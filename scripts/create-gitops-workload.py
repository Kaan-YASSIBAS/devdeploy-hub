#!/usr/bin/env python3
"""Generate GitOps-managed Kubernetes workload manifests for DevDeploy Hub."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GENERATED_ROOT = REPO_ROOT / "infra/kubernetes/generated/workloads"
APPS_ROOT = GENERATED_ROOT / "apps"
ROOT_KUSTOMIZATION = GENERATED_ROOT / "kustomization.yaml"

DNS_LABEL_PATTERN = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
IMAGE_PATTERN = re.compile(r"^[a-z0-9]+([._-][a-z0-9]+)*(\/[a-z0-9]+([._-][a-z0-9]+)*)+$")
TAG_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
ALLOWED_REGISTRIES = ("ghcr.io/",)


def validate_dns_label(value: str, field_name: str) -> str:
    if len(value) > 63 or not DNS_LABEL_PATTERN.fullmatch(value):
        raise ValueError(f"{field_name} must be a DNS-safe slug, for example demo-api")
    return value


def validate_image(image: str) -> str:
    if not image.startswith(ALLOWED_REGISTRIES):
        allowed = ", ".join(registry.rstrip("/") for registry in ALLOWED_REGISTRIES)
        raise ValueError(f"image must start with an allowed registry: {allowed}")

    remainder = image.split("/", 1)[1]
    if ":" in remainder:
        raise ValueError("image must not include a tag; pass the tag with --tag")

    if not IMAGE_PATTERN.fullmatch(image):
        raise ValueError("image repository contains unsupported characters")

    return image


def validate_tag(tag: str) -> str:
    if tag.lower() == "latest":
        raise ValueError("tag cannot be latest")
    if not TAG_PATTERN.fullmatch(tag):
        raise ValueError("tag contains unsupported characters")
    return tag


def validate_port(port: int, field_name: str) -> int:
    if port < 1024 or port > 65535:
        raise ValueError(f"{field_name} must be between 1024 and 65535")
    return port


def validate_replicas(replicas: int) -> int:
    if replicas < 1 or replicas > 5:
        raise ValueError("replicas must be between 1 and 5")
    return replicas


def validate_ingress_host(host: str | None) -> str | None:
    if not host:
        return None
    if len(host) > 253 or not re.fullmatch(r"[a-z0-9]([-.a-z0-9]*[a-z0-9])?", host):
        raise ValueError("ingress host must be a lowercase DNS host")
    return host


def yaml_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def workload_labels(app_name: str) -> str:
    return f"""app.kubernetes.io/name: {app_name}
    app.kubernetes.io/managed-by: devdeploy-hub
    devdeploy.io/application: {app_name}"""


def deployment_yaml(
    *,
    app_name: str,
    image: str,
    tag: str,
    namespace: str,
    container_port: int,
    replicas: int,
    environment: str | None,
) -> str:
    environment_section = (
        f"""          env:
            - name: APP_ENVIRONMENT
              value: {yaml_quote(environment)}
"""
        if environment
        else ""
    )

    return f"""apiVersion: apps/v1
kind: Deployment
metadata:
  name: {app_name}
  namespace: {namespace}
  labels:
    {workload_labels(app_name)}
spec:
  replicas: {replicas}
  selector:
    matchLabels:
      app.kubernetes.io/name: {app_name}
      devdeploy.io/application: {app_name}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {app_name}
        app.kubernetes.io/managed-by: devdeploy-hub
        devdeploy.io/application: {app_name}
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: {app_name}
          image: {image}:{tag}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: {container_port}
{environment_section}          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: true
            runAsNonRoot: true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {{}}
"""


def service_yaml(*, app_name: str, namespace: str, service_port: int, container_port: int) -> str:
    return f"""apiVersion: v1
