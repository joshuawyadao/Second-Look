"""Private, UUID-scoped localhost Supabase inputs for one connected smoke run."""
from __future__ import annotations

from dataclasses import dataclass
import copy
import json
import os
from pathlib import Path
import re
import socket
import tomllib
import uuid


TOKEN = re.compile(r"[0-9a-f]{16}\Z")
PROJECT_PREFIX = "secondlook-m2-smoke-"
NETWORK_PREFIX = "secondlook_m2_smoke_"
REQUIRED_SERVICES = ("db", "kong", "auth", "rest")


@dataclass(frozen=True)
class Scope:
    token: str
    project: str
    network: str
    workdir: Path
    api_port: int
    db_port: int
    shadow_port: int
    server_port: int

    def validate(self) -> None:
        if not TOKEN.fullmatch(self.token):
            raise ValueError("Invalid ephemeral scope token")
        if self.project != PROJECT_PREFIX + self.token or self.network != NETWORK_PREFIX + self.token:
            raise ValueError("Invalid ephemeral project or network")
        if len({self.api_port, self.db_port, self.shadow_port, self.server_port}) != 4 or any(
                type(port) is not int or not 1024 <= port <= 65535 for port in
                (self.api_port, self.db_port, self.shadow_port, self.server_port)):
            raise ValueError("Invalid ephemeral loopback ports")


def selected_ports() -> tuple[int, int, int, int]:
    listeners = []
    try:
        for _ in range(4):
            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listeners.append(listener)
            listener.bind(("127.0.0.1", 0))
        return tuple(listener.getsockname()[1] for listener in listeners)
    finally:
        for listener in listeners:
            listener.close()


def prepare(root: Path, private_directory: Path) -> Scope:
    """Copy reviewed config/migrations only; never inherit .temp, backups or links."""
    token = uuid.uuid4().hex[:16]
    workdir = private_directory / "ephemeral-workdir"
    workdir.mkdir(mode=0o700)
    supabase = workdir / "supabase"
    supabase.mkdir(mode=0o700)
    api, db, shadow, server = selected_ports()
    scope = Scope(token, PROJECT_PREFIX + token, NETWORK_PREFIX + token,
                  workdir, api, db, shadow, server)
    scope.validate()
    source = root / "supabase/config.toml"
    if source.is_symlink() or not source.is_file():
        raise ValueError("Reviewed Supabase config unavailable")
    original = source.read_text()
    parsed = tomllib.loads(original)
    if parsed["project_id"] != "secondlook-m2-local" or parsed["api"]["port"] != 56321 or \
            parsed["db"]["port"] != 56322 or parsed["db"]["shadow_port"] != 56320 or \
            parsed["auth"]["site_url"] != "http://127.0.0.1:8080" or parsed["db"]["seed"]["enabled"] is not False:
        raise ValueError("Reviewed Supabase config anchors changed")
    replacements = {
        'project_id = "secondlook-m2-local"': f'project_id = "{scope.project}"',
        "port = 56321": f"port = {scope.api_port}",
        "port = 56322": f"port = {scope.db_port}",
        "shadow_port = 56320": f"shadow_port = {scope.shadow_port}",
        'site_url = "http://127.0.0.1:8080"': f'site_url = "http://127.0.0.1:{scope.server_port}"',
    }
    generated = original
    for old, new in replacements.items():
        if generated.count(old) != 1:
            raise ValueError("Reviewed Supabase config anchor count changed")
        generated = generated.replace(old, new)
    expected = copy.deepcopy(parsed)
    expected["project_id"] = scope.project
    expected["api"]["port"] = scope.api_port
    expected["db"]["port"] = scope.db_port
    expected["db"]["shadow_port"] = scope.shadow_port
    expected["auth"]["site_url"] = f"http://127.0.0.1:{scope.server_port}"
    if tomllib.loads(generated) != expected:
        raise ValueError("Generated Supabase config has unexpected changes")
    (supabase / "config.toml").write_text(generated)
    migrations = root / "supabase/migrations"
    if migrations.is_symlink() or not migrations.is_dir():
        raise ValueError("Reviewed migration directory unavailable")
    target = supabase / "migrations"
    target.mkdir(mode=0o700)
    files = sorted(migrations.glob("*.sql"))
    if not files:
        raise ValueError("Reviewed migrations unavailable")
    for path in files:
        if path.is_symlink() or not path.is_file() or not re.fullmatch(r"\d{12,14}_[a-z0-9_]+\.sql", path.name):
            raise ValueError("Reviewed migration path unavailable")
        data = path.read_bytes()
        (target / path.name).write_bytes(data)
        if (target / path.name).read_bytes() != data:
            raise ValueError("Generated migration copy changed")
    (workdir / "scope.private.json").write_text(json.dumps({
        "kind": "secondlook-ephemeral-v1", "project": scope.project,
        "network": scope.network, "token": scope.token,
        "ports": [scope.api_port, scope.db_port, scope.shadow_port, scope.server_port],
    }, sort_keys=True))
    os.chmod(workdir / "scope.private.json", 0o600)
    return scope


