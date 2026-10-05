#!/usr/bin/env python3
"""Run local Supabase through a private Unix proxy that enforces loopback port bindings.

The pinned CLI supplies an explicit wildcard HostIp, overriding Docker network
host_binding_ipv4 defaults. This adapter changes only container-create requests
for our named synthetic project. No Docker daemon or user context is modified.
"""
from __future__ import annotations
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingMixIn, UnixStreamServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

PROJECT = "secondlook-m2-local"


def bind_create(path: str, data: bytes) -> bytes:
    parts = urlsplit(path)
    name = parse_qs(parts.query).get("name", [""])[0]
    if not parts.path.endswith("/containers/create"):
        return data
    if not (name.startswith("supabase_") and name.endswith("_" + PROJECT)):
        raise ValueError("Local test launcher refused an unrelated container creation.")
    payload = json.loads(data)
    for bindings in payload.get("HostConfig", {}).get("PortBindings", {}).values():
        for binding in bindings:
            binding["HostIp"] = "127.0.0.1"
    return json.dumps(payload, separators=(",", ":")).encode()


def read_chunked(stream, limit: int = 8 * 1024 * 1024) -> bytes:
    body = bytearray()
    while True:
        header = stream.readline(256)
        size = int(header.split(b";", 1)[0].strip(), 16)
        if size < 0 or len(body) + size > limit:
            raise ValueError("Unexpected Docker request size.")
        if size == 0:
            while stream.readline(8192) not in (b"\r\n", b""):
                pass
            return bytes(body)
        chunk = stream.read(size)
        if len(chunk) != size or stream.read(2) != b"\r\n":
            raise ValueError("Incomplete Docker request body.")
        body.extend(chunk)


def main(arguments: list[str]) -> int:
    if not arguments:
        raise ValueError("Supply the local CLI command.")
    # This workflow supports a local Unix Docker socket only, never a remote host.
    host = os.environ.get("DOCKER_HOST")
    if host is None:
        context = subprocess.check_output(["docker", "context", "inspect"])
        host = json.loads(context)[0]["Endpoints"]["docker"]["Host"]
    if not host.startswith("unix://"):
        raise ValueError("Local test launcher requires a Unix Docker socket.")
    upstream = host.removeprefix("unix://")
    directory = tempfile.TemporaryDirectory(prefix="secondlook-docker-")
    proxy_path = str(Path(directory.name) / "docker.sock")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *_):
            pass  # Requests/headers can contain server credentials.

        def forward(self):
            self.close_connection = True
            try:
                if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                    body = read_chunked(self.rfile)
                elif self.headers.get("Transfer-Encoding"):
                    raise ValueError("Unsupported Docker transfer encoding.")
                else:
                    length = int(self.headers.get("Content-Length", "0"))
                    if length < 0 or length > 8 * 1024 * 1024:
                        raise ValueError("Unexpected Docker request size.")
                    body = self.rfile.read(length)
                if self.command == "POST":
                    body = bind_create(self.path, body)
                headers = {key: value for key, value in self.headers.items()
                           if key.lower() not in ("content-length", "connection", "transfer-encoding")}
                headers["Connection"] = "close"
                headers["Content-Length"] = str(len(body))
                head = f"{self.command} {self.path} HTTP/1.1\r\n" + "".join(
                    f"{key}: {value}\r\n" for key, value in headers.items()) + "\r\n"
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                    stream.settimeout(300)
                    stream.connect(upstream)
                    stream.sendall(head.encode() + body)
                    while chunk := stream.recv(65536):
                        self.connection.sendall(chunk)
            except (ValueError, OSError):
                # Static message only. Never echo a Docker request or response.
                try:
                    self.send_error(502, "Local Docker adapter failed")
                except OSError:
                    pass

        do_GET = forward
        do_POST = forward
        do_PUT = forward
        do_DELETE = forward
        do_HEAD = forward

    class Server(ThreadingMixIn, UnixStreamServer):
        daemon_threads = True

    server = Server(proxy_path, Handler)
    os.chmod(proxy_path, 0o600)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        return subprocess.run(arguments, env=dict(os.environ, DOCKER_HOST="unix://" + proxy_path)).returncode
    finally:
        server.shutdown()
        server.server_close()
        directory.cleanup()


if __name__ == "__main__":
    os.umask(0o077)
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ValueError:
        print("Local Docker launcher configuration is invalid.", file=sys.stderr)
        raise SystemExit(1)
