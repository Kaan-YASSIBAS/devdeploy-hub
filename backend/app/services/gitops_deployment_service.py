from collections.abc import Iterable
from datetime import datetime, timedelta, timezone
import re
from typing import Any

import httpx
from fastapi import HTTPException, status
from kubernetes.client import ApiException
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models.deployment import Deployment
from app.models.gitops_deployment_request import GitOpsDeploymentRequest
from app.models.user import User
from app.repositories.application_repository import ApplicationRepository
from app.repositories.deployment_repository import DeploymentRepository
from app.schemas.gitops_deployment import GitOpsDeploymentCreate, GitOpsDeploymentDeleteResponse, GitOpsDeploymentResponse
from app.schemas.gitops_deployment import DeploymentListItem
from app.services.kubernetes_service import KubernetesService
from app.services.observability_errors import ObservabilityUnavailableError


DEFAULT_WORKLOAD_NAMESPACE = "devdeploy-workloads"
ACTIVE_GITOPS_REQUEST_STATUSES = {"pending", "pending_manual_trigger", "workflow_triggered", "pr_opened"}
STALE_GITOPS_REQUEST_AFTER = timedelta(hours=1)
STALE_GITOPS_REQUEST_MESSAGE = (
    "No matching Kubernetes deployment was observed within the expected GitOps reconciliation window."
)
DNS_SAFE_NAME_PATTERN = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


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
        workload_namespaces = {DEFAULT_WORKLOAD_NAMESPACE}
        workload_namespaces.update(request.namespace for request in gitops_requests)

        live_deployments = self._list_live_deployments(workload_namespaces)
        if live_deployments is not None:
            for live_deployment in live_deployments:
                request = requests_by_workload.pop(
                    (live_deployment["namespace"], live_deployment["name"]),
                    None,
                )
                items.append(self._from_live_deployment(live_deployment, request))

            if self._mark_stale_requests(requests_by_workload.values()):
                self.db.commit()
            if self._mark_deleted_requests(requests_by_workload.values()):
                self.db.commit()

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

    def delete(self, namespace: str, name: str, current_user: User) -> GitOpsDeploymentDeleteResponse:
        if not DNS_SAFE_NAME_PATTERN.fullmatch(namespace) or not DNS_SAFE_NAME_PATTERN.fullmatch(name):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="namespace and name must be DNS-safe values",
            )

        request = self._find_request(namespace, name, current_user)
        live_deployment = self._find_live_deployment(namespace, name)

        if request is None and live_deployment is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="GitOps deployment not found")

        if request is None:
            if current_user.role != "admin":
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail="Only admins can delete cluster-only GitOps deployments.",
                )
            request = self._create_delete_tracking_request(live_deployment or {}, namespace, name, current_user)

        manual_inputs = self._delete_workflow_inputs(namespace=namespace, name=name)
        manual_workflow = f"{settings.github_owner}/{settings.github_repo}/actions/workflows/{settings.gitops_delete_workflow_file}"

        if not settings.gitops_enabled or not settings.github_workflow_token:
            self.db.commit()
            self.db.refresh(request)
            return GitOpsDeploymentDeleteResponse(
                request=request,
                workflow_triggered=False,
                message="GitOps workflow dispatch is not configured. Trigger the deletion workflow manually.",
                manual_workflow=manual_workflow,
                manual_inputs=manual_inputs,
            )

        try:
            self._dispatch_workflow(manual_inputs, workflow_file=settings.gitops_delete_workflow_file)
        except httpx.HTTPStatusError as exc:
            request.status = "failed"
            request.error_message = self._sanitize_http_error(exc)
            self.db.commit()
            self.db.refresh(request)
            return GitOpsDeploymentDeleteResponse(
                request=request,
                workflow_triggered=False,
                message="GitOps workload deletion dispatch failed.",
                manual_workflow=manual_workflow,
                manual_inputs=manual_inputs,
            )
        except httpx.HTTPError as exc:
            request.status = "failed"
            request.error_message = f"GitHub workflow dispatch failed: {exc.__class__.__name__}"
            self.db.commit()
            self.db.refresh(request)
            return GitOpsDeploymentDeleteResponse(
                request=request,
                workflow_triggered=False,
                message="GitOps workload deletion dispatch failed.",
                manual_workflow=manual_workflow,
                manual_inputs=manual_inputs,
            )

        request.status = "deletion_requested"
        request.error_message = None
        request.updated_at = datetime.now(timezone.utc)
        self.db.commit()
        self.db.refresh(request)
        return GitOpsDeploymentDeleteResponse(
            request=request,
            workflow_triggered=True,
            message="GitOps workload deletion workflow was triggered.",
            manual_workflow=manual_workflow,
            manual_inputs=manual_inputs,
        )

    def _list_requests(self, current_user: User) -> list[GitOpsDeploymentRequest]:
        query = self.db.query(GitOpsDeploymentRequest).order_by(GitOpsDeploymentRequest.created_at.desc())
        if current_user.role != "admin":
            query = query.filter(GitOpsDeploymentRequest.created_by_id == current_user.id)
        return query.all()

    @staticmethod
    def _list_live_deployments(namespaces: set[str]) -> list[dict[str, Any]] | None:
        service = KubernetesService()
        deployments: list[dict[str, Any]] = []
        try:
            for namespace in sorted(namespaces):
                try:
                    deployments.extend(service.list_deployments(namespace=namespace))
                except ApiException as exc:
                    if exc.status == 404:
                        continue
                    raise
        except (ObservabilityUnavailableError, ApiException):
            return None
        return deployments

    def _mark_stale_requests(self, requests: Iterable[GitOpsDeploymentRequest]) -> bool:
        now = datetime.now(timezone.utc)
        changed = False
        for request in requests:
            if not self._should_mark_stale(request, now):
                continue
            request.status = "stale"
            request.error_message = STALE_GITOPS_REQUEST_MESSAGE
            request.updated_at = now
            changed = True
        return changed

    def _mark_deleted_requests(self, requests: Iterable[GitOpsDeploymentRequest]) -> bool:
        now = datetime.now(timezone.utc)
        changed = False
        for request in requests:
            if request.status != "deletion_requested":
                continue
            request.status = "deleted"
            request.updated_at = now
            changed = True
        return changed

    @staticmethod
    def _should_mark_stale(request: GitOpsDeploymentRequest, now: datetime) -> bool:
        if request.status not in ACTIVE_GITOPS_REQUEST_STATUSES:
            return False
        reference_time = GitOpsDeploymentService._request_reference_time(request)
        return now - reference_time > STALE_GITOPS_REQUEST_AFTER

    @staticmethod
    def _request_reference_time(request: GitOpsDeploymentRequest) -> datetime:
        value = request.updated_at or request.created_at
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)

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
            status=(
                GitOpsDeploymentService._status_from_request(request.status)
                if request and request.status == "deletion_requested"
                else live_deployment.get("status", "unknown")
            ),
            source="gitops" if request else "cluster",
            is_live=True,
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
            is_live=False,
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
            is_live=False,
            created_at=deployment.created_at,
            updated_at=deployment.updated_at,
        )

    @staticmethod
    def _status_from_request(status_value: str) -> str:
        if status_value in {"deletion_requested", "deleted"}:
            return status_value
        if status_value in {"failed", "stale"}:
            if status_value == "stale":
                return "stale"
            return "failed"
        if status_value in {"pending", "pending_manual_trigger"}:
            return "pending"
        if status_value in {"workflow_triggered", "pr_opened"}:
            return "progressing"
        return "unknown"

    @staticmethod
    def _sort_timestamp(item: DeploymentListItem) -> datetime:
        value = item.updated_at or item.created_at or datetime.min.replace(tzinfo=timezone.utc)
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)

    def _dispatch_workflow(self, inputs: dict[str, str], *, workflow_file: str | None = None) -> None:
        # GitOps boundary: the backend dispatches a GitHub workflow that edits
        # manifests in Git. It must not apply or delete Kubernetes resources.
        selected_workflow_file = workflow_file or settings.gitops_workflow_file
        url = (
            f"https://api.github.com/repos/{settings.github_owner}/{settings.github_repo}"
            f"/actions/workflows/{selected_workflow_file}/dispatches"
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
    def _delete_workflow_inputs(*, namespace: str, name: str) -> dict[str, str]:
        return {
            "app_name": name,
            "namespace": namespace,
            "auto_merge": "true",
        }

    def _find_request(self, namespace: str, name: str, current_user: User) -> GitOpsDeploymentRequest | None:
        query = self.db.query(GitOpsDeploymentRequest).filter(
            GitOpsDeploymentRequest.namespace == namespace,
            GitOpsDeploymentRequest.app_name == name,
        )
        if current_user.role != "admin":
            query = query.filter(GitOpsDeploymentRequest.created_by_id == current_user.id)
        return query.order_by(GitOpsDeploymentRequest.created_at.desc()).first()

    @staticmethod
    def _find_live_deployment(namespace: str, name: str) -> dict[str, Any] | None:
        live_deployments = GitOpsDeploymentService._list_live_deployments({namespace})
        if live_deployments is None:
            return None
        return next(
            (
                deployment
                for deployment in live_deployments
                if deployment["namespace"] == namespace and deployment["name"] == name
            ),
            None,
        )

    def _create_delete_tracking_request(
        self,
        live_deployment: dict[str, Any],
        namespace: str,
        name: str,
        current_user: User,
    ) -> GitOpsDeploymentRequest:
        request = GitOpsDeploymentRequest(
            application_id=None,
            app_name=name,
            image=live_deployment.get("image") or "ghcr.io/unknown/workload",
            tag=live_deployment.get("tag") or "deleted",
            namespace=namespace,
            container_port=1024,
            replicas=max(int(live_deployment.get("replicas") or 1), 1),
            ingress_host=None,
            status="pending",
            created_by_id=current_user.id,
        )
        self.db.add(request)
        self.db.flush()
        return request

    @staticmethod
    def _sanitize_http_error(exc: httpx.HTTPStatusError) -> str:
        status_code = exc.response.status_code
        reason = exc.response.reason_phrase
        return f"GitHub workflow dispatch returned HTTP {status_code}: {reason}"
