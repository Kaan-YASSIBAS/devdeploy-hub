from datetime import datetime, timezone
from typing import Any

import httpx
from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models.deployment import Deployment
from app.models.gitops_deployment_request import GitOpsDeploymentRequest
from app.models.user import User
from app.repositories.application_repository import ApplicationRepository
from app.repositories.deployment_repository import DeploymentRepository
from app.schemas.gitops_deployment import GitOpsDeploymentCreate, GitOpsDeploymentResponse
from app.schemas.gitops_deployment import DeploymentListItem
from app.services.kubernetes_service import KubernetesService
from app.services.observability_errors import ObservabilityUnavailableError


DEFAULT_WORKLOAD_NAMESPACE = "devdeploy-workloads"


class GitOpsDeploymentService:
    def __init__(self, db: Session):
        self.db = db
        self.applications = ApplicationRepository(db)
        self.deployments = DeploymentRepository(db)

    def list_deployments(self, current_user: User) -> list[DeploymentListItem]:
        items: list[DeploymentListItem] = []
        gitops_requests = self._list_requests(current_user)
        requests_by_workload = {
            (request.namespace, request.app_name): request
            for request in gitops_requests
        }

        for live_deployment in self._list_live_deployments(DEFAULT_WORKLOAD_NAMESPACE):
            request = requests_by_workload.pop(
                (live_deployment["namespace"], live_deployment["name"]),
                None,
            )
            items.append(self._from_live_deployment(live_deployment, request))

        for request in requests_by_workload.values():
            items.append(self._from_gitops_request(request))

        legacy_deployments = (
            self.deployments.list_all()
            if current_user.role == "admin"
            else self.deployments.list_for_owner(current_user.id)
        )
        for deployment in legacy_deployments:
            items.append(self._from_legacy_deployment(deployment))

        return sorted(items, key=self._sort_timestamp, reverse=True)

    def get_deployment(self, namespace: str, name: str, current_user: User) -> DeploymentListItem:
        for item in self.list_deployments(current_user):
            if item.namespace == namespace and item.name == name:
                return item
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="GitOps deployment not found")

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

    def _list_requests(self, current_user: User) -> list[GitOpsDeploymentRequest]:
        query = self.db.query(GitOpsDeploymentRequest).order_by(GitOpsDeploymentRequest.created_at.desc())
        if current_user.role != "admin":
            query = query.filter(GitOpsDeploymentRequest.created_by_id == current_user.id)
        return query.all()

    @staticmethod
    def _list_live_deployments(namespace: str) -> list[dict[str, Any]]:
        try:
            return KubernetesService().list_deployments(namespace=namespace)
        except ObservabilityUnavailableError:
            return []

    @staticmethod
    def _from_live_deployment(
        live_deployment: dict[str, Any],
        request: GitOpsDeploymentRequest | None,
    ) -> DeploymentListItem:
        labels = live_deployment.get("labels") or {}
        return DeploymentListItem(
            id=request.id if request else None,
            gitops_request_id=request.id if request else None,
            application_id=request.application_id if request else None,
            name=live_deployment["name"],
            app_name=request.app_name if request else labels.get("devdeploy.io/application", live_deployment["name"]),
            namespace=live_deployment["namespace"],
            image=live_deployment.get("image") or (request.image if request else None),
            tag=live_deployment.get("tag") or (request.tag if request else None),
            environment=labels.get("environment", "dev"),
            replicas=live_deployment["replicas"],
            available_replicas=live_deployment["available_replicas"],
            updated_replicas=live_deployment["updated_replicas"],
            status=live_deployment.get("status", "unknown"),
            source="gitops" if request else "cluster",
            created_at=request.created_at if request else live_deployment.get("created_at"),
            updated_at=live_deployment.get("updated_at") or (request.updated_at if request else None),
        )

    @staticmethod
    def _from_gitops_request(request: GitOpsDeploymentRequest) -> DeploymentListItem:
        return DeploymentListItem(
            id=request.id,
            gitops_request_id=request.id,
            application_id=request.application_id,
            name=request.app_name,
            app_name=request.app_name,
            namespace=request.namespace,
            image=request.image,
            tag=request.tag,
            environment="dev",
            replicas=request.replicas,
            available_replicas=0,
            updated_replicas=0,
            status=GitOpsDeploymentService._status_from_request(request.status),
            source="gitops",
            created_at=request.created_at,
            updated_at=request.updated_at,
        )

    @staticmethod
    def _from_legacy_deployment(deployment: Deployment) -> DeploymentListItem:
        application = deployment.application
        return DeploymentListItem(
            id=deployment.id,
            legacy_deployment_id=deployment.id,
            application_id=deployment.application_id,
            name=f"deployment-{deployment.id}",
            app_name=application.name if application else f"application-{deployment.application_id}",
            namespace="devdeploy",
            image=application.image_name if application else None,
            tag=deployment.image_tag,
            environment=deployment.environment,
            replicas=deployment.replica_count,
            available_replicas=deployment.replica_count if deployment.status == "success" else 0,
            updated_replicas=deployment.replica_count if deployment.status in {"running", "success"} else 0,
            status=deployment.status,
            source="legacy",
            created_at=deployment.created_at,
            updated_at=deployment.updated_at,
        )

    @staticmethod
    def _status_from_request(status_value: str) -> str:
        if status_value == "failed":
            return "failed"
        if status_value in {"pending", "pending_manual_trigger"}:
            return "pending"
        if status_value in {"workflow_triggered", "pr_opened"}:
            return "progressing"
        return "unknown"

    @staticmethod
    def _sort_timestamp(item: DeploymentListItem) -> datetime:
        return item.updated_at or item.created_at or datetime.min.replace(tzinfo=timezone.utc)

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
