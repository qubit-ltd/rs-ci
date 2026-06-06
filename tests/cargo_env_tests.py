#!/usr/bin/env python3
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CARGO_ENV = REPO_ROOT / "cargo-env.sh"


def run_helper(project_root: Path, env_overrides: dict[str, str]) -> subprocess.CompletedProcess[str]:
    script = textwrap.dedent(
        f"""\
        set -euo pipefail
        source "{CARGO_ENV}"
        configure_rs_ci_cargo_home "{project_root}"
        printf 'CARGO_HOME=%s\\n' "${{CARGO_HOME-}}"
        printf 'RS_CI_ORIGINAL_CARGO_HOME=%s\\n' "${{RS_CI_ORIGINAL_CARGO_HOME-}}"
        printf 'PATH=%s\\n' "$PATH"
        if [ -d "${{CARGO_HOME-}}" ]; then
            printf 'CARGO_HOME_EXISTS=1\\n'
        else
            printf 'CARGO_HOME_EXISTS=0\\n'
        fi
        """
    )
    env = os.environ.copy()
    env.update(env_overrides)
    return subprocess.run(
        ["bash", "-c", script],
        cwd="/",
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


class CargoEnvTests(unittest.TestCase):
    def test_project_mode_uses_project_specific_cargo_home(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            temp_root = Path(tmp)
            project_root = temp_root / "work" / "rs-config"
            project_root.mkdir(parents=True)
            original_cargo_home = temp_root / "cargo"
            cargo_home_root = temp_root / "rs-ci-cargo-home"

            result = run_helper(
                project_root,
                {
                    "CARGO_HOME": str(original_cargo_home),
                    "PATH": "/usr/bin",
                    "RS_CI_CARGO_HOME_MODE": "project",
                    "RS_CI_CARGO_HOME_ROOT": str(cargo_home_root),
                },
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"CARGO_HOME={cargo_home_root / 'rs-config'}\n", result.stdout)
            self.assertIn(f"RS_CI_ORIGINAL_CARGO_HOME={original_cargo_home}\n", result.stdout)
            self.assertIn(f"PATH={original_cargo_home / 'bin'}:/usr/bin\n", result.stdout)
            self.assertIn("CARGO_HOME_EXISTS=1\n", result.stdout)

    def test_shared_mode_keeps_existing_cargo_home(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            temp_root = Path(tmp)
            project_root = temp_root / "work" / "rs-config"
            project_root.mkdir(parents=True)
            original_cargo_home = temp_root / "cargo"

            result = run_helper(
                project_root,
                {
                    "CARGO_HOME": str(original_cargo_home),
                    "PATH": "/usr/bin",
                    "RS_CI_CARGO_HOME_MODE": "shared",
                },
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"CARGO_HOME={original_cargo_home}\n", result.stdout)
            self.assertIn(f"RS_CI_ORIGINAL_CARGO_HOME={original_cargo_home}\n", result.stdout)
            self.assertIn("PATH=/usr/bin\n", result.stdout)


if __name__ == "__main__":
    unittest.main()
