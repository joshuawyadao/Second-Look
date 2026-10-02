#!/usr/bin/env python3
"""Check the public repository's files and local Markdown references.

Adapted from BoardBot's MIT-licensed repository verifier (Joshua Yadao, 2026).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


REQUIRED_FILES = (
    "README.md",
    "LICENSE",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "CODE_OF_CONDUCT.md",
    "AGENTS.md",
    ".gitignore",
    ".editorconfig",
    "docs/Implementation-Plan.md",
    "docs/Product-Brief.md",
    "docs/Verification.md",
    ".github/workflows/ci.yml",
    ".github/dependabot.yml",
    ".github/pull_request_template.md",
    ".github/ISSUE_TEMPLATE/bug_report.yml",
    ".github/ISSUE_TEMPLATE/feature_request.yml",
    ".github/ISSUE_TEMPLATE/config.yml",
    "scripts/verify_repository.py",
    "scripts/verify-repository.sh",
    "tests/test_verify_repository.py",
)

PRIVATE_DIRS = {"private", "local-data", "photos", "uploads", "logs", "outputs"}
CACHE_DIRS = {"__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".venv", "node_modules"}
PRIVATE_SUFFIXES = {".key", ".pem", ".p8", ".p12", ".pfx", ".mobileprovision"}
GENERATED_SUFFIXES = {".pyc", ".pyo"}
LINK = re.compile(r"!?\[[^\]]*\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+[^)]*)?\)")


def inventory(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return [Path(name.decode("utf-8", "surrogateescape")) for name in result.stdout.split(b"\0") if name]


def is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
        return True
    except (OSError, ValueError):
        return False


def unsafe_reason(path: Path) -> str | None:
    parts = {part.lower() for part in path.parts[:-1]}
    name = path.name.lower()
    if parts & PRIVATE_DIRS:
        return "private local data"
    if parts & CACHE_DIRS or name in {".ds_store", ".coverage"} or path.suffix.lower() in GENERATED_SUFFIXES:
        return "generated cache"
    if name == ".env" or (name.startswith(".env.") and name not in {".env.example", ".env.template"}):
        return "private credential"
    if (path.suffix.lower() in PRIVATE_SUFFIXES or ".private." in name
            or re.fullmatch(r"(?:credentials|secrets)[^/]*\.json", name)):
        return "private credential"
    return None


def markdown_targets(content: str):
    for match in LINK.finditer(content):
        target = match.group(1)
        yield target[1:-1] if target.startswith("<") else target


def verify(root: Path) -> list[str]:
    errors: list[str] = []
    root = root.resolve()
    try:
        paths = inventory(root)
    except (OSError, subprocess.CalledProcessError) as exc:
        return [f"Cannot read Git file inventory: {exc}"]

    for relative in REQUIRED_FILES:
        path = root / relative
        if not path.is_file() or not is_within(path, root):
            errors.append(f"Missing or unsafe required file: {relative}")
        elif path.stat().st_size == 0:
            errors.append(f"Empty required file: {relative}")

    for relative in paths:
        path = root / relative
        if not path.exists() or not is_within(path, root):
            errors.append(f"Missing or unsafe Git file: {relative}")
            continue
        reason = unsafe_reason(relative)
        if reason:
            errors.append(f"{reason.capitalize()} in Git inventory: {relative}")
        if relative.suffix.lower() != ".md" or not path.is_file():
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            errors.append(f"Cannot read Markdown file {relative}: {exc}")
            continue
        for target in markdown_targets(content):
            if not target or target.startswith("#") or target.startswith("//"):
                continue
            parsed = urlsplit(target)
            if parsed.scheme or parsed.netloc:
                continue
            location = unquote(parsed.path)
            if not location:
                continue
            destination = path.parent / location
            if not destination.exists() or not is_within(destination, root):
                errors.append(f"Broken or unsafe Markdown link in {relative}: {target}")
    return sorted(set(errors))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    errors = verify(args.root)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Repository verification passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
