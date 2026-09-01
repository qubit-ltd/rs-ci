#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "cargo-miri-check.sh"


class CargoMiriCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name) / "project"
        self.root.mkdir()
        (self.root / "Cargo.toml").write_text(
            "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n",
            encoding="utf-8",
        )
        self.bin_dir = Path(self.temp_dir.name) / "bin"
        self.bin_dir.mkdir()
        self.metadata_file = Path(self.temp_dir.name) / "metadata.json"
        self.command_log = Path(self.temp_dir.name) / "cargo.log"
        cargo = self.bin_dir / "cargo"
        cargo.write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                case "${1:-}" in
                    metadata)
                        cat "$FAKE_CARGO_METADATA"
                        exit 0
                        ;;
                    +*)
                        if [ "${2:-}" = "metadata" ]; then
                            cat "$FAKE_CARGO_METADATA"
                            exit 0
                        fi
                        ;;
                esac
                printf '%s\n' "$*" >> "$FAKE_CARGO_LOG"
                printf '%s\n' "${FAKE_MIRI_OUTPUT:-running 1 test}"
                exit "${FAKE_MIRI_STATUS:-0}"
                """
            ),
            encoding="utf-8",
        )
        cargo.chmod(0o755)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_metadata(self, rs_ci: object | None) -> None:
        package_id = "demo 0.1.0 (path+file:///demo)"
        package_metadata = {} if rs_ci is None else {"rs-ci": rs_ci}
        self.metadata_file.write_text(
            json.dumps(
                {
                    "packages": [
                        {
                            "id": package_id,
                            "name": "demo",
                            "manifest_path": str(self.root / "Cargo.toml"),
                            "metadata": package_metadata,
                        }
                    ],
                    "workspace_members": [package_id],
                    "workspace_default_members": [package_id],
                    "workspace_root": str(self.root),
                }
            ),
            encoding="utf-8",
        )

    def run_checker(
        self,
        *arguments: str,
        rs_ci: object | None,
        status: int = 0,
        output: str = "running 1 test",
        cargo_target_dir: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        self.write_metadata(rs_ci)
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env['PATH']}"
        env["FAKE_CARGO_METADATA"] = str(self.metadata_file)
        env["FAKE_CARGO_LOG"] = str(self.command_log)
        env["FAKE_MIRI_STATUS"] = str(status)
        env["FAKE_MIRI_OUTPUT"] = output
        env["RS_CI_PROJECT_ROOT"] = str(self.root)
        env["RS_CI_MIRI_TOOLCHAIN"] = "nightly-2099-01-01"
        if cargo_target_dir is not None:
            env["CARGO_TARGET_DIR"] = str(cargo_target_dir)
        return subprocess.run(
            ["bash", str(CHECKER), *arguments],
            cwd="/",
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_detection_uses_tri_state_contract(self) -> None:
        enabled = self.run_checker(
            "--is-configured",
            rs_ci={"miri": True},
        )
        disabled = self.run_checker("--is-configured", rs_ci=None)
        invalid = self.run_checker(
            "--is-configured",
            rs_ci={"miri": "true"},
        )

        self.assertEqual(0, enabled.returncode, enabled.stderr)
        self.assertEqual(1, disabled.returncode, disabled.stderr)
        self.assertNotIn(invalid.returncode, (0, 1))

    def test_unconfigured_project_skips_without_invoking_miri(self) -> None:
        result = self.run_checker(rs_ci=None)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("Miri is not configured", result.stdout)
        self.assertFalse(self.command_log.exists())

    def test_runs_miri_for_configured_package(self) -> None:
        result = self.run_checker(rs_ci={"miri": True})

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            "+nightly-2099-01-01 miri test --all-features --package demo\n",
            self.command_log.read_text(encoding="utf-8"),
        )

    def test_guards_empty_miri_test_args_for_bash_32(self) -> None:
        script = CHECKER.read_text(encoding="utf-8")

        self.assertRegex(
            script,
            r'if \[ \$\{#TEST_ARGS\[@\]\} -gt 0 \]; then'
            r'(?s:.*?)miri_args\+=\("\$\{TEST_ARGS\[@\]\}"\)',
        )

    def test_appends_configured_miri_test_arguments(self) -> None:
        result = self.run_checker(
            rs_ci={
                "miri": True,
                "miri-test-args": [
                    "--test",
                    "tests",
                    "tree::json tree mutator tests",
                ],
            }
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            "+nightly-2099-01-01 miri test --all-features --package demo "
            "--test tests tree::json tree mutator tests\n",
            self.command_log.read_text(encoding="utf-8"),
        )

    def test_propagates_miri_failure(self) -> None:
        result = self.run_checker(rs_ci={"miri": True}, status=7)

        self.assertEqual(7, result.returncode)

    def test_rejects_successful_miri_run_that_selects_no_tests(self) -> None:
        result = self.run_checker(
            rs_ci={
                "miri": True,
                "miri-test-args": ["--test", "tests", "missing_filter"],
            },
            output="running 0 tests",
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("Miri selected no tests for package 'demo'", result.stderr)

    def test_rejects_unknown_argument(self) -> None:
        result = self.run_checker("--unknown", rs_ci={"miri": True})

        self.assertNotEqual(0, result.returncode)
        self.assertIn("Usage", result.stderr)

    def test_clears_stale_miri_cache_when_cargo_lock_changes(self) -> None:
        target_root = self.root / "target" / "rs-ci"
        miri_target = target_root / "miri"
        miri_target.mkdir(parents=True)
        stale_marker = miri_target / "stale-artifact.txt"
        stale_marker.write_text("old", encoding="utf-8")
        stamp = miri_target / ".rs-ci-miri-input-stamp"
        stamp.write_text(
            "toolchain=nightly-2099-01-01\nmissing-lock\n",
            encoding="utf-8",
        )
        (self.root / "Cargo.lock").write_text("[[package]]\nname = \"demo\"\n", encoding="utf-8")

        result = self.run_checker(
            rs_ci={"miri": True},
            cargo_target_dir=target_root,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(stale_marker.exists())
        self.assertIn("Miri build inputs changed", result.stdout)

    def test_preserves_miri_cache_when_inputs_unchanged(self) -> None:
        lock_content = "[[package]]\nname = \"demo\"\n"
        (self.root / "Cargo.lock").write_text(lock_content, encoding="utf-8")

        target_root = self.root / "target" / "rs-ci"
        miri_target = target_root / "miri"
        miri_target.mkdir(parents=True)
        marker = miri_target / "cached-artifact.txt"
        marker.write_text("keep", encoding="utf-8")
        stamp_content = f"toolchain=nightly-2099-01-01\n{lock_content}"
        (miri_target / ".rs-ci-miri-input-stamp").write_text(
            stamp_content,
            encoding="utf-8",
        )

        result = self.run_checker(
            rs_ci={"miri": True},
            cargo_target_dir=target_root,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(marker.exists())
        self.assertNotIn("Miri build inputs changed", result.stdout)


if __name__ == "__main__":
    unittest.main()
