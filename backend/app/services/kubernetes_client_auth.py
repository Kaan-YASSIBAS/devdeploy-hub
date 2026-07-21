from kubernetes import client
from kubernetes.config.config_exception import ConfigException


def configure_bearer_token_refresh(
    configuration: client.Configuration,
    *,
    required: bool = False,
) -> None:
    """Keep generated-client BearerToken auth synchronized after token refreshes."""
    original_refresh = configuration.refresh_api_key_hook

    def refresh(current: client.Configuration) -> None:
        if original_refresh is not None:
            original_refresh(current)
            current.refresh_api_key_hook = refresh
        _synchronize_bearer_token(current, required=required)

    if original_refresh is not None:
        configuration.refresh_api_key_hook = refresh
        refresh(configuration)
    else:
        _synchronize_bearer_token(configuration, required=required)


def _synchronize_bearer_token(
    configuration: client.Configuration,
    *,
    required: bool,
) -> None:
    authorization = (
        configuration.api_key.get("authorization")
        or configuration.api_key.get("BearerToken")
    )
    if not authorization:
        if required:
            raise ConfigException("Kubernetes bearer token was not loaded")
        return

    token = authorization.strip()
    while token.lower().startswith("bearer "):
        token = token[7:].strip()
    if not token:
        if required:
            raise ConfigException("Kubernetes bearer token was empty")
        return

    configuration.api_key["authorization"] = token
    configuration.api_key_prefix["authorization"] = "Bearer"
    configuration.api_key["BearerToken"] = token
    configuration.api_key_prefix["BearerToken"] = "Bearer"
