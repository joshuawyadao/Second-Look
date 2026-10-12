#!/usr/bin/env python3
"""Run local Supabase through a private Unix proxy that enforces loopback port bindings.

The pinned CLI supplies an explicit wildcard HostIp, overriding Docker network
host_binding_ipv4 defaults. This adapter changes only container-create requests
scoped to our synthetic project. No Docker daemon or user context is modified.
"""
from __future__ import annotations
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingMixIn, UnixStreamServer
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

PROJECT = "secondlook-m2-local"
NETWORK = "secondlook_m2_local"
PROJECT_LABELS = ("com.supabase.cli.project", "com.docker.compose.project")
DOCKER_STREAM_TYPES = frozenset((b"application/vnd.docker.raw-stream",
                                 b"application/vnd.docker.multiplexed-stream"))
ADAPTER_PHASE_MARKERS = {
    "container_scope": "Local Docker adapter phase: container_scope",
    "request": "Local Docker adapter phase: request",
    "upstream_connect": "Local Docker adapter phase: upstream_connect",
    "upstream_send": "Local Docker adapter phase: upstream_send",
    "response_read": "Local Docker adapter phase: response_read",
    "downstream_write": "Local Docker adapter phase: downstream_write",
}


class UnrelatedContainerError(ValueError):
    """A container-create request escaped this synthetic project's scope."""


def report_adapter_phase(phase: str) -> None:
    # Only names from this closed set reach stderr; requests and exceptions stay private.
    print(ADAPTER_PHASE_MARKERS[phase], file=sys.stderr, flush=True)


def bind_create(path: str, data: bytes) -> bytes:
    parts = urlsplit(path)
    name = parse_qs(parts.query).get("name", [""])[0]
    if not parts.path.endswith("/containers/create"):
        return data
    if name and not (name.startswith("supabase_") and name.endswith("_" + PROJECT)):
        raise UnrelatedContainerError("Local test launcher refused an unrelated container creation.")
    payload = json.loads(data)
    if not name:
        if not isinstance(payload, dict):
            raise UnrelatedContainerError("Local test launcher refused an unrelated container creation.")
        labels = payload.get("Labels")
        host_config = payload.get("HostConfig")
        if (not isinstance(labels, dict) or
                not all(labels.get(label) == PROJECT for label in PROJECT_LABELS) or
                not isinstance(host_config, dict) or
                host_config.get("NetworkMode") != NETWORK):
            raise UnrelatedContainerError("Local test launcher refused an unrelated container creation.")
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


def is_docker_stream_route(method: str, path: str) -> bool:
    if method != "POST":
        return False
    route = urlsplit(path).path
    return bool(re.fullmatch(r"/(?:v\d+\.\d+/)?(?:exec/[^/]+/start|containers/[^/]+/attach)", route))


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
            response_started = False
            phase = "request"
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
                wants_upgrade = (bool(self.headers.get("Upgrade")) and
                                 any(token.strip().lower() == "upgrade" for token in
                                     self.headers.get("Connection", "").split(",")))
                headers["Connection"] = "Upgrade" if wants_upgrade else "close"
                headers["Content-Length"] = str(len(body))
                head = f"{self.command} {self.path} HTTP/1.1\r\n" + "".join(
                    f"{key}: {value}\r\n" for key, value in headers.items()) + "\r\n"
                phase = "upstream_connect"
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                    stream.settimeout(300)
                    stream.connect(upstream)
                    phase = "upstream_send"
                    stream.sendall(head.encode() + body)

                    def receive_upstream():
                        nonlocal phase
                        phase = "response_read"
                        return stream.recv(65536)

                    def send_downstream(data):
                        nonlocal phase
                        phase = "downstream_write"
                        self.connection.sendall(data)

                    stream_route = is_docker_stream_route(self.command, self.path)
                    if wants_upgrade or stream_route:
                        response = bytearray()
                        while b"\r\n\r\n" not in response:
                            chunk = receive_upstream()
                            if not chunk:
                                raise OSError("Incomplete upstream response.")
                            response.extend(chunk)
                            if len(response) > 64 * 1024 and b"\r\n\r\n" not in response:
                                raise ValueError("Unexpected upstream response header size.")
                        header_end = response.index(b"\r\n\r\n")
                        if header_end > 64 * 1024:
                            raise ValueError("Unexpected upstream response header size.")
                        lines = bytes(response[:header_end]).split(b"\r\n")
                        status = lines[0].split()
                        content_types = [line.split(b":", 1)[1].strip().split(b";", 1)[0].lower()
                                         for line in lines[1:] if line.lower().startswith(b"content-type:")]
                        hijacked = ((len(status) >= 2 and status[1] == b"101" and wants_upgrade) or
                                    (len(status) >= 2 and status[1] == b"200" and stream_route and
                                     len(content_types) == 1 and content_types[0] in DOCKER_STREAM_TYPES))
                        send_downstream(response)
                        response_started = True
                        if hijacked:
                            def client_to_upstream():
                                try:
                                    while chunk := self.rfile.read1(65536):
                                        try:
                                            stream.sendall(chunk)
                                        except OSError:
                                            report_adapter_phase("upstream_send")
                                            break
                                except OSError:
                                    pass
                                finally:
                                    try:
                                        stream.shutdown(socket.SHUT_WR)
                                    except OSError:
                                        pass

                            sender = threading.Thread(target=client_to_upstream, daemon=True)
                            sender.start()
                            try:
                                while chunk := receive_upstream():
                                    send_downstream(chunk)
                            finally:
                                try:
                                    self.connection.shutdown(socket.SHUT_RD)
                                except OSError:
                                    pass
                                sender.join(timeout=2)
                        else:
                            while chunk := receive_upstream():
                                send_downstream(chunk)
                    else:
                        chunk = receive_upstream()
                        if not chunk:
                            raise OSError("No upstream response.")
                        while chunk:
                            response_started = True
                            send_downstream(chunk)
                            chunk = receive_upstream()
            except (ValueError, OSError) as error:
                # Static message only. Never echo a Docker request or response.
                report_adapter_phase("container_scope" if isinstance(error, UnrelatedContainerError) else phase)
                if not response_started:
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
