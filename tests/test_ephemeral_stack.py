"""Private stack preparation and exact ownership boundaries; no Docker is contacted."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("ephemeral_stack_test", SCRIPTS / "ephemeral_stack.py")
stack = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = stack
spec.loader.exec_module(stack)
adapter_spec = importlib.util.spec_from_file_location("ephemeral_adapter_test", SCRIPTS / "local-docker-binding.py")
adapter = importlib.util.module_from_spec(adapter_spec)
adapter_spec.loader.exec_module(adapter)


class EphemeralStackTests(unittest.TestCase):
    def test_private_copy_changes_only_five_config_fields_and_exact_migrations(self):
        with tempfile.TemporaryDirectory() as directory:
            private = Path(directory)
            with patch.object(stack, "selected_ports", return_value=(43001, 43002, 43003, 43004)):
                scope = stack.prepare(ROOT, private)
            self.assertTrue(stack.metadata_matches(scope))
            self.assertEqual(stat.S_IMODE(scope.workdir.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((scope.workdir / "scope.private.json").stat().st_mode), 0o600)
            source = tomllib.loads((ROOT / "supabase/config.toml").read_text())
            copied = tomllib.loads((scope.workdir / "supabase/config.toml").read_text())
            source["project_id"] = scope.project
            source["api"]["port"] = scope.api_port
            source["db"]["port"] = scope.db_port
            source["db"]["shadow_port"] = scope.shadow_port
            source["auth"]["site_url"] = f"http://127.0.0.1:{scope.server_port}"
            self.assertEqual(copied, source)
            self.assertEqual(len({scope.api_port, scope.db_port, scope.shadow_port, scope.server_port}), 4)
            originals = sorted((ROOT / "supabase/migrations").glob("*.sql"))
            copied_files = sorted((scope.workdir / "supabase/migrations").glob("*.sql"))
            self.assertEqual([p.name for p in copied_files], [p.name for p in originals])
            for original, copy in zip(originals, copied_files):
                self.assertEqual(copy.read_bytes(), original.read_bytes())
            self.assertEqual(set(p.name for p in (scope.workdir / "supabase").iterdir()),
                             {"config.toml", "migrations"})

    def test_invalid_scope_metadata_and_ports_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(stack, "selected_ports", return_value=(43001, 43002, 43003, 43004)):
                scope = stack.prepare(ROOT, Path(directory))
            (scope.workdir / "scope.private.json").write_text("{}")
            self.assertFalse(stack.metadata_matches(scope))
            invalid = stack.Scope(scope.token, "secondlook-m2-local", scope.network, scope.workdir,
                                  scope.api_port, scope.db_port, scope.shadow_port, scope.api_port)
            with self.assertRaises(ValueError):
                invalid.validate()

    def test_private_workdir_does_not_change_repo_source_fingerprint(self):
        checker_spec = importlib.util.spec_from_file_location("ephemeral_checker_test",
                                                      SCRIPTS / "check-connected-native-evidence.py")
        checker = importlib.util.module_from_spec(checker_spec)
        checker_spec.loader.exec_module(checker)
        before = checker.source_fingerprint()
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(stack, "selected_ports", return_value=(43001, 43002, 43003, 43004)):
            stack.prepare(ROOT, Path(directory))
            self.assertEqual(checker.source_fingerprint(), before)

    def test_ephemeral_adapter_rejects_other_names_labels_network_and_ports(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        with patch.object(stack, "selected_ports", return_value=(43001, 43002, 43003, 43004)):
            scope = stack.prepare(ROOT, Path(directory.name))
        token, project, network = scope.token, scope.project, scope.network
        environment = {"SECONDLOOK_EPHEMERAL_TOKEN": token,
                       "SECONDLOOK_EPHEMERAL_PROJECT": project,
                       "SECONDLOOK_EPHEMERAL_NETWORK": network,
                       "SECONDLOOK_EPHEMERAL_WORKDIR": str(scope.workdir),
                       "SECONDLOOK_EPHEMERAL_PORTS": "43001,43002,43003"}
        selected = adapter.ephemeral_scope(environment)
        payload = {"Labels": {label: project for label in adapter.PROJECT_LABELS},
                   "HostConfig": {"NetworkMode": network,
                                  "PortBindings": {"5432/tcp": [{"HostIp": "0.0.0.0", "HostPort": "43002"}]}}}
        def created(name, value):
            return adapter.bind_create("/v1.52/containers/create?name=" + name,
                                       json.dumps(value).encode(), selected)
        def refused(reason, call):
            with self.assertRaises(adapter.UnrelatedContainerError) as caught:
                call()
            self.assertEqual(caught.exception.reason, reason)
        rewritten = json.loads(created("supabase_db_" + project, payload))
        self.assertEqual(rewritten["HostConfig"]["PortBindings"]["5432/tcp"][0]["HostIp"], "127.0.0.1")
        self.assertTrue(created("", payload))  # exact-label unnamed migration bootstrap
        private_config = str(scope.workdir / "supabase/config.toml")
        self.assertTrue(created("supabase_db_" + project, {**payload, "HostConfig": {
            "NetworkMode": network, "Binds": [private_config + ":/etc/config:ro"]}}))
        rest = {"Labels": payload["Labels"], "HostConfig": {"NetworkMode": network}}
        self.assertTrue(created("supabase_rest_" + project, rest))
        self.assertTrue(adapter.bind_volume_create("/v1.52/volumes/create", json.dumps({
            "Name": "supabase_db_" + project, "Labels": payload["Labels"], "Driver": "local"}).encode(), selected))
        refused("volume_name", lambda: adapter.bind_volume_create(
            "/v1.52/volumes/create", json.dumps({
                "Name": "supabase_db_secondlook-m2-local", "Labels": payload["Labels"]}).encode(), selected))
        refused("volume_labels", lambda: adapter.bind_volume_create(
            "/v1.52/volumes/create", json.dumps({
                "Name": "supabase_db_" + project, "Labels": {}}).encode(), selected))
        refused("volume_driver", lambda: adapter.bind_volume_create(
            "/v1.52/volumes/create", json.dumps({
                "Name": "supabase_db_" + project, "Labels": payload["Labels"],
                "Driver": "foreign"}).encode(), selected))
        for reason, name, value in (("create_name", "supabase_db_secondlook-m2-local", payload),
                                    ("create_name", "supabase_studio_" + project, payload),
                                    ("create_port", "supabase_rest_" + project, payload),
                                    ("create_name", "supabase_rest_secondlook-m2-local", rest),
                                    ("create_labels", "supabase_rest_" + project, {**rest, "Labels": {}}),
                                    ("create_network", "supabase_rest_" + project, {**rest, "HostConfig": {"NetworkMode": "bridge"}}),
                                    ("create_mount", "supabase_rest_" + project, {**rest, "HostConfig": {
                                        "NetworkMode": network, "Binds": ["supabase_db_secondlook-m2-local:/var/lib/postgresql/data"]}}),
                                    ("create_payload", "supabase_db_" + project, []),
                                    ("create_labels", "supabase_db_" + project, {**payload, "Labels": {}}),
                                    ("create_network", "supabase_db_" + project, {**payload, "HostConfig": {"NetworkMode": "bridge"}}),
                                    ("create_mount", "supabase_db_" + project, {**payload, "HostConfig": {"NetworkMode": network,
                                        "Binds": ["supabase_db_secondlook-m2-local:/var/lib/postgresql/data"]}}),
                                    ("create_mount", "supabase_db_" + project, {**payload, "HostConfig": {"NetworkMode": network,
                                        "Binds": [private_config + ":/etc/config:rw"]}}),
                                    ("create_mount", "supabase_db_" + project, {**payload, "HostConfig": {"NetworkMode": network,
                                        "Mounts": [{"Type": "volume", "Source": "supabase_db_secondlook-m2-local",
                                                    "Target": "/var/lib/postgresql/data"}]}}),
                                    ("create_port", "supabase_db_" + project, {**payload, "HostConfig": {"NetworkMode": network,
                                        "PortBindings": {"5432/tcp": [{"HostIp": "0.0.0.0", "HostPort": "43001"}]}}}),
                                    ("create_port", "supabase_db_" + project, {**payload, "HostConfig": {"NetworkMode": network,
                                        "PortBindings": {"5432/tcp": [{"HostIp": "0.0.0.0", "HostPort": "56322"}]}}})):
            with self.subTest(reason=reason, name=name, value=value):
                refused(reason, lambda: created(name, value))
        for changed in ({**environment, "SECONDLOOK_EPHEMERAL_TOKEN": "bad"},
                        {**environment, "SECONDLOOK_EPHEMERAL_NETWORK": "secondlook_m2_local"},
                        {**environment, "SECONDLOOK_EPHEMERAL_PORTS": "43001,43001,43003"}):
            with self.assertRaises(ValueError):
                adapter.ephemeral_scope(changed)
        self.assertTrue(stack.inspected_mounts_are_approved(scope, [{
            "Type": "volume", "Name": "supabase_db_" + project, "RW": True}]))
        self.assertFalse(stack.inspected_mounts_are_approved(scope, [{
            "Type": "volume", "Name": "supabase_db_secondlook-m2-local", "RW": True}]))
        self.assertTrue(stack.inspected_mounts_are_approved(scope, [{
            "Type": "bind", "Source": str(scope.workdir / "supabase/config.toml"), "RW": False}]))
        self.assertFalse(stack.inspected_mounts_are_approved(scope, [{
            "Type": "bind", "Source": str(scope.workdir / "supabase/config.toml"), "RW": True}]))


if __name__ == "__main__":
    unittest.main()
