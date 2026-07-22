#!/usr/bin/env python3
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CI_CHECK_SCRIPT = REPO_ROOT / "ci-check.sh"
ALIGN_CI_SCRIPT = REPO_ROOT / "align-ci.sh"


class CiCheckScriptTests(unittest.TestCase):
    def run_format_block(
        self,
        script_path: Path,
        start_marker: str,
        end_marker: str,
        *,
        has_fuzz_manifest: bool,
        fail_fuzz_format: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        script = script_path.read_text(encoding="utf-8")
        block_start = script.index(start_marker)
        block_end = script.index(end_marker, block_start)
        format_block = script[block_start:block_end]

        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            rustfmt_config = project_root / "rustfmt.toml"
            rustfmt_config.write_text("edition = \"2024\"\n", encoding="utf-8")
            if has_fuzz_manifest:
                fuzz_dir = project_root / "fuzz"
                fuzz_dir.mkdir()
                (fuzz_dir / "Cargo.toml").write_text(
                    "[package]\nname = \"fuzz-targets\"\nversion = \"0.0.0\"\n",
                    encoding="utf-8",
                )
            cargo_log = project_root / "cargo.log"
            harness = (
                "set -e\n"
                f"PROJECT_ROOT={shlex.quote(str(project_root))}\n"
                f"RUSTFMT_CONFIG={shlex.quote(str(rustfmt_config))}\n"
                f"CARGO_LOG={shlex.quote(str(cargo_log))}\n"
                "RS_CI_FMT_TOOLCHAIN=nightly-2099-01-01\n"
                "RS_CI_FUZZ_MODE=disabled\n"
                f"FAIL_FUZZ_FORMAT={'1' if fail_fuzz_format else '0'}\n"
                "print_success() { :; }\n"
                "print_error() { :; }\n"
                "cargo() {\n"
                "  local separator=''\n"
                "  local argument\n"
                "  for argument in \"$@\"; do\n"
                "    printf '%s%s' \"$separator\" \"$argument\" >> \"$CARGO_LOG\"\n"
                "    separator='|'\n"
                "  done\n"
                "  printf '\\n' >> \"$CARGO_LOG\"\n"
                "  if [ \"$FAIL_FUZZ_FORMAT\" = '1' ]; then\n"
                "    case \"$*\" in\n"
                "      *fuzz/Cargo.toml*) return 7 ;;\n"
                "    esac\n"
                "  fi\n"
                "}\n"
                f"{format_block}\n"
            )
            result = subprocess.run(
                ["bash", "-c", harness],
                text=True,
                capture_output=True,
                check=False,
            )
            commands = (
                cargo_log.read_text(encoding="utf-8").splitlines()
                if cargo_log.exists()
                else []
            )
        return result, commands

    def run_ci_format_block(
        self,
        *,
        has_fuzz_manifest: bool,
        fail_fuzz_format: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        return self.run_format_block(
            CI_CHECK_SCRIPT,
            'if cargo +"$RS_CI_FMT_TOOLCHAIN" fmt -- --check',
            '\necho ""\n\nprint_step "2/13',
            has_fuzz_manifest=has_fuzz_manifest,
            fail_fuzz_format=fail_fuzz_format,
        )

    def run_align_format_block(
        self,
        *,
        has_fuzz_manifest: bool,
        fail_fuzz_format: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        return self.run_format_block(
            ALIGN_CI_SCRIPT,
            'echo "==> cargo +$RS_CI_FMT_TOOLCHAIN fmt -- --config-path',
            '\necho "==> cargo +$RS_CI_CLIPPY_TOOLCHAIN clippy --fix',
            has_fuzz_manifest=has_fuzz_manifest,
            fail_fuzz_format=fail_fuzz_format,
        )

    def test_format_scripts_skip_fuzz_without_manifest(self) -> None:
        ci_result, ci_commands = self.run_ci_format_block(
            has_fuzz_manifest=False,
        )
        align_result, align_commands = self.run_align_format_block(
            has_fuzz_manifest=False,
        )

        self.assertEqual(0, ci_result.returncode, ci_result.stderr)
        self.assertEqual(0, align_result.returncode, align_result.stderr)
        self.assertEqual(1, len(ci_commands), ci_commands)
        self.assertEqual(1, len(align_commands), align_commands)

    def test_format_scripts_include_fuzz_manifest_when_fuzz_disabled(
        self,
    ) -> None:
        ci_result, ci_commands = self.run_ci_format_block(
            has_fuzz_manifest=True,
        )
        align_result, align_commands = self.run_align_format_block(
            has_fuzz_manifest=True,
        )

        self.assertEqual(0, ci_result.returncode, ci_result.stderr)
        self.assertEqual(0, align_result.returncode, align_result.stderr)
        self.assertEqual(2, len(ci_commands), ci_commands)
        self.assertEqual(2, len(align_commands), align_commands)
        self.assertIn("--manifest-path", ci_commands[1])
        self.assertIn("fuzz/Cargo.toml", ci_commands[1])
        self.assertIn("|--check|", ci_commands[1])
        self.assertIn("--manifest-path", align_commands[1])
        self.assertIn("fuzz/Cargo.toml", align_commands[1])
        self.assertNotIn("|--check|", align_commands[1])

    def test_format_scripts_propagate_fuzz_format_failure(self) -> None:
        ci_result, _ = self.run_ci_format_block(
            has_fuzz_manifest=True,
            fail_fuzz_format=True,
        )
        align_result, _ = self.run_align_format_block(
            has_fuzz_manifest=True,
            fail_fuzz_format=True,
        )

        self.assertNotEqual(0, ci_result.returncode)
        self.assertNotEqual(0, align_result.returncode)

    def test_ci_check_delegates_style_policy_without_rule_overrides(
        self,
    ) -> None:
        script = CI_CHECK_SCRIPT.read_text(encoding="utf-8")
        block_start = script.index(
            'print_step "3/13 Running Rust style checks"'
        )
        block_end = script.index(
            'print_success "Rust style checks passed"',
            block_start,
        )
        style_block = script[block_start:block_end]

        self.assertIn(
            'RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/style-check.sh"',
            style_block,
        )
        self.assertNotIn("STYLE_ENFORCE_", style_block)

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
                "RS_CI_FUZZ_TOOLCHAIN=nightly-2099-01-01\n"
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
        self.assertEqual("nightly-2099-01-01\n", result.stdout)
        self.assertEqual("", result.stderr)

    def test_ci_check_runs_conditional_cargo_fuzz_after_tests(self) -> None:
        script = CI_CHECK_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            'source "$SCRIPT_DIR/toolchains.sh"',
            script,
        )
        self.assertIn("configure_rs_ci_toolchains", script)
        self.assertIn(
            'print_step "6/13 Running conditional cargo-fuzz smoke checks"',
            script,
        )
        self.assertIn('ensure_toolchain "$RS_CI_FUZZ_TOOLCHAIN"', script)
        self.assertIn('"${RS_CI_FUZZ_MODE:-smoke}" != "disabled"', script)
        self.assertIn('"$SCRIPT_DIR/cargo-fuzz-check.sh"', script)
        self.assertIn(
            'print_step "8/13 Building all-feature documentation',
            script,
        )
        self.assertNotIn('2b/12 Running Clippy checks', script)
        self.assertIn('2b/13 Running Clippy checks', script)

    def test_ci_check_runs_conditional_loom_after_fuzz(self) -> None:
        script = CI_CHECK_SCRIPT.read_text(encoding="utf-8")

        fuzz_step = script.index(
            'print_step "6/13 Running conditional cargo-fuzz smoke checks"'
        )
        self.assertIn(
            'print_step "7/13 Running conditional Loom model checks"',
            script,
        )
        loom_step = script.index(
            'print_step "7/13 Running conditional Loom model checks"'
        )
        self.assertGreater(loom_step, fuzz_step)
        self.assertIn('"$SCRIPT_DIR/cargo-loom-check.sh"', script)

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
