"""Guard the CI event matrix and the narrow public dependency cache."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
DOCKERFILE = (ROOT / "Backend/Dockerfile").read_text(encoding="utf-8")


def top_level_block(text: str, name: str) -> str:
    match = re.search(rf"(?m)^{re.escape(name)}:\s*\n(.*?)(?=^\S|\Z)", text, re.S | re.M)
    if match is None:
        raise AssertionError(f"Missing top-level {name} block")
    return match.group(1)


class CIEfficiencyContracts(unittest.TestCase):
    def test_one_automatic_full_run_per_pull_request_update(self):
        triggers = top_level_block(WORKFLOW, "on")
        push_branches = re.search(r"(?m)^  push:\s*\n    branches: \[([^]]+)\]", triggers)
        self.assertIsNotNone(push_branches)
        self.assertEqual(push_branches.group(1).strip(), "main")
        self.assertRegex(triggers, r"(?m)^  pull_request:\s*$")
        self.assertRegex(triggers, r"(?m)^  workflow_dispatch:\s*$")
        self.assertNotRegex(triggers, r"(?m)^    paths(?:-ignore)?:")

        # An unmerged branch can be checked manually; opening/updating its PR
        # schedules exactly one automatic run, while main remains covered.
        branches = set(push_branches.group(1).replace("'", "").split(", "))

        def scheduled(branch: str, pr: bool = False, manual: bool = False) -> int:
            return int(branch in branches) + int(pr) + int(manual)

        self.assertEqual(scheduled("codex/resource-efficiency"), 0)
        self.assertEqual(scheduled("codex/resource-efficiency", manual=True), 1)
        self.assertEqual(scheduled("codex/resource-efficiency", pr=True), 1)
        self.assertEqual(scheduled("main"), 1)

    def test_required_gate_retains_all_expensive_boundaries(self):
        jobs = top_level_block(WORKFLOW, "jobs")
        self.assertEqual(
            set(re.findall(r"(?m)^  ([a-z]+):$", jobs)),
            {"repository", "native", "backend", "verify"},
        )
        self.assertIn("    needs: [repository, native, backend]", jobs)
        for job in ("repository", "native", "backend"):
            self.assertIn(f"${{{{ needs.{job}.result }}}}", jobs)
        self.assertIn("    if: always()", jobs)
        self.assertIn("    name: CI Verify", jobs)
        self.assertIn("./scripts/verify-native.sh", jobs)
        self.assertIn("--configuration release --build-system native", jobs)
        self.assertIn("./scripts/verify-shared-state.sh --modern-keys", jobs)
        self.assertIn("./scripts/verify-shared-state.sh\n", jobs)

    def test_cache_contains_only_resolved_public_dependencies(self):
        cache_step = WORKFLOW.split("- name: Cache resolved Swift server dependencies\n", 1)[1]
        cache_step = cache_step.split("      - name:", 1)[0]
        paths = re.search(r"(?m)^          path: \|\n((?:            .+\n)+)", cache_step)
        self.assertIsNotNone(paths)
        entries = {line.strip() for line in paths.group(1).splitlines()}
        self.assertEqual(entries, {
            "${{ runner.temp }}/secondlook-backend/checkouts",
            "${{ runner.temp }}/secondlook-backend/repositories",
        })
        self.assertIn("${{ runner.os }}-${{ runner.arch }}-6.2.1-", cache_step)
        self.assertIn("hashFiles('Backend/Package.resolved', 'Backend/Package.swift', 'Package.swift')", cache_step)
        self.assertNotIn("restore-keys:", cache_step)

    def test_docker_dependency_cache_does_not_enter_runtime_image(self):
        self.assertIn("# syntax=docker/dockerfile:1", DOCKERFILE.splitlines()[0])
        self.assertEqual(DOCKERFILE.count("target=/root/.cache/org.swift.swiftpm"), 2)
        self.assertIn("resolve --force-resolved-versions", DOCKERFILE)
        build, runtime = DOCKERFILE.split(" AS runtime\n", 1)
        self.assertIn("--cache-path /root/.cache/org.swift.swiftpm", build)
        self.assertNotIn("/root/.cache", runtime)
        self.assertIn("USER secondlook:secondlook", runtime)


if __name__ == "__main__":
    unittest.main()
