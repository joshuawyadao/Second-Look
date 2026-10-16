"""Bounded, credential-safe hints for a failed local Supabase startup.

The source log stays in the private temporary directory. Only messages from
this fixed table may appear in terminal or CI output.
"""
from __future__ import annotations

from pathlib import Path
import re

MAX_DIAGNOSTIC_BYTES = 128 * 1024

_ADAPTER_PHASE_MESSAGES = {
    "container_scope": "Local Docker adapter rejected a container outside the synthetic project scope.",
    "request": "Local Docker adapter rejected a malformed or oversized request.",
    "upstream_connect": "Local Docker adapter could not connect to the upstream Unix socket.",
    "upstream_send": "Local Docker adapter could not send the request upstream.",
    "response_read": "Local Docker adapter could not read a valid upstream response.",
    "downstream_write": "Local Docker adapter could not write the response to the CLI.",
}
_ADAPTER_PHASE_PATTERNS = {
    phase: rb"(?m)^Local Docker adapter phase: " + phase.encode() + rb"\r?$"
    for phase in _ADAPTER_PHASE_MESSAGES
}

_DOCKER_SUBREASONS = {
    "daemon": (
        rb"cannot connect to the docker daemon",
        rb"is the docker daemon running",
        rb"docker daemon is not running",
        rb"error during connect",
    ),
    "client_api": (rb"client version.{0,120}is too old",),
    "unsupported_api": (
        rb"api version.{0,120}(?:not supported|too (?:old|new))",
        rb"unsupported (?:docker )?api version",
    ),
    "adapter": (rb"local docker adapter failed",) + tuple(_ADAPTER_PHASE_PATTERNS.values()),
}

_PATTERNS = {
    "docker": tuple(pattern for patterns in _DOCKER_SUBREASONS.values() for pattern in patterns),
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

_DOCKER_MESSAGES = {
    "daemon": "Docker daemon unavailable or unreachable; check the local Docker engine.",
    "client_api": "Docker client API too old for the daemon; check client and daemon compatibility.",
    "unsupported_api": "Docker API version unsupported; check client and daemon compatibility.",
    "adapter": "Local Docker adapter failed; inspect the private stack log.",
}


def _log_tail(log_path: Path) -> bytes | None:
    """Read only bounded private log bytes, or None when unavailable."""
    try:
        with log_path.open("rb") as log:
            log.seek(0, 2)
            log.seek(max(0, log.tell() - MAX_DIAGNOSTIC_BYTES))
            return log.read(MAX_DIAGNOSTIC_BYTES)
    except OSError:
        return None


def _matching_families(sample: bytes) -> tuple[str, ...]:
    """Return only fixed pattern family names, sorted for stable reporting."""
    return tuple(sorted(family for family, patterns in _PATTERNS.items()
                        if any(re.search(pattern, sample, re.IGNORECASE) for pattern in patterns)))


def classify_startup_log(log_path: Path) -> str:
    """Return one known family only when a bounded log tail is unambiguous."""
    sample = _log_tail(log_path)
    matches = _matching_families(sample) if sample is not None else ()
    return matches[0] if len(matches) == 1 else "unknown"


def startup_failure_message(log_path: Path) -> str:
    """Never interpolate log content, file paths, or subprocess exceptions."""
    sample = _log_tail(log_path)
    matches = _matching_families(sample) if sample is not None else ()
    if sample is None:
        hint = "Private stack log unavailable; cause not identified."
    elif len(matches) > 1:
        hint = "Multiple known failure signals (" + ", ".join(_LABELS[family] for family in matches) + "); inspect the private stack log."
    elif matches == ("docker",):
        subreasons = [name for name, patterns in _DOCKER_SUBREASONS.items()
                      if any(re.search(pattern, sample, re.IGNORECASE) for pattern in patterns)]
        if subreasons == ["adapter"]:
            observed = [(match.start(), name)
                        for name, pattern in _ADAPTER_PHASE_PATTERNS.items()
                        if (match := re.search(pattern, sample, re.IGNORECASE))]
            phases = [name for _, name in sorted(observed)]
            if len(phases) == 1:
                hint = _ADAPTER_PHASE_MESSAGES[phases[0]]
            elif phases:
                # Names alone come from the whitelist. Their byte positions reveal
                # order in the bounded sample, not the cause of startup failure.
                hint = ("Observed local Docker adapter phases in inspected log tail (" +
                        ", ".join(phases) + "); first observed: " + phases[0] +
                        "; cause unconfirmed; inspect the private stack log.")
            else:
                hint = _DOCKER_MESSAGES["adapter"]
        else:
            hint = (_DOCKER_MESSAGES[subreasons[0]] if len(subreasons) == 1 else
                    "Multiple Docker/API signals or unspecified Docker failure; inspect the private stack log.")
    else:
        hint = _MESSAGES[matches[0] if matches else "unknown"]
    return "Local Supabase startup failed: " + hint
