#!/usr/bin/env python3
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CI_CHECK_SCRIPT = REPO_ROOT / "ci-check.sh"


class CiCheckScriptTests(unittest.TestCase):
    def test_ci_check_ensures_fuzz_toolchain_when_configured(self) -> None:
        script = CI_CHECK_SCRIPT.read_text(encoding="utf-8")
        block_start = script.index(
            'if [ "${RS_CI_FUZZ_MODE:-smoke}" != "disabled"'
        )
        block_end = script.index("\nfi", block_start) + len("\nfi")
        condition_block = script[block_start:block_end]

        with tempfile.TemporaryDirectory() as temp_dir:
            script_dir = Path(temp_dir)
            checker = script_dir / "cargo-fuzz-check.sh"
            checker.write_text(
                "#!/bin/sh\n[ \"${1:-}\" = \"--is-configured\" ]\n",
                encoding="utf-8",
            )
            checker.chmod(0o755)
            harness = (
                f"SCRIPT_DIR={shlex.quote(str(script_dir))}\n"
                f"PROJECT_ROOT={shlex.quote(str(script_dir))}\n"
                "RS_CI_FUZZ_MODE=smoke\n"
                "RS_CI_FUZZ_TOOLCHAIN=nightly-test\n"
                "ensure_toolchain() { printf '%s\\n' \"$1\"; }\n"
                f"{condition_block}\n"
            )
            result = subprocess.run(
                ["bash", "-c", harness],
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("nightly-test\n", result.stdout)
        self.assertEqual("", result.stderr)

    def test_ci_check_runs_conditional_cargo_fuzz_after_tests(self) -> None:
        script = CI_CHECK_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            'RS_CI_FUZZ_TOOLCHAIN="${RS_CI_FUZZ_TOOLCHAIN:-$RS_CI_DEFAULT_LINT_TOOLCHAIN}"',
            script,
        )
        self.assertIn(
            'print_step "6/12 Running conditional cargo-fuzz smoke checks"',
            script,
        )
        self.assertIn('ensure_toolchain "$RS_CI_FUZZ_TOOLCHAIN"', script)
        self.assertIn('"${RS_CI_FUZZ_MODE:-smoke}" != "disabled"', script)
        self.assertIn('"$SCRIPT_DIR/cargo-fuzz-check.sh"', script)
        self.assertIn(
            'print_step "7/12 Building all-feature documentation',
            script,
        )
        self.assertNotIn('2b/11 Running Clippy checks', script)
        self.assertIn('2b/12 Running Clippy checks', script)

    def test_documentation_build_checks_all_features_and_missing_docs(self) -> None:
        script = CI_CHECK_SCRIPT.read_text(encoding="utf-8")

        self.assertEqual(
            2,
            script.count('RUSTDOCFLAGS="-D warnings -D missing-docs"'),
        )
        self.assertEqual(
            2,
            script.count("doc --all-features --no-deps --verbose"),
        )


if __name__ == "__main__":
    unittest.main()