def metadata_matches(scope: Scope) -> bool:
    scope.validate()
    try:
        value = json.loads((scope.workdir / "scope.private.json").read_text())
    except (OSError, ValueError):
        return False
    return value == {"kind": "secondlook-ephemeral-v1", "project": scope.project,
                     "network": scope.network, "token": scope.token,
                     "ports": [scope.api_port, scope.db_port, scope.shadow_port, scope.server_port]}


def approved_volume(scope: Scope, name: object) -> bool:
    """The pinned local stack's persistent database volume must be new to this run."""
    return name == f"supabase_db_{scope.project}"


def approved_private_file(scope: Scope, source: object) -> bool:
    if not isinstance(source, str):
        return False
    path = Path(source)
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        return False
    if ".." in path.parts:
        return False
    try:
        relative = path.resolve(strict=True).relative_to(scope.workdir.resolve(strict=True))
    except (ValueError, OSError):
        return False
    if not relative.parts or any((scope.workdir / Path(*relative.parts[:index])).is_symlink()
                                 for index in range(1, len(relative.parts))):
        return False
    return True


def approved_mount(scope: Scope, kind: object, source: object, read_only: object) -> bool:
    if kind == "volume":
        return approved_volume(scope, source)
    if kind == "bind":
        return read_only is True and approved_private_file(scope, source)
    return False


def create_mounts_are_approved(scope: Scope, payload: object) -> bool:
    """Reject volume inheritance, anonymous volumes and every foreign host source."""
    if not isinstance(payload, dict) or payload.get("Volumes") or payload.get("Mounts"):
        return False
    host = payload.get("HostConfig")
    if not isinstance(host, dict) or host.get("VolumesFrom") or host.get("Tmpfs"):
        return False
    binds = host.get("Binds") or []
    mounts = host.get("Mounts") or []
    if not isinstance(binds, list) or not isinstance(mounts, list):
        return False
    for bind in binds:
        if not isinstance(bind, str):
            return False
        parts = bind.split(":")
        if len(parts) not in (2, 3) or not parts[0] or not parts[1]:
            return False
        mode = parts[2].split(",") if len(parts) == 3 else []
        kind = "bind" if parts[0].startswith("/") else "volume"
        if (mode != ["ro"] if kind == "bind" else mode not in ([], ["ro"], ["rw"])) or \
                not approved_mount(scope, kind, parts[0], mode == ["ro"]):
            return False
    for mount in mounts:
        if not isinstance(mount, dict) or not approved_mount(
                scope, mount.get("Type"), mount.get("Source"), mount.get("ReadOnly", False)):
            return False
    return True


def inspected_mounts_are_approved(scope: Scope, mounts: object) -> bool:
    if not isinstance(mounts, list):
        return False
    for mount in mounts:
        if not isinstance(mount, dict):
            return False
        source = mount.get("Name") if mount.get("Type") == "volume" else mount.get("Source")
        if not approved_mount(scope, mount.get("Type"), source, not mount.get("RW", True)):
            return False
    return True
