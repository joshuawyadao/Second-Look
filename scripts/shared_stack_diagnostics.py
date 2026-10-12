"""Bounded, credential-safe hints for a failed local Supabase startup.

The source log stays in the private temporary directory. Only messages from
this fixed table may appear in terminal or CI output.
"""
from __future__ import annotations

from pathlib import Path
import re

MAX_DIAGNOSTIC_BYTES = 128 * 1024

_PATTERNS = {
    "docker": (
        rb"cannot connect to the docker daemon",
        rb"is the docker daemon running",
        rb"docker daemon is not running",
        rb"error during connect",
        rb"local docker adapter failed",
        rb"client version.{0,120}is too old",
        rb"api version.{0,120}(?:not supported|too (?:old|new))",
        rb"unsupported (?:docker )?api version",
    ),
    "image": (
        rb"failed to pull image",
        rb"error pulling image",
        rb"pull access denied",
        rb"failed to resolve reference",
        rb"failed to (?:fetch|do request).{0,160}(?:registry|docker\.io)",
    ),
    "port": (
        rb"port is already allocated",
        rb"ports are not available",
        rb"address already in use",
        rb"bind for .{0,120} failed: port",
    ),
    "health": (
        rb"database is (?:not healthy|unhealthy)",
        rb"timed out waiting for (?:health checks|postgres|database)",
        rb"health check failed",
        rb"container .{0,120} is unhealthy",
    ),
    "migration": (
        rb"(?:error|failed) applying migration",
        rb"failed to apply migration",
        rb"migration .{0,120} failed",
    ),
    "database_connection": (
        rb"(?:failed|unable) to connect to (?:postgres|postgresql|the database)",
        rb"could not connect to (?:postgres|postgresql|the database)",
        rb"password authentication failed for user [\"']?postgres[\"']?",
        rb"(?:postgres|postgresql).{0,120}connection refused",
    ),
    "cli_configuration": (
        rb"unknown flag: --(?:network-id|exclude)",
        rb"failed to parse (?:supabase )?config",
        rb"(?:invalid|malformed) (?:supabase/)?config\.toml",
        rb"config\.toml.{0,120}(?:invalid|malformed)",
    ),
}

_MESSAGES = {
    "docker": "Docker availability or API compatibility; check the local Docker engine and CLI.",
    "image": "Container image pull or registry access; check local registry connectivity.",
    "port": "Local port conflict; check the configured test ports.",
    "health": "Database or container health timeout; inspect the private stack log.",
    "migration": "Database migration failure; inspect the private stack log.",
    "database_connection": "Database connection or authentication failure; inspect the private stack log.",
    "cli_configuration": "Supabase CLI or project configuration failure; inspect the private stack log.",
    "unknown": "Cause not identified; inspect the private stack log.",
}

_LABELS = {
    "docker": "Docker/API",
    "image": "image/registry",
    "port": "port",
    "health": "health",
    "migration": "migration",
    "database_connection": "database connection/authentication",
    "cli_configuration": "CLI/configuration",
}


def _matching_families(log_path: Path) -> tuple[str, ...] | None:
    """Return fixed pattern families, or None when the private log is unavailable."""
    try:
        with log_path.open("rb") as log:
            log.seek(0, 2)
            log.seek(max(0, log.tell() - MAX_DIAGNOSTIC_BYTES))
            sample = log.read(MAX_DIAGNOSTIC_BYTES)
    except OSError:
        return None
    return tuple(sorted(family for family, patterns in _PATTERNS.items()
                        if any(re.search(pattern, sample, re.IGNORECASE) for pattern in patterns)))


def classify_startup_log(log_path: Path) -> str:
    """Return one known family only when a bounded log tail is unambiguous."""
    matches = _matching_families(log_path)
    return matches[0] if matches is not None and len(matches) == 1 else "unknown"


def startup_failure_message(log_path: Path) -> str:
    """Never interpolate log content, file paths, or subprocess exceptions."""
    matches = _matching_families(log_path)
    if matches is None:
        hint = "Private stack log unavailable; cause not identified."
    elif len(matches) > 1:
        hint = "Multiple known failure signals (" + ", ".join(_LABELS[family] for family in matches) + "); inspect the private stack log."
    else:
        hint = _MESSAGES[matches[0] if matches else "unknown"]
    return "Local Supabase startup failed: " + hint
