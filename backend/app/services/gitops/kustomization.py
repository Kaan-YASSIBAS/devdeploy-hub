from pathlib import Path
from typing import Any

import yaml

from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.manifests import KUSTOMIZE_API_VERSION, KUSTOMIZE_KIND, dump_yaml
from app.services.gitops.models import validate_app_name
from app.services.gitops.paths import GitOpsRepositoryPaths


class RootKustomizationEditor:
    def __init__(self, paths: GitOpsRepositoryPaths):
        self.paths = paths

    def add_app(self, app_name: str) -> str:
        validated_name = validate_app_name(app_name)
        document = self._load_document(self.paths.root_kustomization)
        resources_value = document.get("resources", [])
        if resources_value is None:
            resources_value = []
        if not isinstance(resources_value, list):
            raise GitOpsWriterError(
                "invalid_root_kustomization",
                "The root Kustomization resources field must be a list.",
            )

        resources: list[str] = []
        for entry in resources_value:
            safe_entry = self.paths.validate_resource_entry(entry)
            if safe_entry not in resources:
                resources.append(safe_entry)

        app_entry = f"apps/{validated_name}"
        self.paths.validate_resource_entry(app_entry)
        if app_entry not in resources:
            resources.append(app_entry)

        document["resources"] = sorted(resources)
        return dump_yaml(document)

    @staticmethod
    def _load_document(path: Path) -> dict[str, Any]:
        if not path.is_file():
            raise GitOpsWriterError(
                "repo_not_configured",
                "The root Kustomization file is missing.",
            )
        try:
            document = yaml.safe_load(path.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError, UnicodeError):
            raise GitOpsWriterError(
                "invalid_root_kustomization",
                "The root Kustomization could not be read as safe YAML.",
            ) from None

        if not isinstance(document, dict):
            raise GitOpsWriterError(
                "invalid_root_kustomization",
                "The root Kustomization must be a YAML mapping.",
            )
        if document.get("apiVersion") != KUSTOMIZE_API_VERSION or document.get("kind") != KUSTOMIZE_KIND:
            raise GitOpsWriterError(
                "invalid_root_kustomization",
                "The root Kustomization apiVersion or kind is invalid.",
            )
        return document
