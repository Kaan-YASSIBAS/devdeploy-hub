from dataclasses import dataclass

import yaml

from app.services.gitops.models import WorkloadWriteRequest


WORKLOAD_NAMESPACE = "devdeploy-apps"
KUSTOMIZE_API_VERSION = "kustomize.config.k8s.io/v1beta1"
KUSTOMIZE_KIND = "Kustomization"
MANIFEST_FILE_ORDER = ("deployment.yaml", "service.yaml", "kustomization.yaml")


class _IndentedSafeDumper(yaml.SafeDumper):
    def increase_indent(self, flow: bool = False, indentless: bool = False) -> None:
        return super().increase_indent(flow, False)


def dump_yaml(document: dict) -> str:
    rendered = yaml.dump(
        document,
        Dumper=_IndentedSafeDumper,
        allow_unicode=False,
        default_flow_style=False,
        sort_keys=False,
    )
    return rendered.rstrip() + "\n"


def workload_labels(app_name: str) -> dict[str, str]:
    return {
        "app.kubernetes.io/name": app_name,
        "app.kubernetes.io/managed-by": "devdeploy",
        "app.kubernetes.io/part-of": "devdeploy-workloads",
    }


@dataclass(frozen=True, slots=True)
class GeneratedManifestSet:
    files: dict[str, str]


def generate_workload_manifests(request: WorkloadWriteRequest) -> GeneratedManifestSet:
    deployment = {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": request.app_name,
            "namespace": request.namespace,
            "labels": workload_labels(request.app_name),
        },
        "spec": {
            "replicas": request.replicas,
            "selector": {
                "matchLabels": {
                    "app.kubernetes.io/name": request.app_name,
                },
            },
            "template": {
                "metadata": {
                    "labels": workload_labels(request.app_name),
                },
                "spec": {
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 101,
                        "runAsGroup": 101,
                        "fsGroup": 101,
                        "seccompProfile": {
                            "type": "RuntimeDefault",
                        },
                    },
                    "containers": [
                        {
                            "name": request.app_name,
                            "image": request.image,
                            "ports": [
                                {
                                    "name": "http",
                                    "containerPort": request.container_port,
                                    "protocol": "TCP",
                                },
                            ],
                            "securityContext": {
                                "allowPrivilegeEscalation": False,
                                "readOnlyRootFilesystem": True,
                                "capabilities": {
                                    "drop": ["ALL"],
                                },
                            },
                            "volumeMounts": [
                                {
                                    "name": "nginx-cache",
                                    "mountPath": "/var/cache/nginx",
                                },
                                {
                                    "name": "nginx-run",
                                    "mountPath": "/var/run",
                                },
                                {
                                    "name": "tmp",
                                    "mountPath": "/tmp",
                                },
                            ],
                        },
                    ],
                    "volumes": [
                        {
                            "name": "nginx-cache",
                            "emptyDir": {},
                        },
                        {
                            "name": "nginx-run",
                            "emptyDir": {},
                        },
                        {
                            "name": "tmp",
                            "emptyDir": {},
                        },
                    ],
                },
            },
        },
    }
    service = {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": request.app_name,
            "namespace": request.namespace,
            "labels": workload_labels(request.app_name),
        },
        "spec": {
            "type": request.service_type,
            "selector": {
                "app.kubernetes.io/name": request.app_name,
            },
            "ports": [
                {
                    "name": "http",
                    "port": request.service_port,
                    "targetPort": "http",
                    "protocol": "TCP",
                },
            ],
        },
    }
    kustomization = {
        "apiVersion": KUSTOMIZE_API_VERSION,
        "kind": KUSTOMIZE_KIND,
        "resources": ["deployment.yaml", "service.yaml"],
    }

    files = {
        "deployment.yaml": dump_yaml(deployment),
        "service.yaml": dump_yaml(service),
        "kustomization.yaml": dump_yaml(kustomization),
    }
    return GeneratedManifestSet(files={name: files[name] for name in MANIFEST_FILE_ORDER})
