#!/usr/bin/env python3
import json
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
    source_dir = root / "src"
    source_dir.mkdir()
    (source_dir / "lib.rs").write_text("pub fn covered() {}\n", encoding="utf-8")


def write_fake_tools(bin_dir: Path, log_path: Path) -> None:
    cargo = bin_dir / "cargo"
    cargo.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            printf 'LLVM_COV=%s\\n' "${{LLVM_COV-<unset>}}" > "{log_path}"
            printf 'LLVM_PROFDATA=%s\\n' "${{LLVM_PROFDATA-<unset>}}" >> "{log_path}"
            printf 'ARGS=%s\\n' "$*" >> "{log_path}"
            if [ -n "${{FAKE_COVERAGE_JSON:-}}" ]; then
                previous=""
                for argument in "$@"; do
                    if [ "$previous" = "--output-path" ]; then
                        command cp "$FAKE_COVERAGE_JSON" "$argument"
                        break
                    fi
                    previous="$argument"
                done
            fi
            exit 0
            """
        ),
        encoding="utf-8",
    )
    cargo.chmod(0o755)

    cargo_llvm_cov = bin_dir / "cargo-llvm-cov"
    cargo_llvm_cov.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    cargo_llvm_cov.chmod(0o755)


def run_coverage(
    root: Path,
    fake_bin: Path,
    env_overrides: dict[str, str],
    report_format: str = "text",
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(env_overrides)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["RS_CI_PROJECT_ROOT"] = str(root)
    return subprocess.run(
        ["bash", str(COVERAGE_SCRIPT), report_format],
        cwd="/",
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


class CoverageScriptTests(unittest.TestCase):
    def test_prints_summary_for_every_report_format(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            write_project(root)
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            log_path = Path(tmp) / "cargo.log"
            write_fake_tools(fake_bin, log_path)

            coverage_fixture = Path(tmp) / "coverage.json"
            coverage_fixture.write_text(
                json.dumps(
                    {
                        "data": [
                            {
                                "files": [
                                    {
                                        "filename": str(root / "src" / "lib.rs"),
                                        "summary": {
                                            "functions": {
                                                "count": 1,
                                                "covered": 1,
                                                "percent": 100,
                                            },
                                            "lines": {
                                                "count": 1,
                                                "covered": 1,
                                                "percent": 100,
                                            },
                                            "regions": {
                                                "count": 1,
                                                "covered": 1,
                                                "percent": 100,
                                            },
                                        },
                                    }
                                ]
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            for report_format in ("html", "text", "lcov", "json", "cobertura", "all"):
                with self.subTest(report_format=report_format):
                    result = run_coverage(
                        root,
                        fake_bin,
                        {"FAKE_COVERAGE_JSON": str(coverage_fixture)},
                        report_format=report_format,
                    )

                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("Coverage summary:", result.stdout)
                    self.assertIn("lib.rs", result.stdout)

    def test_ignores_invalid_llvm_tool_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            write_project(root)
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            log_path = Path(tmp) / "cargo.log"
            write_fake_tools(fake_bin, log_path)

            coverage_fixture = Path(tmp) / "coverage.json"
            coverage_fixture.write_text(
                json.dumps({"data": [{"files": []}]}),
                encoding="utf-8",
            )

            result = run_coverage(
                root,
                fake_bin,
                {
                    "LLVM_COV": str(Path(tmp) / "missing-llvm-cov"),
                    "LLVM_PROFDATA": str(Path(tmp) / "missing-llvm-profdata"),
                    "FAKE_COVERAGE_JSON": str(coverage_fixture),
                },
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("LLVM_COV=<unset>", log_path.read_text(encoding="utf-8"))
            self.assertIn("LLVM_PROFDATA=<unset>", log_path.read_text(encoding="utf-8"))

    def test_rejects_summary_threshold_failure_without_zero_count_segment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            write_project(root)
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            log_path = Path(tmp) / "cargo.log"
            write_fake_tools(fake_bin, log_path)

            coverage_fixture = Path(tmp) / "coverage.json"
            coverage_fixture.write_text(
                json.dumps(
                    {
                        "data": [
                            {
                                "files": [
                                    {
                                        "filename": str(root / "src" / "lib.rs"),
                                        "segments": [
                                            [1, 1, 1, True, True, False],
                                            [2, 1, 1, False, False, False],
                                        ],
                                        "summary": {
                                            "functions": {
                                                "count": 1,
                                                "covered": 1,
                                                "percent": 100,
                                            },
                                            "lines": {
                                                "count": 1,
                                                "covered": 1,
                                                "percent": 100,
                                            },
                                            "regions": {
                                                "count": 2,
                                                "covered": 1,
                                                "percent": 50,
                                            },
                                        },
                                    }
                                ]
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            result = run_coverage(
                root,
                fake_bin,
                {
                    "FAKE_COVERAGE_JSON": str(coverage_fixture),
                    "MIN_REGION_COVERAGE": "95",
                },
                report_format="json",
            )

            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(
                "per-source coverage thresholds failed",
                result.stderr,
            )


if __name__ == "__main__":
    unittest.main()
