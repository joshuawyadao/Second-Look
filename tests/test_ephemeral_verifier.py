"""Ephemeral stack cleanup ownership and legacy-mode isolation without Docker."""
import importlib.util
import json
from pathlib import Path
import subprocess
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("ephemeral_verifier_test", SCRIPTS / "verify-shared-state.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
from ephemeral_stack import prepare


class EphemeralVerifierTests(unittest.TestCase):
    def setUp(self):
        self.original = (verifier.PROJECT, verifier.NETWORK, verifier.API_PORT,
                         verifier.SERVER_PORT, verifier.WORKDIR, verifier.OWNED_NETWORK_ID,
                         verifier.NETWORK_CREATE_ATTEMPTED)

    def tearDown(self):
        (verifier.PROJECT, verifier.NETWORK, verifier.API_PORT,
         verifier.SERVER_PORT, verifier.WORKDIR, verifier.OWNED_NETWORK_ID,
         verifier.NETWORK_CREATE_ATTEMPTED) = self.original

    def scope(self, directory):
        with patch("ephemeral_stack.selected_ports", return_value=(43001, 43002, 43003, 43004)):
            return prepare(SCRIPTS.parent, Path(directory))

    def test_both_stack_modes_keep_postgrest_for_swift_rpc(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(verifier, "run") as run:
                verifier.start_stack(Path(directory), {})
                command = run.call_args.args[0]
                excluded = command[command.index("--exclude") + 1].split(",")
                self.assertEqual(excluded, verifier.EXCLUDED.split(","))
                for required in ("gotrue", "kong", "postgrest"):
                    self.assertNotIn(required, excluded)
                self.assertNotIn("--ignore-health-check", command)

    def test_invalid_flag_refuses_scope_before_any_mutation(self):
        with patch.object(sys, "argv", ["verify-shared-state.py", "--ephemeral"]), \
                patch.object(verifier, "prepare") as prepare_scope:
            with self.assertRaises(SystemExit):
                verifier.main()
            prepare_scope.assert_not_called()

    def test_ephemeral_temp_root_inside_repo_is_refused_before_scope_creation(self):
        with patch.object(sys, "argv", ["verify-shared-state.py", "--native-smoke", "--ephemeral"]), \
                patch.object(verifier.tempfile, "gettempdir", return_value=str(SCRIPTS.parent)), \
                patch.object(verifier, "prepare") as prepare_scope:
            with self.assertRaisesRegex(RuntimeError, "outside the repository"):
                verifier.main()
            prepare_scope.assert_not_called()

    def test_ephemeral_main_cleans_up_after_early_return_and_error(self):
        with tempfile.TemporaryDirectory() as directory:
            scope = self.scope(directory)
            original = (verifier.PROJECT, verifier.NETWORK, verifier.API_PORT,
                        verifier.SERVER_PORT, verifier.WORKDIR, verifier.OWNED_NETWORK_ID,
                        verifier.NETWORK_CREATE_ATTEMPTED)
            try:
                for outcome in (None, RuntimeError("synthetic failure")):
                    with self.subTest(outcome=outcome), \
                            patch.object(sys, "argv", ["verify-shared-state.py", "--native-smoke", "--ephemeral"]), \
                            patch.object(verifier, "prepare", return_value=scope), \
                            patch.object(verifier, "run_verification", side_effect=outcome) as workflow, \
                            patch.object(verifier, "cleanup_ephemeral") as cleanup:
                        if outcome:
                            with self.assertRaises(RuntimeError):
                                verifier.main()
                        else:
                            verifier.main()
                        workflow.assert_called_once()
                        cleanup.assert_called_once_with(scope)
            finally:
                (verifier.PROJECT, verifier.NETWORK, verifier.API_PORT,
                 verifier.SERVER_PORT, verifier.WORKDIR, verifier.OWNED_NETWORK_ID,
                 verifier.NETWORK_CREATE_ATTEMPTED) = original

    def test_cleanup_stops_only_exact_owned_uuid_project_and_network(self):
        with tempfile.TemporaryDirectory() as directory:
            scope = self.scope(directory)
            network_id = "a" * 64
            container_ids = {service: letter * 64 for service, letter in
                             zip(verifier.REQUIRED_SERVICES, "bcde")}
            attached = {"Id": network_id, "Name": scope.network,
                        "Labels": {"com.secondlook.smoke": scope.token},
                        "Containers": {identity: {} for identity in container_ids.values()}}
            empty = {**attached, "Containers": {}}
            containers = {identity: {
                "Name": f"/supabase_{service}_{scope.project}",
                "Mounts": ([{"Type": "volume", "Name": "supabase_db_" + scope.project,
                             "RW": True}] if service == "db" else []),
                "Config": {"Labels": {"com.supabase.cli.project": scope.project,
                                      "com.docker.compose.project": scope.project}},
                "NetworkSettings": {"Networks": {scope.network: {}}},
            } for service, identity in container_ids.items()}
            calls = []
            def fake_run(command, **_kwargs):
                calls.append(command)
                if command[:3] == ["docker", "network", "inspect"]:
                    value = attached if len([c for c in calls if c[:3] == ["docker", "network", "inspect"]]) == 1 else empty
                    return subprocess.CompletedProcess(command, 0, json.dumps([value]).encode())
                if command[:2] == ["docker", "inspect"]:
                    return subprocess.CompletedProcess(command, 0, json.dumps([containers[command[2]]]).encode())
                return subprocess.CompletedProcess(command, 0, b"")
            with patch.object(verifier, "OWNED_NETWORK_ID", network_id), \
                    patch.object(verifier, "NETWORK_CREATE_ATTEMPTED", True), \
                    patch.object(verifier, "WORKDIR", scope.workdir), \
                    patch.object(verifier, "INSPECTABLE_IDS", set()), \
                    patch.object(verifier, "run", side_effect=fake_run):
                verifier.cleanup_ephemeral(scope)
            stop = [command for command in calls if command[:4] == [*verifier.CLI, "stop"]]
            self.assertEqual(len(stop), 1)
            self.assertEqual({command[2] for command in calls if command[:2] == ["docker", "inspect"]},
                             set(container_ids.values()))
            self.assertIn(["--project-id", scope.project, "--no-backup"],
                          [stop[0][index:index + 3] for index in range(len(stop[0]) - 2)])
            self.assertIn("--workdir", stop[0])
            self.assertNotIn("--all", stop[0])
            self.assertNotIn("secondlook-m2-local", " ".join(stop[0]))
            self.assertIn(["docker", "network", "rm", network_id], calls)
            self.assertEqual(calls[-1], ["docker", "network", "ls", "--filter",
                                         f"name={scope.network}", "--format", "{{.ID}}"])

    def test_wrong_network_label_prevents_stop_or_delete(self):
        with tempfile.TemporaryDirectory() as directory:
            scope = self.scope(directory)
            calls = []
            def fake_run(command, **_kwargs):
                calls.append(command)
                return subprocess.CompletedProcess(command, 0, json.dumps([{
                    "Id": "a" * 64, "Name": scope.network, "Labels": {}, "Containers": {}}]).encode())
            with patch.object(verifier, "OWNED_NETWORK_ID", "a" * 64), \
                    patch.object(verifier, "NETWORK_CREATE_ATTEMPTED", True), \
                    patch.object(verifier, "run", side_effect=fake_run):
                with self.assertRaises(RuntimeError):
                    verifier.cleanup_ephemeral(scope)
            self.assertEqual(len(calls), 1)

    def test_wrong_stopped_container_or_volume_aborts_before_destructive_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            scope = self.scope(directory)
            network_id = "a" * 64
            for wrong in ("container", "volume"):
                with self.subTest(wrong=wrong):
                    calls = []
                    details = {"Id": network_id, "Name": scope.network,
                               "Labels": {"com.secondlook.smoke": scope.token}, "Containers": {}}
                    def fake_run(command, **_kwargs):
                        calls.append(command)
                        if command[:3] == ["docker", "network", "inspect"]:
                            return subprocess.CompletedProcess(command, 0, json.dumps([details]).encode())
                        if command[:3] == ["docker", "ps", "-a"]:
                            return subprocess.CompletedProcess(command, 0,
                                b"b" * 64 + b"\n" if wrong == "container" else b"")
                        if command[:3] == ["docker", "volume", "ls"]:
                            return subprocess.CompletedProcess(command, 0,
                                ("supabase_db_" + scope.project).encode() + b"\n" if wrong == "volume" else b"")
                        if command[:3] == ["docker", "volume", "inspect"]:
                            return subprocess.CompletedProcess(command, 0, json.dumps([{
                                "Name": "supabase_db_" + scope.project, "Driver": "local",
                                "Labels": {"com.supabase.cli.project": "secondlook-m2-local"}}]).encode())
                        if command[:2] == ["docker", "inspect"]:
                            return subprocess.CompletedProcess(command, 0, json.dumps([{
                                "Name": "/supabase_db_" + scope.project,
                                "Config": {"Labels": {"com.supabase.cli.project": scope.project,
                                                      "com.docker.compose.project": scope.project}},
                                "NetworkSettings": {"Networks": {}},
                                "Mounts": [{"Type": "volume", "Name": "supabase_db_secondlook-m2-local", "RW": True}],
                            }]).encode())
                        return subprocess.CompletedProcess(command, 0, b"")
                    with patch.object(verifier, "OWNED_NETWORK_ID", network_id), \
                            patch.object(verifier, "NETWORK_CREATE_ATTEMPTED", True), \
                            patch.object(verifier, "run", side_effect=fake_run):
                        with self.assertRaises(RuntimeError):
                            verifier.cleanup_ephemeral(scope)
                    self.assertFalse(any(command[:4] == [*verifier.CLI, "stop"] for command in calls))
                    self.assertFalse(any(command[:3] == ["docker", "network", "rm"] for command in calls))

    def test_wrong_actual_database_mount_is_refused_before_any_sql(self):
        with tempfile.TemporaryDirectory() as directory:
            scope = self.scope(directory)
            network_id = "a" * 64
            calls = []
            network = {"Id": network_id, "Name": scope.network,
                       "Labels": {"com.secondlook.smoke": scope.token},
                       "Options": {"com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"}}
            def fake_run(command, **_kwargs):
                calls.append(command)
                if command[:3] == ["docker", "network", "inspect"]:
                    count = sum(c[:3] == ["docker", "network", "inspect"] for c in calls)
                    return subprocess.CompletedProcess(command, 1 if count == 1 else 0,
                                                       b"" if count == 1 else json.dumps([network]).encode())
                if command[:3] == ["docker", "network", "create"]:
                    return subprocess.CompletedProcess(command, 0, network_id.encode())
                if command[:2] == ["docker", "inspect"]:
                    containers = []
                    for name in verifier.REQUIRED_SERVICES:
                        containers.append({
                            "Name": f"/supabase_{name}_{scope.project}",
                            "Config": {"Labels": {"com.supabase.cli.project": scope.project,
                                                  "com.docker.compose.project": scope.project}},
                            "NetworkSettings": {"Networks": {scope.network: {}}, "Ports": {}},
                            "Mounts": [{"Type": "volume", "Name": "supabase_db_secondlook-m2-local", "RW": True}]
                            if name == "db" else [],
                        })
                    return subprocess.CompletedProcess(command, 0, json.dumps(containers).encode())
                raise AssertionError("Unexpected command after mount refusal")
            with patch.object(verifier, "PROJECT", scope.project), \
                    patch.object(verifier, "NETWORK", scope.network), \
                    patch.object(verifier, "WORKDIR", scope.workdir), \
                    patch.object(verifier, "OWNED_NETWORK_ID", None), \
                    patch.object(verifier, "NETWORK_CREATE_ATTEMPTED", False), \
                    patch.object(verifier, "preflight_ephemeral"), \
                    patch.object(verifier, "start_stack"), \
                    patch.object(verifier, "run", side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, "container ownership"):
                    verifier.run_verification(SimpleNamespace(), Path(directory), {}, True, lambda _: [], scope)
            self.assertFalse(any(command[:2] == ["docker", "exec"] for command in calls))
            self.assertFalse(any(command[:4] == [*verifier.CLI, "status"] for command in calls))

    def test_rest_ownership_and_unpublished_port_are_checked_before_sql(self):
        with tempfile.TemporaryDirectory() as directory:
            scope = self.scope(directory)
            network_id = "a" * 64
            network = {"Id": network_id, "Name": scope.network,
                       "Labels": {"com.secondlook.smoke": scope.token},
                       "Options": {"com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"}}
            for fault in ("label", "network", "additional-network", "mount", "port"):
                with self.subTest(fault=fault):
                    calls = []
                    def fake_run(command, **_kwargs):
                        calls.append(command)
                        if command[:3] == ["docker", "network", "inspect"]:
                            first = sum(c[:3] == ["docker", "network", "inspect"] for c in calls) == 1
                            return subprocess.CompletedProcess(command, 1 if first else 0,
                                                               b"" if first else json.dumps([network]).encode())
                        if command[:3] == ["docker", "network", "create"]:
                            return subprocess.CompletedProcess(command, 0, network_id.encode())
                        if command[:2] == ["docker", "inspect"]:
                            containers = []
                            for service in verifier.REQUIRED_SERVICES:
                                labels = {"com.supabase.cli.project": scope.project,
                                          "com.docker.compose.project": scope.project}
                                networks = {scope.network: {}}
                                mounts = ([{"Type": "volume", "Name": "supabase_db_" + scope.project,
                                            "RW": True}] if service == "db" else [])
                                ports = {}
                                if service == "rest":
                                    if fault == "label": labels["com.supabase.cli.project"] = "secondlook-m2-local"
                                    if fault == "network": networks = {"bridge": {}}
                                    if fault == "additional-network": networks["bridge"] = {}
                                    if fault == "mount": mounts = [{"Type": "volume", "Name": "supabase_db_secondlook-m2-local", "RW": True}]
                                    if fault == "port": ports = {"3000/tcp": [{"HostIp": "127.0.0.1", "HostPort": "43001"}]}
                                containers.append({
                                    "Name": f"/supabase_{service}_{scope.project}",
                                    "Config": {"Labels": labels},
                                    "NetworkSettings": {"Networks": networks, "Ports": ports},
                                    "Mounts": mounts,
                                })
                            return subprocess.CompletedProcess(command, 0, json.dumps(containers).encode())
                        raise AssertionError("Unexpected command after REST ownership refusal")
                    with patch.object(verifier, "PROJECT", scope.project), \
                            patch.object(verifier, "NETWORK", scope.network), \
                            patch.object(verifier, "WORKDIR", scope.workdir), \
                            patch.object(verifier, "OWNED_NETWORK_ID", None), \
                            patch.object(verifier, "NETWORK_CREATE_ATTEMPTED", False), \
                            patch.object(verifier, "preflight_ephemeral"), \
                            patch.object(verifier, "start_stack"), \
                            patch.object(verifier, "run", side_effect=fake_run):
                        with self.assertRaisesRegex(RuntimeError, "ownership|binding"):
                            verifier.run_verification(SimpleNamespace(), Path(directory), {}, True,
                                                      lambda _: [], scope)
                    inspected = [c for c in calls if c[:2] == ["docker", "inspect"]]
                    self.assertEqual(len(inspected), 1)
                    self.assertIn(f"supabase_rest_{scope.project}", inspected[0])
                    self.assertFalse(any(c[:2] == ["docker", "exec"] for c in calls))
                    self.assertFalse(any(c[:4] == [*verifier.CLI, "status"] for c in calls))

    def test_cleanup_failure_prevents_success_even_after_smoke_returns(self):
        with tempfile.TemporaryDirectory() as directory:
            scope = self.scope(directory)
            with patch.object(sys, "argv", ["verify-shared-state.py", "--native-smoke", "--ephemeral"]), \
                    patch.object(verifier, "prepare", return_value=scope), \
                    patch.object(verifier, "run_verification", return_value=None), \
                    patch.object(verifier, "cleanup_ephemeral", side_effect=RuntimeError("cleanup unproved")):
                with self.assertRaisesRegex(RuntimeError, "cleanup unproved"):
                    verifier.main()

    def test_legacy_default_keeps_named_network_and_cli_commands(self):
        calls = []
        def fake_run(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 1 if command[:3] == ["docker", "network", "inspect"] else 0, b"")
        with patch.object(verifier, "run", side_effect=fake_run), \
                patch.object(verifier, "start_stack", side_effect=RuntimeError("synthetic stop")):
            with self.assertRaisesRegex(RuntimeError, "synthetic stop"):
                verifier.run_verification(SimpleNamespace(), Path("/tmp/synthetic"), {}, False, lambda _: [], None)
        self.assertEqual(calls[0], ["docker", "network", "inspect", "secondlook_m2_local"])
        self.assertEqual(calls[1], ["docker", "network", "create", "--opt",
                                    "com.docker.network.bridge.host_binding_ipv4=127.0.0.1",
                                    "secondlook_m2_local"])
        self.assertEqual(verifier.cli_command("status", "-o", "json"), [*verifier.CLI, "status", "-o", "json"])

    def test_preflight_refuses_existing_namespace_before_network_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            scope = self.scope(directory)
            calls = []
            def fake_run(command, **_kwargs):
                calls.append(command)
                return subprocess.CompletedProcess(command, 0, b"preexisting")
            with patch.object(verifier, "run", side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, "already exists"):
                    verifier.preflight_ephemeral(scope)
            self.assertEqual(len(calls), 3)
            self.assertFalse(any(command[:3] == ["docker", "network", "create"] for command in calls))

    def test_failed_network_create_can_remove_only_labeled_empty_network(self):
        with tempfile.TemporaryDirectory() as directory:
            scope = self.scope(directory)
            network_id = "c" * 64
            owned = {"Id": network_id, "Name": scope.network,
                     "Labels": {"com.secondlook.smoke": scope.token}, "Containers": {}}
            calls = []
            def fake_run(command, **_kwargs):
                calls.append(command)
                if command[:3] == ["docker", "network", "inspect"]:
                    return subprocess.CompletedProcess(command, 0, json.dumps([owned]).encode())
                return subprocess.CompletedProcess(command, 0, b"")
            with patch.object(verifier, "OWNED_NETWORK_ID", None), \
                    patch.object(verifier, "NETWORK_CREATE_ATTEMPTED", True), \
                    patch.object(verifier, "run", side_effect=fake_run):
                verifier.cleanup_ephemeral(scope)
            self.assertEqual(calls, [["docker", "network", "inspect", scope.network],
                                     ["docker", "network", "rm", network_id],
                                     ["docker", "network", "ls", "--filter", f"name={scope.network}",
                                      "--format", "{{.ID}}"]])

    def test_ephemeral_fixture_pointer_preserves_legacy_sentinel(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scope = self.scope(directory)
            legacy = root / "secondlook-m2-paths.private.json"
            legacy.write_text("legacy sentinel")
            with patch.object(verifier.tempfile, "gettempdir", return_value=directory):
                private = verifier.write_fixture_pointer(root, root / "fixture.private.json",
                                                         root / "ui.private.json", str(root / "build"), scope)
            self.assertEqual(legacy.read_text(), "legacy sentinel")
            self.assertEqual(private, root / "paths.private.json")
            self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o600)
            self.assertTrue(json.loads(private.read_text())["fixture"].endswith("fixture.private.json"))


if __name__ == "__main__":
    unittest.main()
