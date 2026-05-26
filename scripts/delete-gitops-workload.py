#!/usr/bin/env python3
"""Remove GitOps-managed Kubernetes workload manifests for DevDeploy Hub."""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
# Standard generated workload root. This script removes manifests from Git only;
# it never calls Kubernetes. Argo CD performs the cluster deletion after merge.
GENERATED_ROOT = REPO_ROOT / "infra/kubernetes/generated/workloads"
APPS_ROOT = GENERATED_ROOT / "apps"
ROOT_KUSTOMIZATION = GENERATED_ROOT / "kustomization.yaml"
DNS_LABEL_PATTERN = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


def validate_dns_label(value: str, field_name: str) -> str:
    if len(value) > 63 or not DNS_LABEL_PATTERN.fullmatch(value):
        raise ValueError(f"{field_name} must be a DNS-safe slug")
    return value


def update_root_kustomization(app_name: str) -> None:
    if not ROOT_KUSTOMIZATION.exists():
        raise FileNotFoundError(f"{ROOT_KUSTOMIZATION.relative_to(REPO_ROOT)} does not exist")

    resource = f"apps/{app_name}"
    lines = ROOT_KUSTOMIZATION.read_text(encoding="utf-8").splitlines()
    next_lines = [line for line in lines if line.strip() != f"- {resource}"]
    ROOT_KUSTOMIZATION.write_text("\n".join(next_lines).rstrip() + "\n", encoding="utf-8")


def delete_workload(args: argparse.Namespace) -> None:
    app_name = validate_dns_label(args.app_name, "app_name")
    validate_dns_label(args.namespace, "namespace")
    app_dir = APPS_ROOT / app_name

    if not app_dir.exists():
        raise FileNotFoundError(f"Generated workload path does not exist: {app_dir.relative_to(REPO_ROOT)}")

    shutil.rmtree(app_dir)
    update_root_kustomization(app_name)

    print(f"deleted workload manifests for {app_name}")
    print(f"namespace: {args.namespace}")
    print(f"path: {app_dir.relative_to(REPO_ROOT)}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Delete DevDeploy Hub GitOps workload manifests.")
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--namespace", default="devdeploy-workloads")
    return parser


def main() -> int:
    parser = build_parser()
    try:
        delete_workload(parser.parse_args())
    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