kind: Service
metadata:
  name: {app_name}
  namespace: {namespace}
  labels:
    {workload_labels(app_name)}
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: {app_name}
    devdeploy.io/application: {app_name}
  ports:
    - name: http
      port: {service_port}
      targetPort: {container_port}
      protocol: TCP
"""


def ingress_yaml(*, app_name: str, namespace: str, host: str, service_port: int) -> str:
    return f"""apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {app_name}
  namespace: {namespace}
  labels:
    {workload_labels(app_name)}
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  rules:
    - host: {host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {app_name}
                port:
                  number: {service_port}
"""


def app_kustomization(include_ingress: bool) -> str:
    resources = ["deployment.yaml", "service.yaml"]
    if include_ingress:
        resources.append("ingress.yaml")

    rendered = "\n".join(f"  - {resource}" for resource in resources)
    return f"""apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
{rendered}
"""


def update_root_kustomization(app_name: str) -> None:
    ROOT_KUSTOMIZATION.parent.mkdir(parents=True, exist_ok=True)
    if not ROOT_KUSTOMIZATION.exists():
        ROOT_KUSTOMIZATION.write_text(
            "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n\nresources:\n  - namespace.yaml\n",
            encoding="utf-8",
        )

    content = ROOT_KUSTOMIZATION.read_text(encoding="utf-8")
    lines = content.splitlines()
    resource = f"apps/{app_name}"
    existing_resources = {line.strip()[2:] for line in lines if line.strip().startswith("- ")}
    if resource in existing_resources:
        return

    with ROOT_KUSTOMIZATION.open("a", encoding="utf-8") as file:
        if content and not content.endswith("\n"):
            file.write("\n")
        file.write(f"  - {resource}\n")


def generate(args: argparse.Namespace) -> None:
    app_name = validate_dns_label(args.app_name, "app name")
    namespace = validate_dns_label(args.namespace, "namespace")
    image = validate_image(args.image)
    tag = validate_tag(args.tag)
    container_port = validate_port(args.container_port, "container port")
    service_port = validate_port(args.service_port or args.container_port, "service port")
    replicas = validate_replicas(args.replicas)
    ingress_host = validate_ingress_host(args.ingress_host)
    environment = validate_dns_label(args.environment, "environment") if args.environment else None

    app_dir = APPS_ROOT / app_name
    app_dir.mkdir(parents=True, exist_ok=True)
    (app_dir / "deployment.yaml").write_text(
        deployment_yaml(
            app_name=app_name,
            image=image,
            tag=tag,
            namespace=namespace,
            container_port=container_port,
            replicas=replicas,
            environment=environment,
        ),
        encoding="utf-8",
    )
    (app_dir / "service.yaml").write_text(
        service_yaml(app_name=app_name, namespace=namespace, service_port=service_port, container_port=container_port),
        encoding="utf-8",
    )
    if ingress_host:
        (app_dir / "ingress.yaml").write_text(
            ingress_yaml(app_name=app_name, namespace=namespace, host=ingress_host, service_port=service_port),
            encoding="utf-8",
        )
    elif (app_dir / "ingress.yaml").exists():
        (app_dir / "ingress.yaml").unlink()

    (app_dir / "kustomization.yaml").write_text(app_kustomization(include_ingress=bool(ingress_host)), encoding="utf-8")
    update_root_kustomization(app_name)

    print(f"generated workload manifests for {app_name}")
    print(f"image: {image}:{tag}")
    print(f"path: {app_dir.relative_to(REPO_ROOT)}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Generate DevDeploy Hub GitOps workload manifests.")
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--namespace", default="devdeploy-workloads")
    parser.add_argument("--container-port", required=True, type=int)
    parser.add_argument("--replicas", default=1, type=int)
    parser.add_argument("--service-port", type=int)
    parser.add_argument("--ingress-host")
    parser.add_argument("--environment")
    return parser


def main() -> int:
    parser = build_parser()
    try:
        generate(parser.parse_args())
    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
