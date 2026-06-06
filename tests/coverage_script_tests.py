#!/usr/bin/env python3
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
COVERAGE_SCRIPT = REPO_ROOT / "coverage.sh"


def write_project(root: Path) -> None:
    (root / "Cargo.toml").write_text(
        textwrap.dedent(
            """\
            [package]
            name = "qubit-demo"
            version = "1.2.3"
            edition = "2024"
            """
        ),
        encoding="utf-8",
    )


def write_fake_tools(bin_dir: Path, log_path: Path) -> None:
    cargo = bin_dir / "cargo"
    cargo.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            printf 'LLVM_COV=%s\\n' "${{LLVM_COV-<unset>}}" > "{log_path}"
            printf 'LLVM_PROFDATA=%s\\n' "${{LLVM_PROFDATA-<unset>}}" >> "{log_path}"
            printf 'ARGS=%s\\n' "$*" >> "{log_path}"
            exit 0
            """
        ),
        encoding="utf-8",
    )
    cargo.chmod(0o755)

    cargo_llvm_cov = bin_dir / "cargo-llvm-cov"
    cargo_llvm_cov.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    cargo_llvm_cov.chmod(0o755)


def run_coverage(root: Path, fake_bin: Path, env_overrides: dict[str, str]) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(env_overrides)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["RS_CI_PROJECT_ROOT"] = str(root)
    return subprocess.run(
        ["bash", str(COVERAGE_SCRIPT), "text"],
        cwd="/",
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


class CoverageScriptTests(unittest.TestCase):
    def test_ignores_invalid_llvm_tool_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            write_project(root)
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            log_path = Path(tmp) / "cargo.log"
            write_fake_tools(fake_bin, log_path)

            result = run_coverage(
                root,
                fake_bin,
                {
                    "LLVM_COV": str(Path(tmp) / "missing-llvm-cov"),
                    "LLVM_PROFDATA": str(Path(tmp) / "missing-llvm-profdata"),
                },
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("LLVM_COV=<unset>", log_path.read_text(encoding="utf-8"))
            self.assertIn("LLVM_PROFDATA=<unset>", log_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
