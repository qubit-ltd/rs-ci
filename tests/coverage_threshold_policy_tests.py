#!/usr/bin/env python3
import re
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
POLICY_SCRIPT = REPO_ROOT / "coverage-threshold-policy-check.sh"
CI_CHECK_SCRIPT = REPO_ROOT / "ci-check.sh"
COVERAGE_SCRIPT = REPO_ROOT / "coverage.sh"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "rust-ci.yml"
CIRCLECI = REPO_ROOT / ".circleci" / "config.yml"


class CoverageThresholdPolicyTests(unittest.TestCase):
    def test_policy_script_passes_on_current_tree(self) -> None:
        result = subprocess.run(
            [str(POLICY_SCRIPT)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(
            0,
            result.returncode,
            msg=result.stdout + result.stderr,
        )
        self.assertIn("Coverage threshold policy check passed", result.stdout)

    def test_ci_check_does_not_disable_thresholds(self) -> None:
        script = CI_CHECK_SCRIPT.read_text(encoding="utf-8")
        self.assertNotRegex(
            script,
            r"(^|[\s\\])COVERAGE_ENFORCE_THRESHOLDS=0([\s\\]|$)",
        )
        self.assertIn("coverage-threshold-policy-check.sh", script)

    def test_coverage_script_defaults_to_enforced_thresholds(self) -> None:
        script = COVERAGE_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'COVERAGE_ENFORCE_THRESHOLDS="${COVERAGE_ENFORCE_THRESHOLDS:-1}"',
            script,
        )
        self.assertIn("require_coverage_threshold_enforcement", script)

    def test_reusable_workflow_defaults_to_enforced_thresholds(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        match = re.search(
            r"coverage_enforce_thresholds:\s*\n(?:[^\n]*\n){0,4}\s*default:\s*\"(?P<value>[^\"]+)\"",
            workflow,
        )
        self.assertIsNotNone(match)
        assert match is not None
        self.assertEqual("1", match.group("value"))

    def test_circleci_template_does_not_disable_thresholds(self) -> None:
        config = CIRCLECI.read_text(encoding="utf-8")
        self.assertNotIn("COVERAGE_ENFORCE_THRESHOLDS=0", config)


if __name__ == "__main__":
    unittest.main()
