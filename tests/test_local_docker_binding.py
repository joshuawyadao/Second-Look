"""The local fixture launcher must never publish wildcard ports or mutate another project."""
import importlib.util
import io
import json
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "local-docker-binding.py"
spec = importlib.util.spec_from_file_location("local_docker_binding", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LocalDockerBindingTests(unittest.TestCase):
    def test_forces_each_published_port_to_loopback(self):
        payload = {"HostConfig": {"PortBindings": {"5432/tcp": [
            {"HostIp": "0.0.0.0", "HostPort": "56322"}, {"HostIp": "::", "HostPort": "56322"}]}},
            "Env": ["SYNTHETIC_SECRET=not-a-real-key"]}
        actual = json.loads(module.bind_create(
            "/v1.52/containers/create?name=supabase_db_secondlook-m2-local", json.dumps(payload).encode()))
        self.assertEqual([x["HostIp"] for x in actual["HostConfig"]["PortBindings"]["5432/tcp"]],
                         ["127.0.0.1", "127.0.0.1"])
        self.assertEqual(actual["Env"], payload["Env"])

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
