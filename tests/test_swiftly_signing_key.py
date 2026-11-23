"""Exercise the Swiftly key bootstrap without using a network or host keyring."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/import-swiftly-signing-key.sh"
OFFICIAL_KEY = "E813C892820A6FA13755B268F167DF1ACF9CE069"
OTHER_KEY = "52BB7E3DE28A71BE22EC05FFEF80A866B47A981F"


class SwiftlySigningKeyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.keyring = self.root / "keyring"
        self.keyring.mkdir(mode=0o700)
        self.imported = self.root / "imported"
        self.command("curl", """#!/bin/sh
[ "$FAIL_DOWNLOAD" = 0 ] || exit 22
for output do :; done
printf 'key file' > "$output"
""")
        self.command("gpg", """#!/bin/sh
case "$*" in
  *--show-keys*) printf '%s\n' "$KEY_LIST" ;;
  *--import*) touch "$IMPORT_MARKER" ;;
  *) exit 2 ;;
esac
""")

    def command(self, name, body):
        path = self.root / name
        path.write_text(body)
        path.chmod(0o700)

    def bootstrap(self, keys, *, download_failed=False):
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            env={
                "PATH": f"{self.root}:{os.environ['PATH']}",
                "GNUPGHOME": str(self.keyring),
                "KEY_LIST": keys,
                "IMPORT_MARKER": str(self.imported),
                "FAIL_DOWNLOAD": str(int(download_failed)),
            },
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(list(self.keyring.iterdir()), [])
        return result

    def test_accepts_the_expected_primary_key_with_subkeys(self):
        result = self.bootstrap(f"pub:\nfpr:::::::::{OFFICIAL_KEY}:\nsub:\nfpr:::::::::{OTHER_KEY}:")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.imported.is_file())

    def test_rejects_empty_wrong_or_additional_primary_keys_before_import(self):
        wrong_key = f"pub:\nfpr:::::::::{OTHER_KEY}:"
        for keys in ("", wrong_key, f"pub:\nfpr:::::::::{OFFICIAL_KEY}:\n{wrong_key}"):
            with self.subTest(keys=keys):
                result = self.bootstrap(keys)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("fingerprint mismatch", result.stderr)
                self.assertFalse(self.imported.exists())

    def test_download_failure_prevents_import(self):
        result = self.bootstrap(f"pub:\nfpr:::::::::{OFFICIAL_KEY}:", download_failed=True)
        self.assertEqual(result.returncode, 22)
        self.assertFalse(self.imported.exists())
