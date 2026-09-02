#!/usr/bin/env python3
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "rust-ci.yml"


def job_block(workflow: str, job: str, next_job: str) -> str:
    start = workflow.index(f"  {job}:\n")
    end = workflow.index(f"  {next_job}:\n", start)
    return workflow[start:end]


class AdvancedChecksWorkflowTests(unittest.TestCase):
    def test_cargo_matrix_reuses_resolved_toolchain_and_shared_checker(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        block = job_block(workflow, "cargo_feature_matrix", "build_test_coverage")

        self.assertIn(
            "name: Cargo compatibility matrix (${{ matrix.name }})",
            block,
        )
        self.assertIn("needs:\n      - fast_checks", block)
        self.assertIn(
            "RS_CI_BUILD_TOOLCHAIN: ${{ needs.resolve_toolchains.outputs.build }}",
            block,
        )
        self.assertIn("Restore cargo cache", block)
        self.assertIn("cargo-feature-check.sh run-index", block)

    def test_workflow_resolves_pinned_toolchains_from_the_contract(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("resolve_toolchains:", workflow)
        self.assertIn('source "$TOOLCHAIN_CONTRACT"', workflow)
        self.assertIn(
            "RS_CI_MIRI_TOOLCHAIN: ${{ needs.resolve_toolchains.outputs.miri }}",
            workflow,
        )
        self.assertIn(
            "RS_CI_SANITIZER_TOOLCHAIN: ${{ needs.resolve_toolchains.outputs.sanitizer }}",
            workflow,
        )

    def test_miri_job_detects_before_installing_and_delegates_execution(
        self,
    ) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        block = job_block(workflow, "miri", "sanitizers")

        self.assertIn("needs:\n      - fast_checks", block)
        self.assertIn("cargo-miri-check.sh", block)
        self.assertIn("--is-configured", block)
        self.assertIn("MIRI_CONFIG_STATUS", block)
        self.assertIn("cargo metadata --no-deps --format-version 1", block)
        self.assertIn("MIRI_OPTED_IN", block)
        self.assertIn(
            "Miri is configured, but cargo-miri-check.sh was not found",
            block,
        )
        self.assertIn('if [ "$MIRI_CONFIG_STATUS" -eq 1 ]; then', block)
        self.assertIn("rustup toolchain install", block)
        self.assertIn("--component miri", block)
        self.assertIn('miri setup', block)
        self.assertIn(
            "if: ${{ steps.miri.outputs.enabled == 'true' }}",
            block,
        )
        self.assertLess(
            block.index("Detect Miri configuration"),
            block.index("Install Miri toolchain"),
        )
        self.assertLess(
            block.index("Install Miri toolchain"),
            block.index("Run configured Miri checks"),
        )

    def test_sanitizer_job_detects_before_installing_and_delegates_execution(
        self,
    ) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        block = job_block(workflow, "sanitizers", "fuzz_smoke")

        self.assertIn("needs:\n      - fast_checks", block)
        self.assertIn("cargo-sanitizer-check.sh", block)
        self.assertIn("--is-configured address", block)
        self.assertIn("SANITIZER_CONFIG_STATUS", block)
        self.assertIn("cargo metadata --no-deps --format-version 1", block)
        self.assertIn("SANITIZER_OPTED_IN", block)
        self.assertIn(
            "AddressSanitizer is configured, but "
            "cargo-sanitizer-check.sh was not found",
            block,
        )
        self.assertIn(
            'if [ "$SANITIZER_CONFIG_STATUS" -eq 1 ]; then',
            block,
        )
        self.assertIn("rustup toolchain install", block)
        self.assertIn("--component rust-src", block)
        self.assertIn(
            "if: ${{ steps.sanitizer.outputs.enabled == 'true' }}",
            block,
        )
        self.assertLess(
            block.index("Detect sanitizer configuration"),
            block.index("Install sanitizer toolchain"),
        )
        self.assertLess(
            block.index("Install sanitizer toolchain"),
            block.index("Run configured sanitizer checks"),
        )

    def test_circleci_is_not_extended_with_advanced_checks(self) -> None:
        circleci = (REPO_ROOT / ".circleci" / "config.yml").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("cargo-miri-check.sh", circleci)
        self.assertNotIn("cargo-sanitizer-check.sh", circleci)


if __name__ == "__main__":
    unittest.main()
