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


class GitOpsWorkloadWriter:
    def __init__(
        self,
        source_root: Path | str,
        *,
        render_validator: RenderValidator | None = None,
    ):
        self.paths = GitOpsRepositoryPaths.from_source_root(source_root)
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
        )

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
