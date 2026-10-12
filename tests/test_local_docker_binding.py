"""The local fixture launcher must never publish wildcard ports or mutate another project."""
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "local-docker-binding.py"
spec = importlib.util.spec_from_file_location("local_docker_binding", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LocalDockerBindingTests(unittest.TestCase):
    def _unnamed_bootstrap_payload(self):
        # Docker's create API combines Config fields at the root, with HostConfig beside them.
        return {"Image": "synthetic/migration:local",
                "Labels": {"com.supabase.cli.project": module.PROJECT,
                           "com.docker.compose.project": module.PROJECT},
                "HostConfig": {"NetworkMode": "secondlook_m2_local",
                               "PortBindings": {"5432/tcp": [
                                   {"HostIp": "0.0.0.0", "HostPort": "56322"}]}},
                "Env": ["SYNTHETIC_SECRET=not-a-real-key"]}

    def _failed_proxy_request(self, upstream, request, directory):
        child = r'''
import os, socket, sys
endpoint = os.environ["DOCKER_HOST"].removeprefix("unix://")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(4)
    client.connect(endpoint)
    client.sendall(bytes.fromhex(sys.argv[1]))
    response = bytearray()
    while chunk := client.recv(4096):
        response.extend(chunk)
    sys.exit(0 if b"502" in response.split(b"\r\n", 1)[0] and
             b"Local Docker adapter failed" in response else 3)
'''
        markers = io.StringIO()
        with patch.dict(os.environ, {"DOCKER_HOST": "unix://" + upstream}), \
             patch.object(tempfile, "tempdir", directory), \
             patch.object(sys, "stderr", markers):
            result = module.main([sys.executable, "-c", child, request.hex()])
        self.assertEqual(result, 0)
        return markers.getvalue()

    def test_unrelated_container_is_refused_with_only_fixed_scope_marker(self):
        with tempfile.TemporaryDirectory(prefix="sl-adapter-test-", dir="/tmp") as directory:
            secret = b"sb_secret_SYNTHETIC_ONLY"
            request = (b"POST /v1.48/containers/create?name=another-project HTTP/1.1\r\n"
                       b"Host: docker\r\nX-Secret: " + secret +
                       b"\r\nContent-Length: 2\r\n\r\n{}")
            markers = self._failed_proxy_request(str(Path(directory) / "unused.sock"), request, directory)
        self.assertEqual(markers, module.ADAPTER_PHASE_MARKERS["container_scope"] + "\n")
        self.assertNotIn(secret.decode(), markers)
        self.assertNotIn("another-project", markers)

    def test_matching_labels_do_not_permit_named_unrelated_create_or_log_body(self):
        with tempfile.TemporaryDirectory(prefix="sl-adapter-test-", dir="/tmp") as directory:
            payload = self._unnamed_bootstrap_payload()
            body = json.dumps(payload).encode()
            request = (b"POST /v1.48/containers/create?name=another-project HTTP/1.1\r\n"
                       b"Host: docker\r\nContent-Length: " + str(len(body)).encode() +
                       b"\r\n\r\n" + body)
            markers = self._failed_proxy_request(str(Path(directory) / "unused.sock"), request, directory)
        self.assertEqual(markers, module.ADAPTER_PHASE_MARKERS["container_scope"] + "\n")
        self.assertNotIn("SYNTHETIC_SECRET", markers)
        self.assertNotIn("another-project", markers)

    def test_missing_upstream_socket_has_only_fixed_connect_marker(self):
        with tempfile.TemporaryDirectory(prefix="sl-adapter-test-", dir="/tmp") as directory:
            request = b"GET /v1.48/version HTTP/1.1\r\nHost: docker\r\n\r\n"
            markers = self._failed_proxy_request(str(Path(directory) / "missing.sock"), request, directory)
        self.assertEqual(markers, module.ADAPTER_PHASE_MARKERS["upstream_connect"] + "\n")
        self.assertNotIn("missing.sock", markers)

    def test_oversized_request_has_only_fixed_request_marker(self):
        with tempfile.TemporaryDirectory(prefix="sl-adapter-test-", dir="/tmp") as directory:
            request = b"POST /v1.48/containers/create?name=another-project HTTP/1.1\r\nHost: docker\r\nContent-Length: 8388609\r\n\r\n"
            markers = self._failed_proxy_request(str(Path(directory) / "unused.sock"), request, directory)
        self.assertEqual(markers, module.ADAPTER_PHASE_MARKERS["request"] + "\n")

    def test_upstream_closing_without_response_has_only_fixed_read_marker(self):
        with tempfile.TemporaryDirectory(prefix="sl-adapter-test-", dir="/tmp") as directory:
            endpoint = str(Path(directory) / "upstream.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(endpoint)
                listener.listen(1)

                def upstream():
                    with listener.accept()[0] as connection:
                        connection.settimeout(2)
                        request = bytearray()
                        while b"\r\n\r\n" not in request:
                            request.extend(connection.recv(4096))

                server = threading.Thread(target=upstream, daemon=True)
                server.start()
                request = b"GET /v1.48/version HTTP/1.1\r\nHost: docker\r\n\r\n"
                markers = self._failed_proxy_request(endpoint, request, directory)
                server.join(timeout=3)
        self.assertFalse(server.is_alive())
        self.assertEqual(markers, module.ADAPTER_PHASE_MARKERS["response_read"] + "\n")

    def test_regular_response_still_streams_without_upgrade(self):
        observed = {}
        with tempfile.TemporaryDirectory(prefix="sl-adapter-test-", dir="/tmp") as directory:
            endpoint = str(Path(directory) / "upstream.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(endpoint)
                listener.listen(1)

                def upstream():
                    try:
                        with listener.accept()[0] as connection:
                            connection.settimeout(2)
                            request = bytearray()
                            while b"\r\n\r\n" not in request:
                                request.extend(connection.recv(4096))
                            observed["head"] = bytes(request).split(b"\r\n\r\n", 1)[0].lower()
                            connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                    except BaseException as error:
                        observed["error"] = error

                server = threading.Thread(target=upstream, daemon=True)
                server.start()
                child = r'''
import os, socket, sys
endpoint = os.environ["DOCKER_HOST"].removeprefix("unix://")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(4)
    client.connect(endpoint)
    client.sendall(b"GET /v1.48/version HTTP/1.1\r\nHost: docker\r\n\r\n")
    response = bytearray()
    while chunk := client.recv(4096):
        response.extend(chunk)
    sys.exit(0 if response.endswith(b"\r\n\r\nok") and b"200 OK" in response else 3)
'''
                with patch.dict(os.environ, {"DOCKER_HOST": "unix://" + endpoint}), \
                     patch.object(tempfile, "tempdir", directory):
                    result = module.main([sys.executable, "-c", child])
                server.join(timeout=3)
        self.assertFalse(server.is_alive())
        self.assertNotIn("error", observed)
        self.assertEqual(result, 0)
        self.assertIn(b"connection: close", observed["head"])

    def test_exec_upgrade_forwards_stdin_and_half_close(self):
        """A fake Unix Docker endpoint exercises the child CLI through the proxy."""
        payload = b"synthetic exec stdin"
        output = b"synthetic exec stdout"
        frame = b"\x01\x00\x00\x00" + len(output).to_bytes(4, "big") + output
        observed = {}
        with tempfile.TemporaryDirectory(prefix="sl-adapter-test-", dir="/tmp") as directory:
            endpoint = str(Path(directory) / "upstream.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(endpoint)
                listener.listen(1)

                def upstream():
                    try:
                        with listener.accept()[0] as connection:
                            connection.settimeout(2)
                            request = bytearray()
                            while b"\r\n\r\n" not in request:
                                request.extend(connection.recv(4096))
                            observed["head"] = bytes(request).split(b"\r\n\r\n", 1)[0].lower()
                            connection.sendall(b"HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
                            received = bytearray()
                            try:
                                while chunk := connection.recv(4096):
                                    received.extend(chunk)
                            except socket.timeout:
                                pass  # Old proxy never forwards stdin; let child finish promptly.
                            observed["stdin"] = bytes(received)
                            connection.sendall(frame)
                            connection.shutdown(socket.SHUT_WR)
                    except BaseException as error:
                        observed["error"] = error

                server = threading.Thread(target=upstream, daemon=True)
                server.start()
                child = r'''
import os, socket, sys
endpoint = os.environ["DOCKER_HOST"].removeprefix("unix://")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(4)
    client.connect(endpoint)
    client.sendall(b"POST /v1.48/exec/example/start HTTP/1.1\r\nHost: docker\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n")
    response = bytearray()
    while b"\r\n\r\n" not in response:
        response.extend(client.recv(4096))
    head, remainder = bytes(response).split(b"\r\n\r\n", 1)
    if b"101" not in head.split(b"\r\n", 1)[0]:
        sys.exit(2)
    client.sendall(b"synthetic exec stdin")
    client.shutdown(socket.SHUT_WR)
    while chunk := client.recv(4096):
        remainder += chunk
    expected = b"\x01\x00\x00\x00" + len(b"synthetic exec stdout").to_bytes(4, "big") + b"synthetic exec stdout"
    sys.exit(0 if remainder == expected else 3)
'''
                with patch.dict(os.environ, {"DOCKER_HOST": "unix://" + endpoint}), \
                     patch.object(tempfile, "tempdir", directory):
                    result = module.main([sys.executable, "-c", child])
                server.join(timeout=3)
        self.assertFalse(server.is_alive())
        self.assertNotIn("error", observed)
        self.assertEqual(result, 0)
        self.assertIn(b"connection: upgrade", observed["head"])
        self.assertEqual(observed["stdin"], payload)

    def test_forces_each_published_port_to_loopback(self):
        payload = {"HostConfig": {"PortBindings": {"5432/tcp": [
            {"HostIp": "0.0.0.0", "HostPort": "56322"}, {"HostIp": "::", "HostPort": "56322"}]}},
            "Env": ["SYNTHETIC_SECRET=not-a-real-key"]}
        actual = json.loads(module.bind_create(
            "/v1.52/containers/create?name=supabase_db_secondlook-m2-local", json.dumps(payload).encode()))
        self.assertEqual([x["HostIp"] for x in actual["HostConfig"]["PortBindings"]["5432/tcp"]],
                         ["127.0.0.1", "127.0.0.1"])
        self.assertEqual(actual["Env"], payload["Env"])

    def test_scoped_unnamed_bootstrap_create_rewrites_loopback(self):
        payload = self._unnamed_bootstrap_payload()
        for path in ("/v1.48/containers/create", "/v1.48/containers/create?name="):
            with self.subTest(path=path):
                actual = json.loads(module.bind_create(path, json.dumps(payload).encode()))
                self.assertEqual(actual["HostConfig"]["PortBindings"]["5432/tcp"][0]["HostIp"],
                                 "127.0.0.1")
                self.assertEqual(actual["Env"], payload["Env"])

    def test_unnamed_create_requires_both_project_labels_and_expected_network(self):
        valid = self._unnamed_bootstrap_payload()
        for field in ("com.supabase.cli.project", "com.docker.compose.project"):
            for replacement in (None, "another-project"):
                with self.subTest(label=field, replacement=replacement):
                    payload = json.loads(json.dumps(valid))
                    if replacement is None:
                        del payload["Labels"][field]
                    else:
                        payload["Labels"][field] = replacement
                    with self.assertRaises(module.UnrelatedContainerError):
                        module.bind_create("/v1.48/containers/create", json.dumps(payload).encode())
        for network in (None, "another_network"):
            with self.subTest(network=network):
                payload = json.loads(json.dumps(valid))
                if network is None:
                    del payload["HostConfig"]["NetworkMode"]
                else:
                    payload["HostConfig"]["NetworkMode"] = network
                with self.assertRaises(module.UnrelatedContainerError):
                    module.bind_create("/v1.48/containers/create", json.dumps(payload).encode())

    def test_named_unrelated_create_is_refused_even_with_scoped_labels(self):
        payload = self._unnamed_bootstrap_payload()
        with self.assertRaises(module.UnrelatedContainerError):
            module.bind_create("/v1.48/containers/create?name=another-project", json.dumps(payload).encode())

    def test_refuses_unrelated_creation_and_preserves_other_requests(self):
        with self.assertRaises(ValueError):
            module.bind_create("/v1.52/containers/create?name=another-project", b"{}")
        self.assertEqual(module.bind_create("/v1.52/containers/example/archive", b"tar bytes"), b"tar bytes")

    def test_streamed_secret_copy_is_bounded_and_exact(self):
        self.assertEqual(module.read_chunked(io.BytesIO(b"3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")), b"abcde")
        with self.assertRaises(ValueError):
            module.read_chunked(io.BytesIO(b"3\r\nabc\r\n0\r\n\r\n"), limit=2)
        with self.assertRaises(ValueError):
            module.read_chunked(io.BytesIO(b"3\r\nab"))
