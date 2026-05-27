import re

from app.services.observability_errors import ObservabilityUnavailableError


DNS_LABEL_PATTERN = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
DNS_SUBDOMAIN_PATTERN = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$")
ALLOWED_METRIC_RANGES = {"5m", "15m", "30m", "1h", "6h", "24h", "7d"}
ALLOWED_METRIC_STEPS = {"15s", "30s", "1m", "5m", "15m", "1h"}


def validate_namespace(value: str) -> str:
    namespace = value.strip()
    if not namespace or len(namespace) > 63 or not DNS_LABEL_PATTERN.fullmatch(namespace):
        raise ObservabilityUnavailableError("namespace must be a valid Kubernetes DNS label")
    return namespace


def validate_optional_namespace(value: str | None) -> str | None:
    if value is None:
        return None
    return validate_namespace(value)


def validate_pod_name(value: str) -> str:
    pod_name = value.strip()
    if (
        not pod_name
        or len(pod_name) > 253
        or not DNS_SUBDOMAIN_PATTERN.fullmatch(pod_name)
        or any(len(label) > 63 for label in pod_name.split("."))
    ):
        raise ObservabilityUnavailableError("pod must be a valid Kubernetes DNS name")
    return pod_name


def validate_metric_range(value: str) -> str:
    range_value = value.strip()
    if range_value not in ALLOWED_METRIC_RANGES:
        allowed = ", ".join(sorted(ALLOWED_METRIC_RANGES))
        raise ObservabilityUnavailableError(f"range must be one of: {allowed}")
    return range_value


def validate_metric_step(value: str | None) -> str | None:
    if value is None:
        return None
    step_value = value.strip()
    if step_value not in ALLOWED_METRIC_STEPS:
        allowed = ", ".join(sorted(ALLOWED_METRIC_STEPS))
        raise ObservabilityUnavailableError(f"step must be one of: {allowed}")
    return step_value


def escape_label_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')
