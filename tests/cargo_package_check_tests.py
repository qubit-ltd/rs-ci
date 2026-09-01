#!/usr/bin/env python3
import os
import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "cargo-package-check.sh"


def write_fake_cargo(
    bin_dir: Path,
    log_path: Path,
    metadata_path: Path,
    exit_code: int = 0,
) -> None:
    cargo = bin_dir / "cargo"
    cargo.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            case " $* " in
                *" metadata "*) cat "{metadata_path}"; exit 0 ;;
            esac
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


def write_metadata(
    path: Path,
    packages: list[tuple[str, str, list[str] | None]],
) -> None:
    data = {
        "workspace_members": [package_id for package_id, _, _ in packages],
        "packages": [
            {"id": package_id, "name": name, "publish": publish}
            for package_id, name, publish in packages
        ],
    }
    path.write_text(json.dumps(data), encoding="utf-8")


class CargoPackageCheckTests(unittest.TestCase):
    def test_runs_cargo_package_allow_dirty_from_project_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            log_path = Path(tmp) / "cargo.log"
            metadata_path = Path(tmp) / "metadata.json"
            write_metadata(metadata_path, [("example 0.1.0", "example", None)])
            write_fake_cargo(fake_bin, log_path, metadata_path)

            result = run_checker(root, fake_bin)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                f"{root} :: +1.94.0 package --package example --allow-dirty\n",
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
            metadata_path = Path(tmp) / "metadata.json"
            write_metadata(metadata_path, [("example 0.1.0", "example", None)])
            write_fake_cargo(fake_bin, log_path, metadata_path, exit_code=17)

            result = run_checker(root, fake_bin)

            self.assertEqual(result.returncode, 17)
            self.assertIn("Cargo package verification failed", result.stderr)

    def test_packages_publishable_workspace_members_individually(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            log_path = Path(tmp) / "cargo.log"
            metadata_path = Path(tmp) / "metadata.json"
            write_metadata(
                metadata_path,
                [
                    ("runtime 0.1.0", "runtime", None),
                    ("derive 0.1.0", "runtime-derive", ["crates-io"]),
                    ("fixtures 0.1.0", "fixtures", []),
                ],
            )
            write_fake_cargo(fake_bin, log_path, metadata_path)

            result = run_checker(root, fake_bin)

            commands = log_path.read_text(encoding="utf-8").splitlines()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(2, len(commands))
        self.assertTrue(commands[0].endswith(":: +1.94.0 package --package runtime --allow-dirty"))
        self.assertTrue(
            commands[1].endswith(
                ":: +1.94.0 package --package runtime-derive --allow-dirty"
            )
        )


if __name__ == "__main__":
    unittest.main()
