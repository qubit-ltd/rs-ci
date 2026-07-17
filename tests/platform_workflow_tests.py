#!/usr/bin/env python3
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GITHUB_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "rust-ci.yml"
README = REPO_ROOT / "README.md"
README_ZH_CN = REPO_ROOT / "README.zh_CN.md"


class PlatformWorkflowTests(unittest.TestCase):
    def test_platform_jobs_are_opt_in(self) -> None:
        workflow = GITHUB_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("run_windows_tests:", workflow)
        self.assertIn("run_macos_tests:", workflow)
        self.assertGreaterEqual(workflow.count("default: false"), 2)
        self.assertIn(
            "inputs.run_windows_tests && github.event_name != 'schedule'",
            workflow,
        )
        self.assertIn(
            "inputs.run_macos_tests && github.event_name != 'schedule'",
            workflow,
        )

    def test_readmes_document_platform_inputs(self) -> None:
        for readme in (README, README_ZH_CN):
            content = readme.read_text(encoding="utf-8")
            self.assertIn("run_windows_tests", content)
            self.assertIn("run_macos_tests", content)


if __name__ == "__main__":
    unittest.main()
