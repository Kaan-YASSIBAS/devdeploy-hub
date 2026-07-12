class ObservabilityUnavailableError(RuntimeError):
    """Raised when an external observability backend is not reachable."""


class ObservabilityRestrictedError(ObservabilityUnavailableError):
    """Raised when backend credentials cannot access an observability backend."""


class ObservabilityMalformedResponseError(ObservabilityUnavailableError):
    """Raised when an observability backend responds with unreadable data."""
