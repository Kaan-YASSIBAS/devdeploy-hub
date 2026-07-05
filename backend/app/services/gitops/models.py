from dataclasses import dataclass
import re

from app.services.gitops.errors import GitOpsWriterError


APP_NAME_PATTERN = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
CONTROL_CHARACTER_PATTERN = re.compile(r"[\x00-\x1f\x7f]")
MAX_APP_NAME_LENGTH = 40
MAX_NAMESPACE_LENGTH = 63
MAX_REPLICAS = 20
MIN_PORT = 1
MAX_PORT = 65535


def validate_app_name(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise GitOpsWriterError("invalid_app_name", "App name is required.")
    if value in {".", ".."} or value.startswith("."):
        raise GitOpsWriterError("invalid_app_name", "App name is not a supported DNS label.")
    if "/" in value or "\\" in value:
        raise GitOpsWriterError("invalid_app_name", "App name must not contain path separators.")
    if len(value) > MAX_APP_NAME_LENGTH or not APP_NAME_PATTERN.fullmatch(value):
        raise GitOpsWriterError("invalid_app_name", "App name is not a supported DNS label.")
    return value


def validate_image(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise GitOpsWriterError("invalid_image", "Container image is required.")
    if any(character.isspace() for character in value) or CONTROL_CHARACTER_PATTERN.search(value):
        raise GitOpsWriterError("invalid_image", "Container image contains unsupported characters.")
    return value


def validate_namespace(value: object) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > MAX_NAMESPACE_LENGTH
        or not APP_NAME_PATTERN.fullmatch(value)
    ):
        raise GitOpsWriterError("invalid_namespace", "Namespace is not a supported DNS label.")
    return value


def validate_replicas(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MAX_REPLICAS:
        raise GitOpsWriterError(
            "invalid_replicas",
            f"Replicas must be an integer from 1 through {MAX_REPLICAS}.",
        )
    return value


def validate_port(value: object, field_name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not MIN_PORT <= value <= MAX_PORT:
        raise GitOpsWriterError(
            "invalid_port",
            f"{field_name} must be an integer from {MIN_PORT} through {MAX_PORT}.",
        )
    return value


@dataclass(frozen=True, slots=True)
class WorkloadWriteRequest:
    app_name: str
    image: str
    replicas: int = 1
    container_port: int = 80
    service_port: int = 80
    service_type: str = "ClusterIP"
    namespace: str = "devdeploy-apps"

    def __post_init__(self) -> None:
        validate_app_name(self.app_name)
        validate_image(self.image)
        validate_namespace(self.namespace)
        validate_replicas(self.replicas)
        validate_port(self.container_port, "Container port")
        validate_port(self.service_port, "Service port")
        if self.service_type != "ClusterIP":
            raise GitOpsWriterError(
                "invalid_service_type",
                "Service type must be ClusterIP in V1.",
            )
