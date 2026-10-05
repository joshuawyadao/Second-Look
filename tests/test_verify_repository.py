"""End-to-end checks for the public repository verifier.

Adapted from BoardBot's MIT-licensed verifier tests (Joshua Yadao, 2026).
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "verify_repository.py"
sys.path.insert(0, str(SCRIPT.parent))
from verify_repository import REQUIRED_FILES  # noqa: E402


class RepositoryVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        for relative in REQUIRED_FILES:
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("placeholder\n", encoding="utf-8")
        (self.repo / ".gitignore").write_text(
            ".env\n/local-data/\n/photos/\n", encoding="utf-8"
        )
        self.git("add", ".")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, stdout=subprocess.PIPE)

    def check(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.repo)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_valid_fixture_with_external_and_local_links(self):
        (self.repo / "docs" / "My Guide.md").write_text("guide\n", encoding="utf-8")
        (self.repo / "README.md").write_text(
            "[guide](<docs/My Guide.md>) [encoded](docs/My%20Guide.md) "
            "[web](https://example.com) [mail](mailto:hello@example.com) "
            "[section](#intro) ![image](<docs/My Guide.md>)\n",
            encoding="utf-8",
        )
        self.assertEqual(self.check().returncode, 0)

    def test_missing_required_document_fails(self):
        (self.repo / "docs" / "Product-Brief.md").unlink()
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Missing or unsafe required file: docs/Product-Brief.md", result.stderr)

    def test_broken_relative_link_fails(self):
        (self.repo / "README.md").write_text("[missing](docs/nope.md)\n", encoding="utf-8")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Broken or unsafe Markdown link in README.md: docs/nope.md", result.stderr)

    def test_forcibly_tracked_ignored_credential_fails(self):
        (self.repo / ".env").write_text("TEST_ONLY=value\n", encoding="utf-8")
        self.git("add", "-f", ".env")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Private credential in Git inventory: .env", result.stderr)

    def test_forcibly_tracked_ignored_private_directories_fail(self):
        for directory in ("photos", "local-data"):
            with self.subTest(directory=directory):
                path = self.repo / directory / "sample.txt"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("TEST_ONLY\n", encoding="utf-8")
                self.git("add", "-f", str(path.relative_to(self.repo)))
                result = self.check()
                self.assertEqual(result.returncode, 1)
                self.assertIn(
                    f"Private local data in Git inventory: {directory}/sample.txt",
                    result.stderr,
                )

    def test_private_credential_file_patterns_fail(self):
        for filename in ("signing.p8", "profile.mobileprovision", "account.private.json"):
            with self.subTest(filename=filename):
                path = self.repo / filename
                path.write_text("TEST_ONLY\n", encoding="utf-8")
                self.git("add", "-f", filename)
                result = self.check()
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"Private credential in Git inventory: {filename}", result.stderr)

    def test_forcibly_tracked_xcode_and_swiftpm_artifacts_fail(self):
        artifacts = (
            "reports/Tests.xcresult/Data/contents",
            "reports/OtherTests.XCRESULT/Data/contents",
            "exports/App.xcarchive/Products/Applications/App.app/Info.plist",
            "symbols/App.dSYM/Contents/Resources/DWARF/App",
            "symbols/OtherApp.DSYM/Contents/Info.plist",
            "packages/.build/debug/output.o",
            "packages/.SWIFTPM/configuration/registries.json",
            "out/build/App.o",
            "out/DerivedData/Build/App.o",
            "other-out/dErIvEdDaTa/Build/App.o",
            "SecondLook.xcodeproj/xcuserdata/user.xcuserdatad/UserInterfaceState.xcuserstate",
        )
        ignore_patterns = (
            "*.xcresult/", "*.XCRESULT/", "*.xcarchive/", "*.dSYM/", "*.DSYM/",
            ".build/", ".SWIFTPM/", "build/", "DerivedData/", "dErIvEdDaTa/",
            "xcuserdata/",
        )
        with (self.repo / ".gitignore").open("a", encoding="utf-8") as ignore_file:
            ignore_file.write("\n".join(ignore_patterns) + "\n")
        self.git("add", ".gitignore")

        for relative in artifacts:
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("TEST_ONLY\n", encoding="utf-8")
            with self.subTest(relative=relative):
                subprocess.run(
                    ["git", "-C", str(self.repo), "check-ignore", "--no-index", "--quiet", relative],
                    check=True,
                )
                self.git("add", "-f", relative)

        result = self.check()
        self.assertEqual(result.returncode, 1)
        for relative in artifacts:
            with self.subTest(relative=relative):
                self.assertIn(f"Generated cache in Git inventory: {relative}", result.stderr)

    def test_source_paths_resembling_artifacts_are_allowed(self):
        source_paths = (
            "docs/DerivedData-guide.md",
            "docs/build-notes.md",
            "docs/Archive.xcarchive-example.md",
            "Sources/xcuserdata_helpers.swift",
            "Sources/Result.xcresult-examples/README.md",
        )
        for relative in source_paths:
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("TEST_ONLY\n", encoding="utf-8")
            self.git("add", relative)

        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_symlink_escaping_repository_fails(self):
        outside = Path(self.temporary.name) / "outside.md"
        outside.write_text("outside\n", encoding="utf-8")
        (self.repo / "docs" / "escape.md").symlink_to(outside)
        self.git("add", "docs/escape.md")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Missing or unsafe Git file: docs/escape.md", result.stderr)


if __name__ == "__main__":
    unittest.main()
