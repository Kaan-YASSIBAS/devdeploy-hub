from collections.abc import Mapping
from pathlib import Path
from typing import Protocol

import yaml

from app.services.gitops.errors import GitOpsWriterError


class RenderValidator(Protocol):
    def validate(
        self,
        *,
        source_root: Path,
        app_name: str,
        generated_files: Mapping[str, str],
        root_kustomization: str,
    ) -> None: ...


class StructuralRenderValidator:
    """Validates a candidate Kustomize tree without running cluster commands."""

    required_files = {"deployment.yaml", "service.yaml", "kustomization.yaml"}

    def validate(
        self,
        *,
        source_root: Path,
        app_name: str,
        generated_files: Mapping[str, str],
        root_kustomization: str,
    ) -> None:
        del source_root
        if set(generated_files) != self.required_files:
            raise GitOpsWriterError(
                "render_failed",
                "The generated app file set does not match the V1 contract.",
            )

        parsed: dict[str, object] = {}
        try:
            for name, content in generated_files.items():
                parsed[name] = yaml.safe_load(content)
            root = yaml.safe_load(root_kustomization)
        except yaml.YAMLError:
            raise GitOpsWriterError("render_failed", "Generated YAML validation failed.") from None

        if not all(isinstance(document, dict) for document in parsed.values()) or not isinstance(root, dict):
            raise GitOpsWriterError("render_failed", "Generated YAML must contain mapping documents.")

        deployment = parsed["deployment.yaml"]
        service = parsed["service.yaml"]
        app_kustomization = parsed["kustomization.yaml"]
        if deployment.get("kind") != "Deployment" or service.get("kind") != "Service":
            raise GitOpsWriterError("render_failed", "Generated workload resource kinds are invalid.")
        if app_kustomization.get("resources") != ["deployment.yaml", "service.yaml"]:
            raise GitOpsWriterError("render_failed", "The app Kustomization resource list is invalid.")
        root_resources = root.get("resources")
        if not isinstance(root_resources, list) or f"apps/{app_name}" not in root_resources:
            raise GitOpsWriterError("render_failed", "The root Kustomization does not register the app.")
