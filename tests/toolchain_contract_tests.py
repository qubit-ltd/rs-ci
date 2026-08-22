#!/usr/bin/env python3
import re
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
TOOLCHAIN_CONFIG = REPO_ROOT / "toolchains.sh"
SHELL_SCRIPTS = (
    REPO_ROOT / "align-ci.sh",
    REPO_ROOT / "ci-check.sh",
    REPO_ROOT / "cargo-feature-check.sh",
    REPO_ROOT / "cargo-fuzz-check.sh",
    REPO_ROOT / "cargo-miri-check.sh",
    REPO_ROOT / "cargo-sanitizer-check.sh",
    REPO_ROOT / "coverage.sh",
)
GITHUB_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "rust-ci.yml"
CIRCLECI_CONFIG = REPO_ROOT / ".circleci" / "config.yml"
RUSTFMT_CONFIG = REPO_ROOT / "rustfmt.toml"


class ToolchainContractTests(unittest.TestCase):
    def test_shared_defaults_pin_every_nightly_to_a_date(self) -> None:
        config = TOOLCHAIN_CONFIG.read_text(encoding="utf-8")

        self.assertIn('RS_CI_DEFAULT_BUILD_TOOLCHAIN="1.94.0"', config)
        self.assertRegex(
            config,
            r'RS_CI_DEFAULT_CARGO_LLVM_COV_VERSION="\d+\.\d+\.\d+"',
        )
        self.assertRegex(
            config,
            r'RS_CI_DEFAULT_CARGO_FUZZ_VERSION="\d+\.\d+\.\d+"',
        )
        for variable in (
            "RS_CI_DEFAULT_FMT_TOOLCHAIN",
            "RS_CI_DEFAULT_CLIPPY_TOOLCHAIN",
            "RS_CI_DEFAULT_FUZZ_TOOLCHAIN",
            "RS_CI_DEFAULT_MIRI_TOOLCHAIN",
            "RS_CI_DEFAULT_SANITIZER_TOOLCHAIN",
        ):
            self.assertRegex(
                config,
                rf'{variable}="nightly-\d{{4}}-\d{{2}}-\d{{2}}"',
            )

    def test_shell_entrypoints_load_the_shared_contract(self) -> None:
        for script_path in SHELL_SCRIPTS:
            with self.subTest(script=script_path.name):
                script = script_path.read_text(encoding="utf-8")
                self.assertIn('source "$SCRIPT_DIR/toolchains.sh"', script)
                self.assertIn("configure_rs_ci_toolchains", script)
                self.assertNotIn("RS_CI_DEFAULT_LINT_TOOLCHAIN", script)
                self.assertNotIn("${RUST_TOOLCHAIN:-", script)
                self.assertNotRegex(script, r"nightly-\d{4}-\d{2}-\d{2}")

    def test_metadata_entrypoints_use_the_configured_build_toolchain(self) -> None:
        coverage_script = (REPO_ROOT / "coverage.sh").read_text(encoding="utf-8")
        metadata_script = (REPO_ROOT / "rs-ci-metadata.sh").read_text(
            encoding="utf-8"
        )
        style_script = (REPO_ROOT / "style-check.sh").read_text(
            encoding="utf-8"
        )
        ci_script = (REPO_ROOT / "ci-check.sh").read_text(encoding="utf-8")

        self.assertIn(
            'cargo +"$RS_CI_BUILD_TOOLCHAIN" metadata',
            coverage_script,
        )
        self.assertIn(
            'cargo +"$RS_CI_BUILD_TOOLCHAIN" metadata',
            metadata_script,
        )
        self.assertIn(
            'cargo +"$RS_CI_BUILD_TOOLCHAIN" metadata',
            style_script,
        )
        self.assertIn(
            'RUSTUP_TOOLCHAIN="$RS_CI_BUILD_TOOLCHAIN"',
            ci_script,
        )

    def test_miri_and_sanitizer_jobs_install_build_toolchain_before_detection(
        self,
    ) -> None:
        workflow = GITHUB_WORKFLOW.read_text(encoding="utf-8")

        for job_name, detection_step in (
            ("miri", "Detect Miri configuration"),
            ("sanitizers", "Detect sanitizer configuration"),
        ):
            with self.subTest(job=job_name):
                job = self.extract_workflow_job(workflow, job_name)
                self.assertIn(
                    "RS_CI_BUILD_TOOLCHAIN: "
                    "${{ needs.resolve_toolchains.outputs.build }}",
                    job,
                )
                install_index = job.index("Install Rust build toolchain")
                detect_index = job.index(detection_step)
                self.assertLess(install_index, detect_index)
                self.assertIn(
                    'rustup toolchain install "$RS_CI_BUILD_TOOLCHAIN" '
                    "--profile minimal",
                    job,
                )

    def test_coverage_job_runs_readme_check_with_build_toolchain(self) -> None:
        workflow = GITHUB_WORKFLOW.read_text(encoding="utf-8")
        coverage_job = self.extract_workflow_job(workflow, "build_test_coverage")

        self.assertIn(
            'RUSTUP_TOOLCHAIN="$RS_CI_BUILD_TOOLCHAIN" '
            "python3 .rs-ci/readme-version-check.py",
            coverage_job,
        )
        self.assertIn(
            'RUSTUP_TOOLCHAIN="$RS_CI_BUILD_TOOLCHAIN" '
            "python3 ./readme-version-check.py",
            coverage_job,
        )

    def test_workflow_resolves_versions_from_the_shared_contract(self) -> None:
        workflow = GITHUB_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("resolve_toolchains:", workflow)
        self.assertIn('source "$TOOLCHAIN_CONTRACT"', workflow)
        self.assertIn("CARGO_LLVM_COV_VERSION", workflow)
        self.assertIn("CARGO_FUZZ_VERSION", workflow)
        self.assertNotIn('default: "0.6.21"', workflow)
        self.assertNotIn('default: "0.13.2"', workflow)

    def test_contract_rejects_floating_nightly_overrides(self) -> None:
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; RS_CI_FMT_TOOLCHAIN=nightly; '
                "configure_rs_ci_toolchains",
                "bash",
                str(TOOLCHAIN_CONFIG),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("must pin nightly to nightly-YYYY-MM-DD", result.stderr)

    def test_ci_templates_only_use_dated_nightly_toolchains(self) -> None:
        for config_path in (GITHUB_WORKFLOW, CIRCLECI_CONFIG):
            with self.subTest(config=config_path.name):
                content = config_path.read_text(encoding="utf-8")
                bare_nightly = re.compile(
                    r"(?:default:|TOOLCHAIN:|image:)\s+[^\n]*nightly\s*$",
                    re.MULTILINE,
                )
                self.assertIsNone(bare_nightly.search(content))
                self.assertIn('bash "$TOOLCHAIN_CONTRACT"', content)

    def test_rustfmt_documentation_uses_the_pinned_entrypoint(self) -> None:
        config = RUSTFMT_CONFIG.read_text(encoding="utf-8")

        self.assertIn("Run `./align-ci.sh`", config)
        self.assertNotIn("cargo +nightly fmt", config)

    def test_rustfmt_splits_import_items_and_preserves_style_groups(self) -> None:
        config = RUSTFMT_CONFIG.read_text(encoding="utf-8")

        self.assertIn('edition = "2024"', config)
        self.assertIn('style_edition = "2024"', config)
        self.assertIn('imports_granularity = "Item"', config)
        self.assertIn('group_imports = "StdExternalCrate"', config)
        self.assertIn("reorder_imports = true", config)
        self.assertNotIn("imports_layout", config)

    @staticmethod
    def extract_workflow_job(workflow: str, job_name: str) -> str:
        pattern = re.compile(
            rf"^  {re.escape(job_name)}:\n"
            rf"(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
            re.MULTILINE | re.DOTALL,
        )
        match = pattern.search(workflow)
        if match is None:
            raise AssertionError(f"workflow job {job_name!r} not found")
        return match.group(0)


if __name__ == "__main__":
    unittest.main()
