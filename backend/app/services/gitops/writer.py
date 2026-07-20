from dataclasses import dataclass
import os
from pathlib import Path
import shutil
import tempfile

from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.kustomization import RootKustomizationEditor
from app.services.gitops.manifests import MANIFEST_FILE_ORDER, generate_workload_manifests
from app.services.gitops.models import WorkloadWriteRequest
from app.services.gitops.paths import GitOpsRepositoryPaths
from app.services.gitops.render import RenderValidator, StructuralRenderValidator


@dataclass(frozen=True, slots=True)
class WorkloadWriteResult:
    app_name: str
    app_dir: Path
    written_files: tuple[Path, ...]
    root_kustomization: Path
    changed: bool


@dataclass(frozen=True, slots=True)
class WorkloadDestroyResult:
    app_name: str
    app_dir: Path
    removed_files: tuple[Path, ...]
    root_kustomization: Path
    changed: bool


class GitOpsWorkloadWriter:
    def __init__(
        self,
        source_root: Path | str,
        *,
        render_validator: RenderValidator | None = None,
    ):
        self.paths = GitOpsRepositoryPaths.from_source_root(source_root, create_apps_root=True)
        self.render_validator = render_validator or StructuralRenderValidator()

    def create(self, request: WorkloadWriteRequest) -> WorkloadWriteResult:
        app_dir = self.paths.app_dir(request.app_name)
        if app_dir.exists():
            raise GitOpsWriterError("app_exists", "The requested app already exists.")

        generated = generate_workload_manifests(request)
        root_editor = RootKustomizationEditor(self.paths)
        root_content = root_editor.add_app(request.app_name)
        self.render_validator.validate(
            source_root=self.paths.source_root,
            app_name=request.app_name,
            generated_files=generated.files,
            root_kustomization=root_content,
        )

        candidate_dir = Path(tempfile.mkdtemp(prefix=".devdeploy-app-", dir=self.paths.apps_root))
        app_installed = False
        root_written = False
        try:
            for file_name in MANIFEST_FILE_ORDER:
                (candidate_dir / file_name).write_text(generated.files[file_name], encoding="utf-8", newline="\n")

            candidate_dir.replace(app_dir)
            app_installed = True
            self._atomic_write(self.paths.root_kustomization, root_content)
            root_written = True
        except GitOpsWriterError:
            raise
        except (OSError, UnicodeError):
            raise GitOpsWriterError(
                "write_failed",
                "The GitOps workload files could not be written safely.",
            ) from None
        finally:
            if candidate_dir.exists():
                shutil.rmtree(candidate_dir, ignore_errors=True)
            if app_installed and not root_written:
                shutil.rmtree(app_dir, ignore_errors=True)

        written_files = tuple(app_dir / file_name for file_name in MANIFEST_FILE_ORDER)
        return WorkloadWriteResult(
            app_name=request.app_name,
            app_dir=app_dir,
            written_files=written_files,
            root_kustomization=self.paths.root_kustomization,
            changed=True,
        )

    def recover(self, request: WorkloadWriteRequest) -> WorkloadWriteResult:
        app_dir = self.paths.app_dir(request.app_name)
        if app_dir.exists() and not app_dir.is_dir():
            raise GitOpsWriterError("write_failed", "The GitOps workload path is not a directory.")

        generated = generate_workload_manifests(request)
        root_content = RootKustomizationEditor(self.paths).add_app(request.app_name)
        self.render_validator.validate(
            source_root=self.paths.source_root,
            app_name=request.app_name,
            generated_files=generated.files,
            root_kustomization=root_content,
        )

        written_files = tuple(app_dir / file_name for file_name in MANIFEST_FILE_ORDER)
        app_changed = any(
            not self._matches_content(path, generated.files[path.name])
            for path in written_files
        )
        root_changed = not self._matches_content(self.paths.root_kustomization, root_content)
        changed = app_changed or root_changed
        if not changed:
            return WorkloadWriteResult(
                app_name=request.app_name,
                app_dir=app_dir,
                written_files=written_files,
                root_kustomization=self.paths.root_kustomization,
                changed=False,
            )

        created_app_dir = not app_dir.exists()
        try:
            app_dir.mkdir(exist_ok=True)
            if app_changed:
                for file_name in MANIFEST_FILE_ORDER:
                    self._atomic_write(app_dir / file_name, generated.files[file_name])
            if root_changed:
                self._atomic_write(self.paths.root_kustomization, root_content)
        except (OSError, UnicodeError):
            if created_app_dir:
                shutil.rmtree(app_dir, ignore_errors=True)
            raise GitOpsWriterError(
                "write_failed",
                "The GitOps workload files could not be recovered safely.",
            ) from None

        return WorkloadWriteResult(
            app_name=request.app_name,
            app_dir=app_dir,
            written_files=written_files,
            root_kustomization=self.paths.root_kustomization,
            changed=True,
        )

    def restore_destroyed(self, request: WorkloadWriteRequest) -> WorkloadWriteResult:
        app_dir = self.paths.app_dir(request.app_name)
        if app_dir.exists() and not app_dir.is_dir():
            raise GitOpsWriterError("write_failed", "The GitOps workload path is not a directory.")

        generated = generate_workload_manifests(request)
        self._validate_restore_app_dir(app_dir, generated.files)
        root_content = self._restore_root_content(request.app_name)
        self.render_validator.validate(
            source_root=self.paths.source_root,
            app_name=request.app_name,
            generated_files=generated.files,
            root_kustomization=root_content,
        )

        written_files = tuple(app_dir / file_name for file_name in MANIFEST_FILE_ORDER)
        app_changed = any(
            not self._matches_content(path, generated.files[path.name])
            for path in written_files
        )
        root_changed = not self._matches_content(self.paths.root_kustomization, root_content)
        changed = app_changed or root_changed
        if not changed:
            return WorkloadWriteResult(
                app_name=request.app_name,
                app_dir=app_dir,
                written_files=written_files,
                root_kustomization=self.paths.root_kustomization,
                changed=False,
            )

        created_app_dir = not app_dir.exists()
        try:
            app_dir.mkdir(exist_ok=True)
            if app_changed:
                for file_name in MANIFEST_FILE_ORDER:
                    target = app_dir / file_name
                    if not self._matches_content(target, generated.files[file_name]):
                        self._atomic_write(target, generated.files[file_name])
            if root_changed:
                self._atomic_write(self.paths.root_kustomization, root_content)
        except (OSError, UnicodeError):
            if created_app_dir:
                shutil.rmtree(app_dir, ignore_errors=True)
            raise GitOpsWriterError(
                "write_failed",
                "The destroyed GitOps workload files could not be restored safely.",
            ) from None

        return WorkloadWriteResult(
            app_name=request.app_name,
            app_dir=app_dir,
            written_files=written_files,
            root_kustomization=self.paths.root_kustomization,
            changed=True,
        )

    def destroy(self, app_name: str) -> WorkloadDestroyResult:
        app_dir = self.paths.app_dir(app_name)
        if app_dir.exists() and not app_dir.is_dir():
            raise GitOpsWriterError("write_failed", "The GitOps workload path is not a directory.")

        expected_files = tuple(app_dir / file_name for file_name in MANIFEST_FILE_ORDER)
        if app_dir.exists():
            unexpected_entries = [
                entry.name
                for entry in app_dir.iterdir()
                if entry.name not in MANIFEST_FILE_ORDER or not entry.is_file()
            ]
            if unexpected_entries:
                raise GitOpsWriterError(
                    "unexpected_app_files",
                    "The GitOps workload folder contains files outside the V1 manifest contract.",
                )

        try:
            previous_root_content = self.paths.root_kustomization.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            raise GitOpsWriterError(
                "invalid_root_kustomization",
                "The root Kustomization could not be read safely.",
            ) from None
        root_content = RootKustomizationEditor(self.paths).remove_app(app_name)
        existing_files = tuple(path for path in expected_files if path.exists())
        app_changed = bool(existing_files)
        root_changed = not self._matches_content(self.paths.root_kustomization, root_content)
        changed = app_changed or root_changed
        if not changed:
            return WorkloadDestroyResult(
                app_name=app_name,
                app_dir=app_dir,
                removed_files=existing_files,
                root_kustomization=self.paths.root_kustomization,
                changed=False,
            )

        try:
            if root_changed:
                self._atomic_write(self.paths.root_kustomization, root_content)
            for path in existing_files:
                path.unlink()
            if app_dir.exists():
                app_dir.rmdir()
        except (OSError, UnicodeError):
            if root_changed:
                try:
                    self._atomic_write(self.paths.root_kustomization, previous_root_content)
                except (OSError, UnicodeError):
                    pass
            raise GitOpsWriterError(
                "write_failed",
                "The GitOps workload files could not be removed safely.",
            ) from None

        return WorkloadDestroyResult(
            app_name=app_name,
            app_dir=app_dir,
            removed_files=existing_files,
            root_kustomization=self.paths.root_kustomization,
            changed=True,
        )

    def _validate_restore_app_dir(self, app_dir: Path, generated_files: dict[str, str]) -> None:
        if not app_dir.exists():
            return
        unexpected_entries = [
            entry.name
            for entry in app_dir.iterdir()
            if entry.name not in MANIFEST_FILE_ORDER or not entry.is_file()
        ]
        if unexpected_entries:
            raise GitOpsWriterError(
                "unexpected_app_files",
                "The GitOps workload folder contains files outside the V1 manifest contract.",
            )
        for file_name in MANIFEST_FILE_ORDER:
            path = app_dir / file_name
            if path.exists() and not self._matches_content(path, generated_files[file_name]):
                raise GitOpsWriterError(
                    "app_manifest_conflict",
                    "The existing GitOps workload manifest does not match the deterministic recovery output.",
                )

    def _restore_root_content(self, app_name: str) -> str:
        root_editor = RootKustomizationEditor(self.paths)
        document = root_editor._load_document(self.paths.root_kustomization)
        app_entry = f"apps/{app_name}"
        raw_resources = document.get("resources", [])
        if raw_resources is None:
            raw_resources = []
        if not isinstance(raw_resources, list):
            raise GitOpsWriterError(
                "invalid_root_kustomization",
                "The root Kustomization resources field must be a list.",
            )
        duplicate_count = sum(1 for resource in raw_resources if resource == app_entry)
        if duplicate_count > 1:
            raise GitOpsWriterError(
                "invalid_root_kustomization",
                "The root Kustomization contains duplicate entries for this app.",
            )
        return root_editor.add_app(app_name)

    @staticmethod
    def _matches_content(path: Path, expected: str) -> bool:
        try:
            return path.is_file() and path.read_text(encoding="utf-8") == expected
        except (OSError, UnicodeError):
            return False

    @staticmethod
    def _atomic_write(path: Path, content: str) -> None:
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
        temporary_path = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_path, path)
        finally:
            if temporary_path.exists():
                temporary_path.unlink(missing_ok=True)
