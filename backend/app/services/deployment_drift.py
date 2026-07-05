from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any, Literal, Protocol

import yaml

from app.models.deployment_record import DeploymentRecord
from app.schemas.deployment_drift import (
    DeploymentDriftStatusRead,
    DriftComparisonRead,
    DriftDifferenceRead,
)
from app.services.gitops.models import validate_app_name
from app.services.gitops.status_reader import WorkloadSnapshot
from app.services.product_runtime_status import ProductRuntimeStatusService


ManifestReadStatus = Literal["present", "missing", "unknown"]
REQUIRED_APP_RESOURCES = {"deployment.yaml", "service.yaml"}


@dataclass(frozen=True, slots=True)
class GitOpsManifestSnapshot:
    status: ManifestReadStatus
    message: str
    app_name: str | None = None
    deployment_namespace: str | None = None
    image: str | None = None
    replicas: int | None = None
    container_port: int | None = None
    service_name: str | None = None
    service_namespace: str | None = None
    service_type: str | None = None
    service_port: int | None = None
    target_port: int | str | None = None


class GitOpsManifestSnapshotReader(Protocol):
    def read(self, deployment: DeploymentRecord) -> GitOpsManifestSnapshot: ...


class UnavailableGitOpsManifestReader:
    def read(self, deployment: DeploymentRecord) -> GitOpsManifestSnapshot:
        _ = deployment
        return GitOpsManifestSnapshot(
            status="unknown",
            message="GitOps manifest status is temporarily unavailable.",
        )


