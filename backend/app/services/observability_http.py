import json
from typing import Any

import httpx

from app.core.config import settings
from app.services.observability_errors import ObservabilityUnavailableError


QUERY_TIMEOUT = httpx.Timeout(timeout=5.0, connect=2.0, read=5.0, write=5.0, pool=2.0)
RANGE_QUERY_TIMEOUT = httpx.Timeout(timeout=8.0, connect=2.0, read=8.0, write=5.0, pool=2.0)


def get_bounded_json(
    url: str,
    *,
    params: dict[str, Any] | None,
    timeout: httpx.Timeout,
    service_name: str,
) -> dict[str, Any]:
    with httpx.stream("GET", url, params=params, timeout=timeout, follow_redirects=False) as response:
        response.raise_for_status()

        content_length = response.headers.get("content-length")
        if content_length:
            try:
                if int(content_length) > settings.observability_max_response_bytes:
                    raise ObservabilityUnavailableError(f"{service_name} returned a response that is too large.")
            except ValueError:
                raise ObservabilityUnavailableError(f"{service_name} returned an invalid response size.") from None

        content_type = response.headers.get("content-type", "")
        if content_type and "json" not in content_type.lower():
            raise ObservabilityUnavailableError(f"{service_name} returned an unsupported response type.")

        body = bytearray()
        for chunk in response.iter_bytes():
            body.extend(chunk)
            if len(body) > settings.observability_max_response_bytes:
                raise ObservabilityUnavailableError(f"{service_name} returned a response that is too large.")

    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise ObservabilityUnavailableError(f"{service_name} returned a malformed response.") from exc
    if not isinstance(payload, dict):
        raise ObservabilityUnavailableError(f"{service_name} returned a malformed response.")
    return payload
