from dataclasses import dataclass
from pathlib import Path, PureWindowsPath

from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.models import validate_app_name


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


@dataclass(frozen=True, slots=True)
class GitOpsRepositoryPaths:
    source_root: Path
    apps_root: Path
    root_kustomization: Path

    @classmethod
    def from_source_root(cls, source_root: Path | str, *, create_apps_root: bool = False) -> "GitOpsRepositoryPaths":
        try:
            resolved_source = Path(source_root).resolve(strict=True)
        except (OSError, RuntimeError):
            raise GitOpsWriterError(
                "repo_not_configured",
                "The configured GitOps source root is missing or unavailable.",
            ) from None

        if not resolved_source.is_dir():
            raise GitOpsWriterError(
                "repo_not_configured",
                "The configured GitOps source root is not a directory.",
            )

        apps_path = resolved_source / "apps"
        try:
            resolved_apps = apps_path.resolve(strict=True)
        except (OSError, RuntimeError):
            if not create_apps_root:
                raise GitOpsWriterError(
                    "repo_not_configured",
                    "The configured GitOps apps directory is missing or unavailable.",
                ) from None
            try:
                candidate_apps = apps_path.resolve(strict=False)
                if not _is_within(candidate_apps, resolved_source):
                    raise GitOpsWriterError(
                        "unsafe_path",
                        "The GitOps apps directory resolves outside the configured source root.",
                    )
                apps_path.mkdir()
                resolved_apps = apps_path.resolve(strict=True)
            except GitOpsWriterError:
                raise
            except (OSError, RuntimeError):
                raise GitOpsWriterError(
                    "repo_not_configured",
                    "The configured GitOps apps directory could not be prepared.",
                ) from None

        if not resolved_apps.is_dir() or not _is_within(resolved_apps, resolved_source):
            raise GitOpsWriterError(
                "unsafe_path",
                "The GitOps apps directory resolves outside the configured source root.",
            )

        root_kustomization = (resolved_source / "kustomization.yaml").resolve(strict=False)
        if not _is_within(root_kustomization, resolved_source):
            raise GitOpsWriterError(
                "unsafe_path",
                "The root Kustomization path resolves outside the configured source root.",
            )

        return cls(
            source_root=resolved_source,
            apps_root=resolved_apps,
            root_kustomization=root_kustomization,
        )

    def app_dir(self, app_name: str) -> Path:
        validated_name = validate_app_name(app_name)
        try:
            candidate = (self.apps_root / validated_name).resolve(strict=False)
        except (OSError, RuntimeError):
            raise GitOpsWriterError("unsafe_path", "The app path could not be resolved safely.") from None
        if not _is_within(candidate, self.apps_root):
            raise GitOpsWriterError(
                "unsafe_path",
                "The app path resolves outside the configured apps directory.",
            )
        return candidate

    def validate_resource_entry(self, entry: object) -> str:
        if not isinstance(entry, str) or not entry or "\\" in entry:
            raise GitOpsWriterError(
                "unsafe_kustomization_resource",
                "The root Kustomization contains an unsafe resource entry.",
            )

        windows_path = PureWindowsPath(entry)
        parts = Path(entry).parts
        if windows_path.is_absolute() or Path(entry).is_absolute() or any(part in {".", ".."} for part in parts):
            raise GitOpsWriterError(
                "unsafe_kustomization_resource",
                "The root Kustomization contains an unsafe resource entry.",
            )

        try:
            candidate = (self.source_root / entry).resolve(strict=False)
        except (OSError, RuntimeError):
            raise GitOpsWriterError(
                "unsafe_kustomization_resource",
                "A root Kustomization resource path could not be resolved safely.",
            ) from None
        if not _is_within(candidate, self.source_root):
            raise GitOpsWriterError(
                "unsafe_kustomization_resource",
                "A root Kustomization resource resolves outside the configured source root.",
            )
        return entry
