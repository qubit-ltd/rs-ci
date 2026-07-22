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

    def test_platform_jobs_test_all_features(self) -> None:
        workflow = GITHUB_WORKFLOW.read_text(encoding="utf-8")
        windows_start = workflow.index("\n  windows_test:")
        macos_start = workflow.index("\n  macos_test:")
        windows_job = workflow[windows_start:macos_start]
        macos_job = workflow[macos_start:]

        self.assertIn("test --all-features --verbose", windows_job)
        self.assertIn("test --all-features --verbose", macos_job)

    def test_remote_documentation_matches_local_policy(self) -> None:
        workflow = GITHUB_WORKFLOW.read_text(encoding="utf-8")
        documentation_start = workflow.index("\n  doc:")
        audit_start = workflow.index("\n  security_audit:")
        documentation_job = workflow[documentation_start:audit_start]

        self.assertIn(
            'RUSTDOCFLAGS="-D warnings -D missing-docs"',
            documentation_job,
        )
        self.assertIn(
            "doc --all-features --no-deps --verbose",
            documentation_job,
        )


if __name__ == "__main__":
    unittest.main()
