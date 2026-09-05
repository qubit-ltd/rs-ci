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

    def write_fake_cargo(
        self,
        project_root: Path,
        *,
        resolved_version: str,
        fail_test: bool = False,
    ) -> tuple[Path, Path]:
        bin_dir = project_root / "bin"
        bin_dir.mkdir()
        cargo_log = project_root / "cargo.log"
        cargo = bin_dir / "cargo"
        cargo.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            f'printf "%s\\n" "$*" >> "{cargo_log}"\n'
            'case "$*" in\n'
            "  *\" update -p \"*) printf 'updated\\n' > Cargo.lock ;;\n"
            "  *\" metadata --locked --format-version 1\"*)\n"
            f"    printf '%s\\n' '{{\"packages\":[{{\"name\":\"serde_json\",\"version\":\"{resolved_version}\"}}]}}'\n"
            "    ;;\n"
            "  *\" test \"*)\n"
            f"    exit {7 if fail_test else 0}\n"
            "    ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        cargo.chmod(0o755)
        return bin_dir, cargo_log

    def run_with_path(
        self,
        project_root: Path,
        bin_dir: Path,
        *arguments: str,
    ) -> subprocess.CompletedProcess[str]:
        environment_path = os.environ["PATH"]
        os.environ["PATH"] = f"{bin_dir}{os.pathsep}{environment_path}"
        try:
            return self.run_checker(project_root, *arguments)
        finally:
            os.environ["PATH"] = environment_path

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

    def test_precise_dependency_is_resolved_tested_locked_and_restored(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            original_lock = b"original lock bytes\n"
            (project_root / "Cargo.lock").write_bytes(original_lock)
            config = {
                "version": 1,
                "checks": [
                    {
                        "name": "serde-json-minimum",
                        "commands": ["test"],
                        "allFeatures": True,
                        "dependency": {
                            "name": "serde_json",
                            "resolution": "precise",
                            "version": "1.0.151",
                        },
                    }
                ],
            }
            (project_root / ".rs-ci-cargo-matrix.json").write_text(
                json.dumps(config),
                encoding="utf-8",
            )
            bin_dir, cargo_log = self.write_fake_cargo(
                project_root,
                resolved_version="1.0.151",
            )

            result = self.run_with_path(project_root, bin_dir, "run-all")
            commands = cargo_log.read_text(encoding="utf-8")

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("update -p serde_json --precise 1.0.151", commands)
            self.assertIn("metadata --locked --format-version 1", commands)
            self.assertIn("test --workspace --all-features --locked", commands)
            self.assertIn("cargo +1.94.0 test --all-features --locked", result.stdout)
            self.assertEqual(original_lock, (project_root / "Cargo.lock").read_bytes())

    def test_latest_dependency_uses_cargo_update_without_precise(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "Cargo.lock").write_text("original\n", encoding="utf-8")
            config = {
                "version": 1,
                "checks": [
                    {
                        "name": "serde-json-latest",
                        "commands": ["test"],
                        "dependency": {
                            "name": "serde_json",
                            "resolution": "latest",
                        },
                    }
                ],
            }
            (project_root / ".rs-ci-cargo-matrix.json").write_text(
                json.dumps(config),
                encoding="utf-8",
            )
            bin_dir, cargo_log = self.write_fake_cargo(
                project_root,
                resolved_version="1.0.200",
            )

            result = self.run_with_path(project_root, bin_dir, "run-index", "0")
            commands = cargo_log.read_text(encoding="utf-8")

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("update -p serde_json\n", commands)
            self.assertNotIn("update -p serde_json --precise", commands)
            self.assertIn("Resolved dependency serde_json 1.0.200", result.stdout)

    def test_precise_dependency_rejects_a_different_resolved_version(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "Cargo.lock").write_text("original\n", encoding="utf-8")
            config = {
                "version": 1,
                "checks": [
                    {
                        "name": "serde-json-minimum",
                        "commands": ["test"],
                        "dependency": {
                            "name": "serde_json",
                            "resolution": "precise",
                            "version": "1.0.151",
                        },
                    }
                ],
            }
            (project_root / ".rs-ci-cargo-matrix.json").write_text(
                json.dumps(config),
                encoding="utf-8",
            )
            bin_dir, _ = self.write_fake_cargo(
                project_root,
                resolved_version="1.0.152",
            )

            result = self.run_with_path(project_root, bin_dir, "run-all")

            self.assertNotEqual(0, result.returncode)
            self.assertIn("expected serde_json 1.0.151", result.stderr)

    def test_dependency_configuration_rejects_inconsistent_versions(self) -> None:
        invalid_dependencies = [
            {"name": "serde_json", "resolution": "precise"},
            {
                "name": "serde_json",
                "resolution": "latest",
                "version": "1.0.151",
            },
        ]
        for dependency in invalid_dependencies:
            with self.subTest(dependency=dependency):
                with tempfile.TemporaryDirectory() as temp_dir:
                    project_root = Path(temp_dir)
                    config = {
                        "version": 1,
                        "checks": [
                            {
                                "name": "invalid-dependency",
                                "commands": ["test"],
                                "dependency": dependency,
                            }
                        ],
                    }
                    (project_root / ".rs-ci-cargo-matrix.json").write_text(
                        json.dumps(config),
                        encoding="utf-8",
                    )

                    result = self.run_checker(project_root, "validate")

                self.assertNotEqual(0, result.returncode)

    def test_lockfile_is_restored_when_dependency_test_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            original_lock = b"dirty user lock\n"
            (project_root / "Cargo.lock").write_bytes(original_lock)
            config = {
                "version": 1,
                "checks": [
                    {
                        "name": "failing",
                        "commands": ["test"],
                        "dependency": {
                            "name": "serde_json",
                            "resolution": "latest",
                        },
                    }
                ],
            }
            (project_root / ".rs-ci-cargo-matrix.json").write_text(
                json.dumps(config),
                encoding="utf-8",
            )
            bin_dir, _ = self.write_fake_cargo(
                project_root,
                resolved_version="1.0.200",
                fail_test=True,
            )

            result = self.run_with_path(project_root, bin_dir, "run-all")

            self.assertNotEqual(0, result.returncode)
            self.assertEqual(original_lock, (project_root / "Cargo.lock").read_bytes())

    def test_each_matrix_entry_starts_from_the_original_lockfile(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "Cargo.lock").write_text("original\n", encoding="utf-8")
            config = {
                "version": 1,
                "checks": [
                    {
                        "name": "dependency",
                        "commands": ["test"],
                        "dependency": {
                            "name": "serde_json",
                            "resolution": "latest",
                        },
                    },
                    {
                        "name": "plain-feature-check",
                        "commands": ["test"],
                    },
                ],
            }
            (project_root / ".rs-ci-cargo-matrix.json").write_text(
                json.dumps(config),
                encoding="utf-8",
            )
            bin_dir = project_root / "bin"
            bin_dir.mkdir()
            cargo = bin_dir / "cargo"
            cargo.write_text(
                "#!/bin/sh\n"
                "set -eu\n"
                'case "$*" in\n'
                "  *\" update -p \"*) printf 'updated\\n' > Cargo.lock ;;\n"
                "  *\" metadata --locked --format-version 1\"*)\n"
                "    printf '%s\\n' '{\"packages\":[{\"name\":\"serde_json\",\"version\":\"1.0.200\"}]}'\n"
                "    ;;\n"
                "  *\" test \"*)\n"
                "    count=0\n"
                "    [ ! -f test-count ] || count=$(cat test-count)\n"
                "    count=$((count + 1))\n"
                "    printf '%s\\n' \"$count\" > test-count\n"
                "    if [ \"$count\" -eq 2 ] && [ \"$(cat Cargo.lock)\" != original ]; then exit 9; fi\n"
                "    ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            cargo.chmod(0o755)

            result = self.run_with_path(project_root, bin_dir, "run-all")

            self.assertEqual(0, result.returncode, result.stderr)


if __name__ == "__main__":
    unittest.main()
