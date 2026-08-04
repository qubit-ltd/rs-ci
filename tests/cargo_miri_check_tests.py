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
                if [ "${1:-}" = "metadata" ]; then
                    cat "$FAKE_CARGO_METADATA"
                    exit 0
                fi
                printf '%s\n' "$*" >> "$FAKE_CARGO_LOG"
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
    ) -> subprocess.CompletedProcess[str]:
        self.write_metadata(rs_ci)
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env['PATH']}"
        env["FAKE_CARGO_METADATA"] = str(self.metadata_file)
        env["FAKE_CARGO_LOG"] = str(self.command_log)
        env["FAKE_MIRI_STATUS"] = str(status)
        env["RS_CI_PROJECT_ROOT"] = str(self.root)
        env["RS_CI_MIRI_TOOLCHAIN"] = "nightly-2099-01-01"
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

    def test_propagates_miri_failure(self) -> None:
        result = self.run_checker(rs_ci={"miri": True}, status=7)

        self.assertEqual(7, result.returncode)

    def test_rejects_unknown_argument(self) -> None:
        result = self.run_checker("--unknown", rs_ci={"miri": True})

        self.assertNotEqual(0, result.returncode)
        self.assertIn("Usage", result.stderr)


if __name__ == "__main__":
    unittest.main()
