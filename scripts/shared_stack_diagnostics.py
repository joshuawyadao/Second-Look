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
}

_MESSAGES = {
    "docker": "Docker availability or API compatibility; check the local Docker engine and CLI.",
    "image": "Container image pull or registry access; check local registry connectivity.",
    "port": "Local port conflict; check the configured test ports.",
    "health": "Database or container health timeout; inspect the private stack log.",
    "migration": "Database migration failure; inspect the private stack log.",
    "unknown": "Cause not identified; inspect the private stack log.",
}


def classify_startup_log(log_path: Path) -> str:
    """Return one known family only when a bounded log tail is unambiguous."""
    try:
        with log_path.open("rb") as log:
            log.seek(0, 2)
            log.seek(max(0, log.tell() - MAX_DIAGNOSTIC_BYTES))
            sample = log.read(MAX_DIAGNOSTIC_BYTES)
    except OSError:
        return "unknown"
    matches = {family for family, patterns in _PATTERNS.items()
               if any(re.search(pattern, sample, re.IGNORECASE) for pattern in patterns)}
    return next(iter(matches)) if len(matches) == 1 else "unknown"


def startup_failure_message(log_path: Path) -> str:
    """Never interpolate log content, file paths, or subprocess exceptions."""
    return "Local Supabase startup failed: " + _MESSAGES[classify_startup_log(log_path)]
