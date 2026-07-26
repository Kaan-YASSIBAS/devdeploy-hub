from urllib.parse import unquote, urlsplit

MAX_PREVIEW_PATH_LENGTH = 2048
DEFAULT_PREVIEW_PATH = "/"


def normalize_preview_path(value: str | None) -> str:
    if value is None:
        return DEFAULT_PREVIEW_PATH
    candidate = value.strip()
    if candidate == "":
        return DEFAULT_PREVIEW_PATH
    _reject_unsafe_preview_path(candidate)

    decoded = candidate
    for _ in range(3):
        next_value = unquote(decoded)
        if next_value == decoded:
            break
        decoded = next_value
    _reject_unsafe_preview_path(decoded)

    parsed = urlsplit(decoded)
    if parsed.scheme or parsed.netloc:
        raise ValueError("preview path cannot specify a target URL")
    if parsed.query or parsed.fragment or decoded.startswith(("?", "#")):
        raise ValueError("preview path cannot include query strings or fragments")

    normalized = decoded.lstrip("/")
    if any(segment in {".", ".."} for segment in normalized.split("/")):
        raise ValueError("preview path traversal is not allowed")
    if normalized == "":
        return DEFAULT_PREVIEW_PATH
    return f"/{normalized}"


def preview_path_to_route_suffix(value: str | None) -> str:
    normalized = normalize_preview_path(value)
    return "" if normalized == DEFAULT_PREVIEW_PATH else normalized.lstrip("/")


def _reject_unsafe_preview_path(value: str) -> None:
    lowered = value.lower().lstrip("/")
    if (
        len(value) > MAX_PREVIEW_PATH_LENGTH
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
        or "\\" in value
        or value.startswith("//")
        or lowered.startswith("http://")
        or lowered.startswith("https://")
    ):
        raise ValueError("preview path is invalid")
