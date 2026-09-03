#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RUNNER = REPO_ROOT / "run-project-ci-check.sh"


class ProjectCiCheckTests(unittest.TestCase):
    def run_checker(
        self,
        project_root: Path,
        *,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        process_env = os.environ.copy()
        process_env.update(env or {})
        process_env["RS_CI_PROJECT_ROOT"] = str(project_root)
        return subprocess.run(
            [str(RUNNER)],
            cwd=REPO_ROOT,
            env=process_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_missing_project_hook_is_a_no_op(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_checker(Path(temp_dir))

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("No project-specific CI hook found", result.stdout)

    def test_executable_project_hook_runs_from_project_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            hook = project_root / "project-ci-check.sh"
            output = project_root / "hook-output.txt"
            hook.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n%s\\n' \"$PWD\" \"$RS_CI_BUILD_TOOLCHAIN\" "
                "> hook-output.txt\n",
                encoding="utf-8",
            )
            hook.chmod(0o755)

            result = self.run_checker(
                project_root,
                env={"RS_CI_BUILD_TOOLCHAIN": "1.94.0"},
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(
                [str(project_root), "1.94.0"],
                output.read_text(encoding="utf-8").splitlines(),
            )

    def test_non_executable_project_hook_fails_loudly(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            hook = project_root / "project-ci-check.sh"
            hook.write_text("#!/bin/bash\n", encoding="utf-8")
            hook.chmod(0o644)

            result = self.run_checker(project_root)

        self.assertNotEqual(0, result.returncode)
        self.assertIn("is not executable", result.stderr)


if __name__ == "__main__":
    unittest.main()

