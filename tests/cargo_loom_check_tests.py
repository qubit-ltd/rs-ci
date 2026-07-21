#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "cargo-loom-check.sh"


def write_manifest(project_root: Path, development_dependencies: str = "") -> None:
    (project_root / "Cargo.toml").write_text(
        "[package]\n"
        'name = "example"\n'
        'version = "0.1.0"\n\n'
        f"{development_dependencies}",
        encoding="utf-8",
    )


def write_fake_cargo(bin_dir: Path, command_log: Path, rustflags_log: Path) -> None:
    cargo = bin_dir / "cargo"
    cargo.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$*\" >> \"{command_log}\"\n"
        f"printf '%s\\n' \"${{RUSTFLAGS-}}\" >> \"{rustflags_log}\"\n",
        encoding="utf-8",
    )
    cargo.chmod(0o755)


class CargoLoomCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.project_root = self.root / "project"
        self.project_root.mkdir()
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.command_log_path = self.root / "cargo.log"
        self.rustflags_log_path = self.root / "rustflags.log"
        write_fake_cargo(
            self.bin_dir,
            self.command_log_path,
            self.rustflags_log_path,
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_checker(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}/usr/bin{os.pathsep}/bin",
                "RS_CI_PROJECT_ROOT": str(self.project_root),
                "RS_CI_BUILD_TOOLCHAIN": "1.94.0",
            }
        )
        return subprocess.run(
            ["bash", str(CHECKER), *arguments],
            cwd="/",
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def command_log(self) -> str:
        return self.command_log_path.read_text(encoding="utf-8")

    def rustflags_log(self) -> str:
        return self.rustflags_log_path.read_text(encoding="utf-8")

    def test_skips_project_without_loom_dev_dependency(self) -> None:
        write_manifest(self.project_root)

        result = self.run_checker()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("loom is not configured", result.stdout)
        self.assertFalse(self.command_log_path.exists())

    def test_detection_returns_nonzero_without_loom_dev_dependency(self) -> None:
        write_manifest(self.project_root)

        result = self.run_checker("--is-configured")

        self.assertNotEqual(0, result.returncode)
        self.assertFalse(self.command_log_path.exists())

    def test_detection_returns_zero_for_loom_dev_dependency(self) -> None:
        write_manifest(self.project_root, '[dev-dependencies]\nloom = "0.7"\n')

        result = self.run_checker("--is-configured")

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(self.command_log_path.exists())

    def test_runs_release_all_feature_tests_with_loom_cfg(self) -> None:
        write_manifest(
            self.project_root,
            '[dev-dependencies]\nloom = { version = "0.7" }\n',
        )

        result = self.run_checker()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(
            "+1.94.0 test --release --all-features --verbose",
            self.command_log(),
        )
        self.assertIn("--cfg loom", self.rustflags_log())


if __name__ == "__main__":
    unittest.main()
