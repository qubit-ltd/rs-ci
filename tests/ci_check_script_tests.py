#!/usr/bin/env python3
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CI_CHECK_SCRIPT = REPO_ROOT / "ci-check.sh"


class CiCheckScriptTests(unittest.TestCase):
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
