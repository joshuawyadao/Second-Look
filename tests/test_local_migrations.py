"""Local migration replay stays scoped to the named synthetic database."""

import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("verify_shared_state_migrations",
                                              SCRIPTS / "verify-shared-state.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
DATABASE_COMMAND = ["docker", "exec", "-i", "supabase_db_secondlook-m2-local", "psql",
                    "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1"]


class LocalMigrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.migrations = self.root / "supabase" / "migrations"
        self.migrations.mkdir(parents=True)
        self.root_patch = patch.object(verifier, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)

    def write_migration(self, name: str, sql: str) -> None:
        (self.migrations / name).write_text(sql)

    def test_applies_only_missing_followup_and_repeated_run_skips_it(self):
        self.write_migration("202610050001_private_space.sql", "select 'initial synthetic migration';")
        followup_sql = "select 'synthetic follow-up migration';"
        self.write_migration("202610120001_conditional_invitation.sql", followup_sql)
        recorded = {"202610050001"}
        queries = []
        applied = []

        def fake_run(command, **kwargs):
            self.assertEqual(command[:len(DATABASE_COMMAND)], DATABASE_COMMAND)
            if kwargs.get("capture_output"):
                self.assertEqual(command[len(DATABASE_COMMAND):len(DATABASE_COMMAND) + 2],
                                 ["-At", "-c"])
                query = command[-1]
                match = re.fullmatch(
                    r"select count\(\*\) from supabase_migrations\.schema_migrations "
                    r"where version = '(\d{12,14})';", query)
                self.assertIsNotNone(match)
                version = match.group(1)
                queries.append(version)
                return subprocess.CompletedProcess(command, 0,
                                                   stdout=(b"1\n" if version in recorded else b"0\n"))
            self.assertEqual(command, DATABASE_COMMAND)
            sql = kwargs["input"].decode()
            self.assertTrue(sql.startswith("begin;\n" + followup_sql + "\n"))
            self.assertTrue(sql.endswith("\ncommit;\n"))
            self.assertIn("insert into supabase_migrations.schema_migrations "
                          "(version, name) values ('202610120001', 'conditional_invitation');", sql)
            self.assertLess(sql.index(followup_sql), sql.index("insert into supabase_migrations"))
            self.assertLess(sql.index("insert into supabase_migrations"), sql.index("\ncommit;"))
            applied.append(sql)
            recorded.add("202610120001")
            return subprocess.CompletedProcess(command, 0)

        with patch.object(verifier, "run", side_effect=fake_run):
            verifier.apply_pending_local_migrations()
            verifier.apply_pending_local_migrations()

        self.assertEqual(queries, ["202610050001", "202610120001"] * 2)
        self.assertEqual(len(applied), 1)

    def test_rejects_unsupported_filename_before_database_command(self):
        self.write_migration("20261012_unexpected-name.sql", "select 1;")
        with patch.object(verifier, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "Unsupported local migration filename"):
                verifier.apply_pending_local_migrations()
        run.assert_not_called()

    def test_rejects_unexpected_recorded_status_without_running_migration(self):
        self.write_migration("202610120001_conditional_invitation.sql", "select 1;")
        for status in (b"2\n", b"unexpected\n", b"\n"):
            with self.subTest(status=status), patch.object(
                    verifier, "run", return_value=subprocess.CompletedProcess(
                        DATABASE_COMMAND, 0, stdout=status)) as run:
                with self.assertRaisesRegex(RuntimeError, "Unexpected local migration status"):
                    verifier.apply_pending_local_migrations()
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][:len(DATABASE_COMMAND)], DATABASE_COMMAND)
                self.assertTrue(run.call_args.kwargs["capture_output"])
