#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "cargo-package-check.sh"


def write_fake_cargo(bin_dir: Path, log_path: Path, exit_code: int = 0) -> None:
    cargo = bin_dir / "cargo"
    cargo.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            printf '%s\\n' "$PWD :: $*" >> "{log_path}"
            exit {exit_code}
            """
        ),
        encoding="utf-8",
    )
    cargo.chmod(0o755)


def run_checker(root: Path, fake_bin: Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["RS_CI_PROJECT_ROOT"] = str(root)
    return subprocess.run(
        ["bash", str(CHECKER)],
        cwd="/",
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


class CargoPackageCheckTests(unittest.TestCase):
    def test_runs_cargo_package_allow_dirty_from_project_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            log_path = Path(tmp) / "cargo.log"
            write_fake_cargo(fake_bin, log_path)

            result = run_checker(root, fake_bin)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                f"{root} :: +1.94.0 package --allow-dirty\n",
                log_path.read_text(encoding="utf-8"),
            )
            self.assertIn("Cargo package verification passed", result.stdout)

    def test_propagates_cargo_package_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            log_path = Path(tmp) / "cargo.log"
            write_fake_cargo(fake_bin, log_path, exit_code=17)

            result = run_checker(root, fake_bin)

            self.assertEqual(result.returncode, 17)
            self.assertIn("Cargo package verification failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
