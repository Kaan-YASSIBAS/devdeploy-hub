from typing import Any

import httpx
from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models.gitops_deployment_request import GitOpsDeploymentRequest
from app.models.user import User
from app.repositories.application_repository import ApplicationRepository
from app.schemas.gitops_deployment import GitOpsDeploymentCreate, GitOpsDeploymentResponse


class GitOpsDeploymentService:
    def __init__(self, db: Session):
        self.db = db
        self.applications = ApplicationRepository(db)

    def create(self, payload: GitOpsDeploymentCreate, current_user: User) -> GitOpsDeploymentResponse:
        if payload.application_id is not None:
            application = self.applications.get_by_id(payload.application_id)
            if application is None:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Application not found")
            if current_user.role != "admin" and application.owner_id != current_user.id:
                raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Application access denied")

        request = GitOpsDeploymentRequest(
            application_id=payload.application_id,
            app_name=payload.app_name,
            image=payload.image,
            tag=payload.tag,
            namespace=payload.namespace,
            container_port=payload.container_port,
            replicas=payload.replicas,
            ingress_host=payload.ingress_host,
            created_by_id=current_user.id,
            status="pending",
        )
        self.db.add(request)
        self.db.flush()

        manual_inputs = self._workflow_inputs(payload)
        manual_workflow = f"{settings.github_owner}/{settings.github_repo}/actions/workflows/{settings.gitops_workflow_file}"

        if not settings.gitops_enabled or not settings.github_workflow_token:
            request.status = "pending_manual_trigger"
            self.db.commit()
            self.db.refresh(request)
            return GitOpsDeploymentResponse(
                request=request,
                workflow_triggered=False,
                message="GitOps workflow dispatch is not configured. Trigger the workflow manually.",
                manual_workflow=manual_workflow,
                manual_inputs=manual_inputs,
            )

        try:
            self._dispatch_workflow(manual_inputs)
        except httpx.HTTPStatusError as exc:
            request.status = "failed"
            request.error_message = self._sanitize_http_error(exc)
            self.db.commit()
            self.db.refresh(request)
            return GitOpsDeploymentResponse(
                request=request,
                workflow_triggered=False,
                message="GitOps workflow dispatch failed.",
                manual_workflow=manual_workflow,
                manual_inputs=manual_inputs,
            )
        except httpx.HTTPError as exc:
            request.status = "failed"
            request.error_message = f"GitHub workflow dispatch failed: {exc.__class__.__name__}"
            self.db.commit()
            self.db.refresh(request)
            return GitOpsDeploymentResponse(
                request=request,
                workflow_triggered=False,
                message="GitOps workflow dispatch failed.",
                manual_workflow=manual_workflow,
                manual_inputs=manual_inputs,
            )

        request.status = "workflow_triggered"
        self.db.commit()
        self.db.refresh(request)
        return GitOpsDeploymentResponse(
            request=request,
            workflow_triggered=True,
            message="GitOps workload workflow was triggered.",
            manual_workflow=manual_workflow,
            manual_inputs=manual_inputs,
        )

    def _dispatch_workflow(self, inputs: dict[str, str]) -> None:
        url = (
            f"https://api.github.com/repos/{settings.github_owner}/{settings.github_repo}"
            f"/actions/workflows/{settings.gitops_workflow_file}/dispatches"
        )
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {settings.github_workflow_token}",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        payload: dict[str, Any] = {"ref": settings.gitops_target_ref, "inputs": inputs}
        response = httpx.post(url, headers=headers, json=payload, timeout=10.0)
        response.raise_for_status()

    @staticmethod
    def _workflow_inputs(payload: GitOpsDeploymentCreate) -> dict[str, str]:
        return {
            "app_name": payload.app_name,
            "image": payload.image,
            "tag": payload.tag,
            "namespace": payload.namespace,
            "container_port": str(payload.container_port),
            "replicas": str(payload.replicas),
            "ingress_host": payload.ingress_host or "",
        }

    @staticmethod
    def _sanitize_http_error(exc: httpx.HTTPStatusError) -> str:
        status_code = exc.response.status_code
        reason = exc.response.reason_phrase
        return f"GitHub workflow dispatch returned HTTP {status_code}: {reason}"
