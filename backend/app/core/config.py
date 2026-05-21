from functools import lru_cache

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
