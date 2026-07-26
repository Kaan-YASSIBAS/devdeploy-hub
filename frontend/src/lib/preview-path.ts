export function normalizePreviewPath(value: string) {
  const candidate = value.trim();
  if (!candidate) return "/";
  const lowered = candidate.toLowerCase().replace(/^\/+/, "");
  if (
    candidate.length > 2048 ||
    candidate.startsWith("//") ||
    lowered.startsWith("http://") ||
    lowered.startsWith("https://") ||
    candidate.includes("\\") ||
    candidate.startsWith("?") ||
    candidate.startsWith("#") ||
    candidate.includes("?") ||
    candidate.includes("#")
  ) {
    return null;
  }

  let decoded = candidate;
  for (let index = 0; index < 3; index += 1) {
    try {
      const nextValue = decodeURIComponent(decoded);
      if (nextValue === decoded) break;
      decoded = nextValue;
    } catch {
      return null;
    }
  }

  const decodedLowered = decoded.toLowerCase().replace(/^\/+/, "");
  if (
    decoded.startsWith("//") ||
    decodedLowered.startsWith("http://") ||
    decodedLowered.startsWith("https://") ||
    decoded.includes("\\") ||
    decoded.includes("?") ||
    decoded.includes("#")
  ) {
    return null;
  }

  const normalized = decoded.replace(/^\/+/, "");
  if (!normalized) return "/";
  if (normalized.split("/").some((segment) => segment === "." || segment === "..")) {
    return null;
  }
  return `/${normalized}`;
}
