from dataclasses import dataclass
from pathlib import Path, PureWindowsPath
import re

import yaml

from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.models import WorkloadWriteRequest, validate_app_name


EXPECTED_MANIFEST_FILES = ("deployment.yaml", "service.yaml", "kustomization.yaml")
EXPECTED_KUSTOMIZATION_RESOURCES = ["deployment.yaml", "service.yaml"]
DEFAULT_WORKLOAD_NAMESPACE = "devdeploy-apps"
MAX_DISCOVERED_APPS = 200
MAX_MANIFEST_BYTES = 1_000_000
KUBERNETES_NAME_PATTERN = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")


@dataclass(frozen=True, slots=True)
class DiscoveredGitOpsApp:
    app_name: str
    image: str
    replicas: int
    container_port: int
    service_port: int
    service_type: str
    namespace: str
    manifest_path: str
    status: str = "unknown"


class GitOpsAppDiscoveryService:
    """Read generated desired-state manifests without mutating Git or Kubernetes."""

    def discover(
        self,
        *,
        repo_root: Path | str,
        source_root_relative: str,
    ) -> list[DiscoveredGitOpsApp]:
        source_root = self._resolve_source_root(repo_root, source_root_relative)
        apps_root = self._resolve_apps_root(source_root)
        try:
            entries = sorted(apps_root.iterdir(), key=lambda entry: entry.name)
        except OSError:
            raise GitOpsWriterError(
                "repo_not_configured",
                "The configured GitOps apps directory is unavailable.",
            ) from None

        discovered: list[DiscoveredGitOpsApp] = []
        for entry in entries[:MAX_DISCOVERED_APPS]:
            app = self._discover_entry(source_root, apps_root, entry)
            if app is not None:
                discovered.append(app)
        return discovered

    @staticmethod
    def _resolve_source_root(repo_root: Path | str, source_root_relative: str) -> Path:
        try:
            resolved_repo = Path(repo_root).resolve(strict=True)
        except (OSError, RuntimeError, TypeError):
            raise GitOpsWriterError(
                "repo_not_configured",
                "The configured Git repository is unavailable.",
            ) from None
        if not resolved_repo.is_dir():
            raise GitOpsWriterError(
                "repo_not_configured",
                "The configured Git repository is not a directory.",
            )
        if (
            not isinstance(source_root_relative, str)
            or not source_root_relative
            or "\\" in source_root_relative
            or any(ord(character) < 32 or ord(character) == 127 for character in source_root_relative)
        ):
            raise GitOpsWriterError("unsafe_path", "The configured GitOps source path is invalid.")

        relative_path = Path(source_root_relative)
        windows_path = PureWindowsPath(source_root_relative)
        if relative_path.is_absolute() or windows_path.is_absolute() or windows_path.drive:
            raise GitOpsWriterError("unsafe_path", "The configured GitOps source path must be relative.")
        if any(part in {"", ".", ".."} or part.lower() == ".git" for part in relative_path.parts):
            raise GitOpsWriterError("unsafe_path", "The configured GitOps source path is not allowed.")

        try:
            source_root = (resolved_repo / relative_path).resolve(strict=True)
            source_root.relative_to(resolved_repo)
        except (OSError, RuntimeError, ValueError):
            raise GitOpsWriterError(
                "repo_not_configured",
                "The configured GitOps source root is unavailable.",
            ) from None
        if not source_root.is_dir():
            raise GitOpsWriterError(
                "repo_not_configured",
                "The configured GitOps source root is not a directory.",
            )
        return source_root

    @staticmethod
    def _resolve_apps_root(source_root: Path) -> Path:
        try:
            apps_root = (source_root / "apps").resolve(strict=True)
            apps_root.relative_to(source_root)
        except (OSError, RuntimeError, ValueError):
            raise GitOpsWriterError(
                "repo_not_configured",
                "The configured GitOps apps directory is unavailable.",
            ) from None
        if not apps_root.is_dir():
            raise GitOpsWriterError(
                "repo_not_configured",
                "The configured GitOps apps path is not a directory.",
            )
        return apps_root

    @classmethod
    def _discover_entry(
        cls,
        source_root: Path,
        apps_root: Path,
        entry: Path,
    ) -> DiscoveredGitOpsApp | None:
        if entry.name.startswith("."):
            return None
        try:
            if entry.is_symlink() or not entry.is_dir():
                return None
            app_name = validate_app_name(entry.name)
            app_dir = entry.resolve(strict=True)
            app_dir.relative_to(apps_root)
            manifests = {
                file_name: cls._load_manifest(app_dir, file_name)
                for file_name in EXPECTED_MANIFEST_FILES
            }
            return cls._parse_app(source_root, app_dir, app_name, manifests)
        except (GitOpsWriterError, OSError, RuntimeError, UnicodeError, yaml.YAMLError):
            return None

    @staticmethod
    def _load_manifest(app_dir: Path, file_name: str) -> dict:
        path = app_dir / file_name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_MANIFEST_BYTES:
            raise GitOpsWriterError("invalid_manifest", "A required generated manifest is invalid.")
        resolved = path.resolve(strict=True)
        try:
            resolved.relative_to(app_dir)
        except ValueError:
            raise GitOpsWriterError("unsafe_path", "A generated manifest resolves outside its app directory.") from None
        document = yaml.safe_load(resolved.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise GitOpsWriterError("invalid_manifest", "A required generated manifest is invalid.")
        return document

    @classmethod
    def _parse_app(
        cls,
        source_root: Path,
        app_dir: Path,
        app_name: str,
        manifests: dict[str, dict],
    ) -> DiscoveredGitOpsApp:
        deployment = manifests["deployment.yaml"]
        service = manifests["service.yaml"]
        kustomization = manifests["kustomization.yaml"]
        if (
            deployment.get("apiVersion") != "apps/v1"
            or deployment.get("kind") != "Deployment"
            or service.get("apiVersion") != "v1"
            or service.get("kind") != "Service"
            or kustomization.get("apiVersion") != "kustomize.config.k8s.io/v1beta1"
            or kustomization.get("kind") != "Kustomization"
            or kustomization.get("resources") != EXPECTED_KUSTOMIZATION_RESOURCES
        ):
            raise GitOpsWriterError("invalid_manifest", "The app Kustomization is invalid.")

        deployment_metadata = cls._mapping(deployment.get("metadata"))
        deployment_spec = cls._mapping(deployment.get("spec"))
        template = cls._mapping(deployment_spec.get("template"))
        pod_spec = cls._mapping(template.get("spec"))
        container = cls._first_mapping(pod_spec.get("containers"))
        container_port = cls._named_port(container.get("ports"), "containerPort")

        service_metadata = cls._mapping(service.get("metadata"))
        service_spec = cls._mapping(service.get("spec"))
        service_port = cls._named_port(service_spec.get("ports"), "port")

        if deployment_metadata.get("name") != app_name or service_metadata.get("name") != app_name:
            raise GitOpsWriterError("invalid_manifest", "Generated resource names do not match the app directory.")
        if container.get("name") != app_name:
            raise GitOpsWriterError("invalid_manifest", "The generated container name does not match the app directory.")

        deployment_namespace = deployment_metadata.get("namespace")
        service_namespace = service_metadata.get("namespace")
        namespace = deployment_namespace or service_namespace or DEFAULT_WORKLOAD_NAMESPACE
        if deployment_namespace and service_namespace and deployment_namespace != service_namespace:
            raise GitOpsWriterError("invalid_manifest", "Generated resource namespaces do not match.")
        if (
            not isinstance(namespace, str)
            or len(namespace) > 63
            or not KUBERNETES_NAME_PATTERN.fullmatch(namespace)
        ):
            raise GitOpsWriterError("invalid_manifest", "The generated workload namespace is invalid.")

        request = WorkloadWriteRequest(
            app_name=app_name,
            image=container.get("image"),
            replicas=deployment_spec.get("replicas"),
            container_port=container_port,
            service_port=service_port,
            service_type=service_spec.get("type", "ClusterIP"),
        )
        return DiscoveredGitOpsApp(
            app_name=request.app_name,
            image=request.image,
            replicas=request.replicas,
            container_port=request.container_port,
            service_port=request.service_port,
            service_type=request.service_type,
            namespace=namespace,
            manifest_path=app_dir.relative_to(source_root).as_posix(),
        )

    @staticmethod
    def _mapping(value: object) -> dict:
        if not isinstance(value, dict):
            raise GitOpsWriterError("invalid_manifest", "A generated manifest field is invalid.")
        return value

    @classmethod
    def _first_mapping(cls, value: object) -> dict:
        if not isinstance(value, list) or not value:
            raise GitOpsWriterError("invalid_manifest", "A generated manifest list is invalid.")
        return cls._mapping(value[0])

    @classmethod
    def _named_port(cls, value: object, field_name: str) -> object:
        if not isinstance(value, list) or not value:
            raise GitOpsWriterError("invalid_manifest", "A generated manifest port is missing.")
        named = next(
            (item for item in value if isinstance(item, dict) and item.get("name") == "http"),
            value[0],
        )
        return cls._mapping(named).get(field_name)
