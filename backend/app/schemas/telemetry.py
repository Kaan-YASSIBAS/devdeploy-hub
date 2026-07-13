from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


TelemetryMode = Literal["disabled", "managed_http_proxy", "application_native"]
ApplicationProtocol = Literal["http", "tcp"]

DEFAULT_PROXY_LISTENER_PORT = 18080
DEFAULT_PROXY_ADMIN_PORT = 19090


class HttpTelemetryConfig(BaseModel):
    enabled: bool = False
    mode: TelemetryMode = "disabled"
    application_protocol: ApplicationProtocol = "http"
    application_container_port: int | None = Field(default=None, ge=1, le=65535)
    service_port: int | None = Field(default=None, ge=1, le=65535)
    proxy_listener_port: int | None = Field(default=None, ge=1, le=65535)
    admin_port: int | None = Field(default=None, ge=1, le=65535)

    model_config = ConfigDict(extra="forbid")

    @model_validator(mode="after")
    def normalize_and_validate(self) -> "HttpTelemetryConfig":
        if not self.enabled or self.mode == "disabled":
            self.enabled = False
            self.mode = "disabled"
            self.application_container_port = None
            self.service_port = None
            self.proxy_listener_port = None
            self.admin_port = None
            return self

        if self.mode == "managed_http_proxy":
            if self.application_protocol != "http":
                raise ValueError("managed_http_proxy requires application_protocol=http")
            if self.application_container_port is None:
                raise ValueError("managed_http_proxy requires application_container_port")
            if self.service_port is None:
                raise ValueError("managed_http_proxy requires service_port")
            if self.proxy_listener_port is None:
                self.proxy_listener_port = DEFAULT_PROXY_LISTENER_PORT
            if self.admin_port is None:
                self.admin_port = DEFAULT_PROXY_ADMIN_PORT
            runtime_ports = {
                self.application_container_port,
                self.proxy_listener_port,
                self.admin_port,
            }
            if len(runtime_ports) != 3:
                raise ValueError(
                    "application_container_port, proxy_listener_port, and admin_port must be distinct"
                )
            return self

        if self.mode == "application_native":
            self.proxy_listener_port = None
            self.admin_port = None
            return self

        return self


def disabled_telemetry() -> HttpTelemetryConfig:
    return HttpTelemetryConfig()


def telemetry_columns(config: HttpTelemetryConfig) -> dict:
    normalized = HttpTelemetryConfig.model_validate(config)
    return {
        "telemetry_enabled": normalized.enabled,
        "telemetry_mode": normalized.mode,
        "application_protocol": normalized.application_protocol,
        "application_container_port": normalized.application_container_port,
        "telemetry_proxy_listener_port": normalized.proxy_listener_port,
        "telemetry_admin_port": normalized.admin_port,
    }
