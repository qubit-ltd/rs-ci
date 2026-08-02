#!/usr/bin/env python3
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
LOCK_UPDATE = REPO_ROOT / "cargo-lock-update.sh"


class CargoLockUpdateTests(unittest.TestCase):
    def run_helper(
        self,
        *,
        auxiliary_manifests: str = "",
        mode: str = "--update",
    ) -> tuple[subprocess.CompletedProcess[str], list[str], Path]:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "Cargo.toml").write_text("[package]\nname = \"root\"\n", encoding="utf-8")
            (root / "Cargo.lock").write_text("root lock\n", encoding="utf-8")
            for directory in ("fuzz", "loom"):
                manifest_dir = root / directory
                manifest_dir.mkdir()
                (manifest_dir / "Cargo.toml").write_text(
                    f"[package]\nname = \"{directory}\"\n",
                    encoding="utf-8",
                )
                (manifest_dir / "Cargo.lock").write_text(
                    f"{directory} lock\n",
                    encoding="utf-8",
                )
            for manifest in auxiliary_manifests.splitlines():
                if manifest:
                    manifest_path = root / manifest
                    manifest_path.parent.mkdir(parents=True, exist_ok=True)
                    manifest_path.write_text(
                        "[package]\nname = \"helper\"\n",
                        encoding="utf-8",
                    )
                    (manifest_path.parent / "Cargo.lock").write_text(
                        "helper lock\n",
                        encoding="utf-8",
                    )

            bin_dir = root / "bin"
            bin_dir.mkdir()
            cargo_log = root / "cargo.log"
            fake_cargo = bin_dir / "cargo"
            fake_cargo.write_text(
                textwrap.dedent(
                    f"""\
                    #!/bin/sh
                    printf '%s\\n' "$*" >> "{cargo_log}"
                    if [ "$1" = "+1.94.0" ]; then
                        shift
                    fi
                    if [ "$1" = "metadata" ]; then
                        manifest=""
                        while [ "$#" -gt 0 ]; do
                            if [ "$1" = "--manifest-path" ]; then
                                shift
                                manifest="$1"
                            fi
                            shift
                        done
                        [ -f "$manifest.rs-ci-generated" ] || exit 1
                        exit 0
                    fi
                    if [ "$1" = "generate-lockfile" ]; then
                        manifest=""
                        while [ "$#" -gt 0 ]; do
                            if [ "$1" = "--manifest-path" ]; then
                                shift
                                manifest="$1"
                            fi
                            shift
                        done
                        : > "$manifest.rs-ci-generated"
                        exit 0
                    fi
                    exit 99
                    """
                ),
                encoding="utf-8",
            )
            fake_cargo.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["RS_CI_PROJECT_ROOT"] = str(root)
            env["RS_CI_BUILD_TOOLCHAIN"] = "1.94.0"
            if auxiliary_manifests:
                env["RS_CI_AUXILIARY_MANIFESTS"] = auxiliary_manifests
            else:
                env.pop("RS_CI_AUXILIARY_MANIFESTS", None)
            result = subprocess.run(
                [str(LOCK_UPDATE), mode],
                text=True,
                capture_output=True,
                env=env,
                check=False,
            )
            commands = (
                cargo_log.read_text(encoding="utf-8").splitlines()
                if cargo_log.exists()
                else []
            )
            # Return a copy before TemporaryDirectory removes the fixture.
            return result, commands, root

    def test_update_covers_root_fuzz_loom_and_declared_helpers(self) -> None:
        result, commands, _ = self.run_helper(
            auxiliary_manifests="tools/helper/Cargo.toml\n",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(12, len(commands), commands)
        self.assertEqual(8, sum("metadata" in command and "--locked" in command for command in commands))
        self.assertEqual(4, sum("generate-lockfile" in command for command in commands))

    def test_check_mode_reports_stale_manifest_without_updating(self) -> None:
        result, commands, _ = self.run_helper(
            mode="--check",
        )

        self.assertNotEqual(0, result.returncode)
        self.assertTrue(all("generate-lockfile" not in command for command in commands))


if __name__ == "__main__":
    unittest.main()
