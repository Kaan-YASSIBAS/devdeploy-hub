from functools import lru_cache
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    database_url: str = Field(alias="DATABASE_URL")
    jwt_secret_key: str = Field(alias="JWT_SECRET_KEY", min_length=32)
    jwt_algorithm: str = Field(default="HS256", alias="JWT_ALGORITHM")
    access_token_expire_minutes: int = Field(default=60, alias="ACCESS_TOKEN_EXPIRE_MINUTES")
    frontend_origin: str = Field(default="http://localhost:5173", alias="FRONTEND_ORIGIN")
    environment: str = Field(default="development", alias="ENVIRONMENT")
    kubernetes_in_cluster: bool = Field(default=False, alias="KUBERNETES_IN_CLUSTER")
    kubeconfig_path: str | None = Field(default=None, alias="KUBECONFIG_PATH")
    prometheus_base_url: str = Field(
        default="http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090",
        alias="PROMETHEUS_BASE_URL",
    )
    loki_base_url: str = Field(
        default="http://loki-gateway.monitoring.svc.cluster.local",
        alias="LOKI_BASE_URL",
    )
    grafana_base_url: str | None = Field(default=None, alias="GRAFANA_BASE_URL")
    gitops_enabled: bool = Field(default=False, alias="GITOPS_ENABLED")
    github_owner: str = Field(default="Kaan-YASSIBAS", alias="GITHUB_OWNER")
    github_repo: str = Field(default="devdeploy-hub", alias="GITHUB_REPO")
    gitops_workflow_file: str = Field(default="gitops-workload-request.yml", alias="GITOPS_WORKFLOW_FILE")
    gitops_delete_workflow_file: str = Field(default="gitops-workload-delete.yml", alias="GITOPS_DELETE_WORKFLOW_FILE")
    github_workflow_token: str | None = Field(default=None, alias="GITHUB_WORKFLOW_TOKEN")
    gitops_target_ref: str = Field(default="main", alias="GITOPS_TARGET_REF")
    gitops_repo_root: str | None = Field(default=None, alias="DEVDEPLOY_GITOPS_REPO_ROOT")
    gitops_source_root: str = Field(
        default="gitops/workloads/devdeploy-apps",
        alias="DEVDEPLOY_GITOPS_SOURCE_ROOT",
    )
    gitops_branch: str = Field(default="main", alias="DEVDEPLOY_GITOPS_BRANCH")
    gitops_remote: str = Field(default="origin", alias="DEVDEPLOY_GITOPS_REMOTE")
    gitops_remote_branch: str = Field(default="main", alias="DEVDEPLOY_GITOPS_REMOTE_BRANCH")
    argocd_root_application_name: str = Field(
        default="devdeploy-workloads-root",
        alias="DEVDEPLOY_ARGOCD_ROOT_APPLICATION_NAME",
    )
    argocd_namespace: str = Field(default="argocd", alias="DEVDEPLOY_ARGOCD_NAMESPACE")
    workload_namespace: str = Field(default="devdeploy-apps", alias="DEVDEPLOY_WORKLOAD_NAMESPACE")
    status_reader_mode: Literal["unavailable", "kubernetes"] = Field(
        default="unavailable",
        alias="DEVDEPLOY_STATUS_READER_MODE",
    )
    management_kubeconfig: str | None = Field(default=None, alias="DEVDEPLOY_MGMT_KUBECONFIG")
    management_kubeconfig_context: str | None = Field(
        default=None,
        alias="DEVDEPLOY_MGMT_KUBECONFIG_CONTEXT",
    )
    workload_kubeconfig: str | None = Field(default=None, alias="DEVDEPLOY_WORKLOAD_KUBECONFIG")
    workload_kubeconfig_context: str | None = Field(
        default=None,
        alias="DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT",
    )

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        populate_by_name=True,
    )

    @property
    def cors_origins(self) -> list[str]:
        return [origin.strip() for origin in self.frontend_origin.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
