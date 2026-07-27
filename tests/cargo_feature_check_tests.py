#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "cargo-feature-check.sh"


class CargoFeatureCheckTests(unittest.TestCase):
    def run_checker(
        self,
        project_root: Path,
        *arguments: str,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["RS_CI_PROJECT_ROOT"] = str(project_root)
        environment["RS_CI_BUILD_TOOLCHAIN"] = "1.94.0"
        environment["RS_CI_CLIPPY_TOOLCHAIN"] = "nightly-2026-06-05"
        return subprocess.run(
            ["bash", str(CHECKER), *arguments],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def test_package_selection_is_forwarded_to_cargo(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            bin_dir = project_root / "bin"
            bin_dir.mkdir()
            cargo_log = project_root / "cargo.log"
            cargo = bin_dir / "cargo"
            cargo.write_text(
                f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{cargo_log}"\n',
                encoding="utf-8",
            )
            cargo.chmod(0o755)
            config = {
                "version": 1,
                "checks": [
                    {
                        "name": "workspace",
                        "commands": ["check"],
                        "packages": ["runtime", "runtime-derive"],
                        "defaultFeatures": False,
                        "features": [],
                    }
                ],
            }
            (project_root / ".rs-ci-cargo-matrix.json").write_text(
                json.dumps(config),
                encoding="utf-8",
            )
            environment_path = os.environ["PATH"]
            os.environ["PATH"] = f"{bin_dir}{os.pathsep}{environment_path}"
            try:
                result = self.run_checker(project_root, "run-index", "0")
            finally:
                os.environ["PATH"] = environment_path
            command = cargo_log.read_text(encoding="utf-8")

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("--package runtime", command)
        self.assertIn("--package runtime-derive", command)

    def test_invalid_package_names_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            config = {
                "version": 1,
                "checks": [
                    {
                        "name": "invalid",
                        "commands": ["check"],
                        "packages": ["../outside"],
                    }
                ],
            }
            (project_root / ".rs-ci-cargo-matrix.json").write_text(
                json.dumps(config),
                encoding="utf-8",
            )

            result = self.run_checker(project_root, "validate")

        self.assertNotEqual(0, result.returncode)


if __name__ == "__main__":
    unittest.main()
