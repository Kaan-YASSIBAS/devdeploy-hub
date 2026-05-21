#!/usr/bin/env python3
"""Promote DevDeploy Hub release overlay images to a semantic image tag."""

from __future__ import annotations

import re
import sys
from pathlib import Path


TAG_PATTERN = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
NEW_NAME_PATTERN = re.compile(r"^(\s*)newName:\s*(\S+)\s*$")
NEW_TAG_PATTERN = re.compile(r"^(\s*)newTag:\s*(\S+)\s*$")

REPO_ROOT = Path(__file__).resolve().parents[1]
KUSTOMIZATION_PATH = REPO_ROOT / "infra/kubernetes/overlays/release/kustomization.yaml"

EXPECTED_IMAGES = {
    "ghcr.io/kaan-yassibas/devdeploy-backend": "backend",
    "ghcr.io/kaan-yassibas/devdeploy-frontend": "frontend",
}


def update_image_tags(image_tag: str) -> dict[str, str]:
    if not TAG_PATTERN.fullmatch(image_tag):
        raise ValueError("image tag must match vMAJOR.MINOR.PATCH, for example v1.1.0")

    lines = KUSTOMIZATION_PATH.read_text(encoding="utf-8").splitlines(keepends=True)
    updated_lines: list[str] = []
    pending_image: str | None = None
    old_tags: dict[str, str] = {}

    for line in lines:
        new_name_match = NEW_NAME_PATTERN.match(line.rstrip("\r\n"))
        if new_name_match:
            image_name = new_name_match.group(2)
            pending_image = image_name if image_name in EXPECTED_IMAGES else None
            updated_lines.append(line)
            continue

        new_tag_match = NEW_TAG_PATTERN.match(line.rstrip("\r\n"))
        if pending_image and new_tag_match:
            indent = new_tag_match.group(1)
            old_tags[pending_image] = new_tag_match.group(2)
            newline = "\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else ""
            updated_lines.append(f"{indent}newTag: {image_tag}{newline}")
            pending_image = None
            continue

        updated_lines.append(line)

    missing_images = sorted(set(EXPECTED_IMAGES) - set(old_tags))
    if missing_images:
        missing = ", ".join(missing_images)
        raise RuntimeError(f"expected image tag entries were not found: {missing}")

    KUSTOMIZATION_PATH.write_text("".join(updated_lines), encoding="utf-8")
    return old_tags


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python scripts/promote-release-images.py vMAJOR.MINOR.PATCH", file=sys.stderr)
        return 2

    image_tag = sys.argv[1]
    try:
        old_tags = update_image_tags(image_tag)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    for image_name, old_tag in sorted(old_tags.items()):
        label = EXPECTED_IMAGES[image_name]
        print(f"{label}: {image_name}:{old_tag} -> {image_name}:{image_tag}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
