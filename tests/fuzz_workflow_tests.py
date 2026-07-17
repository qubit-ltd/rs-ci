#!/usr/bin/env python3
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GITHUB_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "rust-ci.yml"
CIRCLECI_CONFIG = REPO_ROOT / ".circleci" / "config.yml"
README = REPO_ROOT / "README.md"
README_ZH_CN = REPO_ROOT / "README.zh_CN.md"


class FuzzWorkflowTests(unittest.TestCase):
    def test_github_workflow_has_conditional_fuzz_smoke_job(self) -> None:
        workflow = GITHUB_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("cargo_fuzz_version:", workflow)
        self.assertIn('default: "0.13.2"', workflow)
        self.assertIn("cargo_fuzz_toolchain:", workflow)
        self.assertIn("cargo_fuzz_mode:", workflow)
        self.assertIn(
            'description: "Conditional fuzz check mode: smoke, build-only, or disabled."',
            workflow,
        )
        self.assertIn("cargo_fuzz_seconds_per_target:", workflow)
        self.assertIn("cargo_fuzz_max_len:", workflow)
        self.assertIn("RS_CI_FUZZ_MAX_LEN", workflow)
        self.assertIn("fuzz_smoke:", workflow)
        self.assertIn("cargo-fuzz-check.sh", workflow)
        self.assertIn("--is-configured", workflow)
        self.assertIn('[ "$RS_CI_FUZZ_MODE" = "disabled" ]', workflow)
        self.assertIn("cargo install --locked", workflow)
        self.assertIn("fuzz/artifacts", workflow)

    def test_circleci_template_has_conditional_fuzz_smoke_job(self) -> None:
        config = CIRCLECI_CONFIG.read_text(encoding="utf-8")

        self.assertIn("fuzz_smoke:", config)
        self.assertIn('CARGO_FUZZ_VERSION: "0.13.2"', config)
        self.assertIn('RS_CI_FUZZ_MAX_LEN: "4096"', config)
        self.assertIn("cargo-fuzz-check.sh", config)
        self.assertIn("--is-configured", config)
        self.assertIn('[ "$RS_CI_FUZZ_MODE" = "disabled" ]', config)
        self.assertIn("cargo install --locked", config)
        self.assertIn("Prepare fuzz artifact directory", config)
        self.assertIn("fuzz/artifacts", config)

    def test_readmes_document_conditional_cargo_fuzz(self) -> None:
        for readme in (README, README_ZH_CN):
            content = readme.read_text(encoding="utf-8")
            self.assertIn("cargo-fuzz-check.sh", content)
            self.assertIn("RS_CI_FUZZ_MODE", content)
            self.assertIn("RS_CI_FUZZ_TOOLCHAIN", content)
            self.assertIn("RS_CI_FUZZ_SECONDS_PER_TARGET", content)
            self.assertIn("RS_CI_FUZZ_MAX_LEN", content)


if __name__ == "__main__":
    unittest.main()
