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
)
GITHUB_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "rust-ci.yml"
CIRCLECI_CONFIG = REPO_ROOT / ".circleci" / "config.yml"
RUSTFMT_CONFIG = REPO_ROOT / "rustfmt.toml"


class ToolchainContractTests(unittest.TestCase):
    def test_shared_defaults_pin_every_nightly_to_a_date(self) -> None:
        config = TOOLCHAIN_CONFIG.read_text(encoding="utf-8")

        self.assertIn('RS_CI_DEFAULT_BUILD_TOOLCHAIN="1.94.0"', config)
        for variable in (
            "RS_CI_DEFAULT_FMT_TOOLCHAIN",
            "RS_CI_DEFAULT_CLIPPY_TOOLCHAIN",
            "RS_CI_DEFAULT_FUZZ_TOOLCHAIN",
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


if __name__ == "__main__":
    unittest.main()