class GitOpsManifestReader:
    def __init__(self, repo_root: Path | str, source_root_relative: str):
        self.repo_root = self._resolve_repo_root(repo_root)
        self.source_root_relative = self._validate_relative_path(source_root_relative)
        self.source_root = self._resolve_within(
            self.repo_root,
            self.repo_root / self.source_root_relative,
            strict=True,
        )

    def read(self, deployment: DeploymentRecord) -> GitOpsManifestSnapshot:
        try:
            app_name = validate_app_name(deployment.app_name)
            app_dir = self._app_directory(deployment, app_name)
            required_paths = (
                app_dir / "deployment.yaml",
                app_dir / "service.yaml",
                app_dir / "kustomization.yaml",
                self.source_root / "kustomization.yaml",
            )
            if not app_dir.is_dir() or any(not path.is_file() for path in required_paths):
                return GitOpsManifestSnapshot(
                    status="missing",
                    message="One or more required GitOps workload manifests are missing.",
                )

            deployment_doc = self._read_mapping(required_paths[0])
            service_doc = self._read_mapping(required_paths[1])
            app_kustomization = self._read_mapping(required_paths[2])
            root_kustomization = self._read_mapping(required_paths[3])
            if not REQUIRED_APP_RESOURCES.issubset(self._resources(app_kustomization)):
                return GitOpsManifestSnapshot(
                    status="missing",
                    message="The app Kustomization does not include all required manifests.",
                )
            root_entry = app_dir.relative_to(self.source_root).as_posix()
            if root_entry not in self._resources(root_kustomization):
                return GitOpsManifestSnapshot(
                    status="missing",
                    message="The root Kustomization does not include the managed app.",
                )

            deployment_metadata = self._mapping(deployment_doc.get("metadata"))
            deployment_spec = self._mapping(deployment_doc.get("spec"))
            pod_template = self._mapping(deployment_spec.get("template"))
            pod_spec = self._mapping(pod_template.get("spec"))
            container = self._named_or_first(pod_spec.get("containers"), app_name)
            container_port = self._named_or_first(container.get("ports"), "http")

            service_metadata = self._mapping(service_doc.get("metadata"))
            service_spec = self._mapping(service_doc.get("spec"))
            service_port = self._named_or_first(service_spec.get("ports"), "http")
            return GitOpsManifestSnapshot(
                status="present",
                message="GitOps workload manifests were inspected successfully.",
                app_name=self._string(deployment_metadata.get("name")),
                deployment_namespace=self._string(deployment_metadata.get("namespace")),
                image=self._string(container.get("image")),
                replicas=self._integer(deployment_spec.get("replicas")),
                container_port=self._integer(container_port.get("containerPort")),
                service_name=self._string(service_metadata.get("name")),
                service_namespace=self._string(service_metadata.get("namespace")),
                service_type=self._string(service_spec.get("type")),
                service_port=self._integer(service_port.get("port")),
                target_port=self._port_value(service_port.get("targetPort")),
            )
        except Exception:
            return GitOpsManifestSnapshot(
                status="unknown",
                message="GitOps manifests could not be inspected safely.",
            )

    def _app_directory(self, deployment: DeploymentRecord, app_name: str) -> Path:
        deterministic = self.source_root / "apps" / app_name
        manifest_path = deployment.gitops_manifest_path
        if manifest_path:
            relative = self._validate_relative_path(manifest_path)
            candidate = self.repo_root / relative
            expected_relative = PurePosixPath(self.source_root_relative) / "apps" / app_name
            if relative != expected_relative:
                raise ValueError("Unexpected manifest path")
        else:
            candidate = deterministic
        return self._resolve_within(self.source_root, candidate, strict=False)

    @staticmethod
    def _resolve_repo_root(repo_root: Path | str) -> Path:
        resolved = Path(repo_root).expanduser().resolve(strict=True)
        if not resolved.is_dir():
            raise ValueError("Repository root is not a directory")
        return resolved

    @staticmethod
    def _validate_relative_path(value: str) -> PurePosixPath:
        if not isinstance(value, str) or not value or "\\" in value:
            raise ValueError("Invalid relative path")
        path = PurePosixPath(value)
        windows_path = PureWindowsPath(value)
        if path.is_absolute() or windows_path.is_absolute() or windows_path.drive:
            raise ValueError("Invalid relative path")
        if any(part in {"", ".", ".."} or part.lower() == ".git" for part in path.parts):
            raise ValueError("Invalid relative path")
        return path

    @staticmethod
    def _resolve_within(root: Path, candidate: Path, *, strict: bool) -> Path:
        resolved_root = root.resolve(strict=True)
        resolved_candidate = candidate.resolve(strict=strict)
        resolved_candidate.relative_to(resolved_root)
        return resolved_candidate

    @staticmethod
    def _read_mapping(path: Path) -> dict[str, Any]:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise ValueError("YAML document is not a mapping")
        return document

    @staticmethod
    def _mapping(value: object) -> dict[str, Any]:
        return value if isinstance(value, dict) else {}

    @staticmethod
    def _resources(document: dict[str, Any]) -> set[str]:
        resources = document.get("resources")
        if not isinstance(resources, list):
            return set()
        return {resource for resource in resources if isinstance(resource, str)}

    @staticmethod
    def _named_or_first(value: object, name: str) -> dict[str, Any]:
        items = [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []
        return next((item for item in items if item.get("name") == name), items[0] if items else {})

    @staticmethod
    def _string(value: object) -> str | None:
        return value if isinstance(value, str) else None

    @staticmethod
    def _integer(value: object) -> int | None:
        return value if isinstance(value, int) and not isinstance(value, bool) else None

    @staticmethod
    def _port_value(value: object) -> int | str | None:
        return value if isinstance(value, (int, str)) and not isinstance(value, bool) else None


class DeploymentDriftService:
    def __init__(
        self,
        *,
        manifest_reader: GitOpsManifestSnapshotReader,
        runtime_service: ProductRuntimeStatusService,
    ):
        self.manifest_reader = manifest_reader
        self.runtime_service = runtime_service

    def evaluate(self, deployment: DeploymentRecord) -> DeploymentDriftStatusRead:
        checked_at = datetime.now(timezone.utc)
        try:
            gitops = self._compare_gitops(deployment, self.manifest_reader.read(deployment))
        except Exception:
            gitops = DriftComparisonRead(status="unknown")
        try:
            runtime = self._compare_runtime(
                deployment,
                self.runtime_service.workload_snapshot(deployment.app_name, deployment.namespace),
            )
        except Exception:
            runtime = DriftComparisonRead(status="unknown")

        status, message = self._overall(gitops.status, runtime.status)
        return DeploymentDriftStatusRead(
            status=status,
            db_to_gitops=gitops,
            db_to_runtime=runtime,
            checked_at=checked_at,
            message=message,
        )

    @staticmethod
    def _compare_gitops(
        deployment: DeploymentRecord,
        snapshot: GitOpsManifestSnapshot,
    ) -> DriftComparisonRead:
        if snapshot.status == "missing":
            return DriftComparisonRead(status="missing")
        if snapshot.status == "unknown":
            return DriftComparisonRead(status="unknown")
        values = (
            ("app_name", deployment.app_name, snapshot.app_name),
            ("namespace", deployment.namespace, snapshot.deployment_namespace),
            ("image", deployment.image, snapshot.image),
            ("replicas", deployment.replicas, snapshot.replicas),
            ("container_port", deployment.container_port, snapshot.container_port),
            ("service_name", deployment.app_name, snapshot.service_name),
            ("service_namespace", deployment.namespace, snapshot.service_namespace),
            ("service_type", deployment.service_type, snapshot.service_type),
            ("service_port", deployment.service_port, snapshot.service_port),
            ("target_port", "http", snapshot.target_port),
        )
        return DeploymentDriftService._comparison(values, "gitops")

    @staticmethod
    def _compare_runtime(
        deployment: DeploymentRecord,
        snapshot: WorkloadSnapshot | None,
    ) -> DriftComparisonRead:
        if snapshot is None:
            return DriftComparisonRead(status="unknown")
        if not snapshot.deployment_exists or not snapshot.service_exists:
            return DriftComparisonRead(status="missing")
        service_port = DeploymentDriftService._http_service_port(snapshot)
        values = (
            ("image", deployment.image, snapshot.deployment_image),
            ("replicas", deployment.replicas, snapshot.desired_replicas),
            ("container_port", deployment.container_port, snapshot.container_port),
            ("service_type", deployment.service_type, snapshot.service_type),
            ("service_port", deployment.service_port, service_port.port if service_port else None),
            ("target_port", "http", service_port.target_port if service_port else None),
        )
        return DeploymentDriftService._comparison(values, "runtime")

    @staticmethod
    def _comparison(
        values: tuple[tuple[str, object, object], ...],
        source: Literal["gitops", "runtime"],
    ) -> DriftComparisonRead:
        differences = [
            DriftDifferenceRead(
                field=field,
                expected=DeploymentDriftService._drift_value(expected),
                actual=DeploymentDriftService._drift_value(actual),
                source=source,
            )
            for field, expected, actual in values
            if expected != actual
        ]
        return DriftComparisonRead(
            status="drifted" if differences else "aligned",
            differences=differences,
        )

    @staticmethod
    def _http_service_port(snapshot: WorkloadSnapshot):
        return next(
            (port for port in snapshot.service_ports if port.name == "http"),
            snapshot.service_ports[0] if snapshot.service_ports else None,
        )

    @staticmethod
    def _drift_value(value: object) -> str | int | None:
        if value is None or isinstance(value, str):
            return value
        if isinstance(value, int) and not isinstance(value, bool):
            return value
        return None

    @staticmethod
    def _overall(gitops: str, runtime: str) -> tuple[str, str]:
        if "unknown" in (gitops, runtime):
            return "unknown", "Drift status could not be determined safely."
        if gitops == "missing" and runtime == "missing":
            return "gitops_missing", "Both the desired GitOps manifests and runtime resources are missing."
        if gitops == "missing":
            return "gitops_missing", "The desired GitOps manifests are missing."
        if runtime == "missing":
            return "runtime_missing", "The Kubernetes runtime resources are missing."
        if "drifted" in (gitops, runtime):
            return "drifted", "The deployment record differs from GitOps or runtime state."
        return "aligned", "The deployment record, GitOps manifests, and runtime state are aligned."
