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


def package_id(name: str, root: Path) -> str:
    return f"{name} 1.2.3 (path+file://{root})"


def package_metadata(
    name: str,
    manifest_path: Path,
) -> dict[str, object]:
    return {
        "id": package_id(name, manifest_path.parent),
        "name": name,
        "manifest_path": str(manifest_path),
        "metadata": {},
    }


def single_package_cargo_metadata(root: Path) -> dict[str, object]:
    package = package_metadata("qubit-demo", root / "Cargo.toml")
    package_id_value = str(package["id"])
    return {
        "packages": [package],
        "workspace_members": [package_id_value],
        "workspace_default_members": [package_id_value],
        "workspace_root": str(root),
        "target_directory": str(root / "target"),
    }


def coverage_file(path: Path, percent: float = 100) -> dict[str, object]:
    return {
        "filename": str(path),
        "summary": {
            "functions": {
                "count": 1,
                "covered": 1 if percent == 100 else 0,
                "percent": percent,
            },
            "lines": {
                "count": 1,
                "covered": 1 if percent == 100 else 0,
                "percent": percent,
            },
            "regions": {
                "count": 1,
                "covered": 1 if percent == 100 else 0,
                "percent": percent,
            },
        },
    }


def write_coverage_fixture(path: Path, files: list[dict[str, object]]) -> None:
    path.write_text(
        json.dumps({"data": [{"files": files}]}),
        encoding="utf-8",
    )


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
            if [ "${{1:-}}" = "metadata" ]; then
                cat "$FAKE_CARGO_METADATA"
                exit "${{FAKE_METADATA_STATUS:-0}}"
            fi
            printf 'LLVM_COV=%s\\n' "${{LLVM_COV-<unset>}}" >> "{log_path}"
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
    if "FAKE_CARGO_METADATA" not in env:
        metadata_path = root / ".fake-cargo-metadata.json"
        metadata_path.write_text(
            json.dumps(single_package_cargo_metadata(root)),
            encoding="utf-8",
        )
        env["FAKE_CARGO_METADATA"] = str(metadata_path)
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
            write_coverage_fixture(
                coverage_fixture,
                [coverage_file(root / "src" / "lib.rs")],
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


def write_workspace(root: Path) -> dict[str, object]:
    (root / "Cargo.toml").write_text(
        textwrap.dedent(
            """\
            [package]
            name = "qubit-workspace"
            version = "1.2.3"
            edition = "2024"

            [workspace]
            members = [".", "derive", "xtask"]
            default-members = [".", "derive"]
            """
        ),
        encoding="utf-8",
    )
    members = (
        ("qubit-workspace", root, "src", "lib.rs"),
        ("qubit-workspace-derive", root / "derive", "src", "lib.rs"),
        ("qubit-workspace-xtask", root / "xtask", "src", "main.rs"),
    )
    packages: list[dict[str, object]] = []
    for name, package_root, source_dir_name, source_file_name in members:
        package_root.mkdir(exist_ok=True)
        manifest = package_root / "Cargo.toml"
        if package_root != root:
            manifest.write_text(
                textwrap.dedent(
                    f"""\
                    [package]
                    name = "{name}"
                    version = "1.2.3"
                    edition = "2024"
                    """
                ),
                encoding="utf-8",
            )
        source_dir = package_root / source_dir_name
        source_dir.mkdir()
        (source_dir / source_file_name).write_text(
            "pub fn covered() {}\n",
            encoding="utf-8",
        )
        packages.append(package_metadata(name, manifest))

    package_ids = [str(package["id"]) for package in packages]
    return {
        "packages": packages,
        "workspace_members": package_ids,
        "workspace_default_members": package_ids[:2],
        "workspace_root": str(root),
        "target_directory": str(root / "target"),
    }


def cargo_commands(log_path: Path) -> list[str]:
    if not log_path.exists():
        return []
    return [
        line.removeprefix("ARGS=")
        for line in log_path.read_text(encoding="utf-8").splitlines()
        if line.startswith("ARGS=")
    ]


class WorkspaceCoverageScriptTests(unittest.TestCase):
    def create_fixture(
        self,
        tmp: str,
        *,
        include_xtask_coverage: bool = False,
    ) -> tuple[Path, Path, Path, Path, Path]:
        root = Path(tmp) / "project"
        root.mkdir()
        metadata = write_workspace(root)
        fake_bin = Path(tmp) / "bin"
        fake_bin.mkdir()
        log_path = Path(tmp) / "cargo.log"
        write_fake_tools(fake_bin, log_path)
        metadata_path = Path(tmp) / "metadata.json"
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        coverage_path = Path(tmp) / "coverage.json"
        files = [
            coverage_file(root / "src" / "lib.rs"),
            coverage_file(root / "derive" / "src" / "lib.rs"),
        ]
        if include_xtask_coverage:
            files.append(coverage_file(root / "xtask" / "src" / "main.rs"))
        write_coverage_fixture(coverage_path, files)
        return root, fake_bin, log_path, metadata_path, coverage_path

    @staticmethod
    def run_fixture(
        root: Path,
        fake_bin: Path,
        metadata_path: Path,
        coverage_path: Path,
        *,
        report_format: str = "json",
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = {
            "FAKE_CARGO_METADATA": str(metadata_path),
            "FAKE_COVERAGE_JSON": str(coverage_path),
        }
        if extra_env:
            env.update(extra_env)
        return run_coverage(
            root,
            fake_bin,
            env,
            report_format=report_format,
        )

    def test_default_members_scope_excludes_non_default_workspace_member(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root, fake_bin, log_path, metadata_path, coverage_path = (
                self.create_fixture(tmp)
            )

            result = self.run_fixture(
                root,
                fake_bin,
                metadata_path,
                coverage_path,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            commands = cargo_commands(log_path)
            self.assertTrue(commands)
            for command in commands:
                self.assertIn("--workspace", command)
                self.assertIn("--exclude qubit-workspace-xtask", command)
            self.assertIn("src/lib.rs", result.stdout)
            self.assertIn("derive/src/lib.rs", result.stdout)

    def test_workspace_scope_includes_every_member(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root, fake_bin, log_path, metadata_path, coverage_path = (
                self.create_fixture(tmp, include_xtask_coverage=True)
            )

            result = self.run_fixture(
                root,
                fake_bin,
                metadata_path,
                coverage_path,
                extra_env={"COVERAGE_SCOPE": "workspace"},
            )

            self.assertEqual(0, result.returncode, result.stderr)
            for command in cargo_commands(log_path):
                self.assertIn("--workspace", command)
                self.assertNotIn("--exclude", command)
            self.assertIn("xtask/src/main.rs", result.stdout)

    def test_package_scope_selects_root_package_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root, fake_bin, log_path, metadata_path, coverage_path = (
                self.create_fixture(tmp)
            )

            result = self.run_fixture(
                root,
                fake_bin,
                metadata_path,
                coverage_path,
                extra_env={"COVERAGE_SCOPE": "package"},
            )

            self.assertEqual(0, result.returncode, result.stderr)
            for command in cargo_commands(log_path):
                self.assertIn("--package qubit-workspace", command)
                self.assertNotIn("--workspace", command)
            self.assertIn("src/lib.rs", result.stdout)
            self.assertNotIn("derive/src/lib.rs", result.stdout)

    def test_package_scope_rejects_virtual_workspace_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            (root / "Cargo.toml").write_text(
                "[workspace]\nmembers = [\"member\"]\n",
                encoding="utf-8",
            )
            member = root / "member"
            member.mkdir()
            (member / "Cargo.toml").write_text(
                "[package]\nname = \"member\"\nversion = \"1.0.0\"\n",
                encoding="utf-8",
            )
            (member / "src").mkdir()
            (member / "src" / "lib.rs").write_text(
                "pub fn covered() {}\n",
                encoding="utf-8",
            )
            package = package_metadata("member", member / "Cargo.toml")
            metadata_path = Path(tmp) / "metadata.json"
            metadata_path.write_text(
                json.dumps(
                    {
                        "packages": [package],
                        "workspace_members": [package["id"]],
                        "workspace_default_members": [package["id"]],
                        "workspace_root": str(root),
                    }
                ),
                encoding="utf-8",
            )
            coverage_path = Path(tmp) / "coverage.json"
            write_coverage_fixture(
                coverage_path,
                [coverage_file(member / "src" / "lib.rs")],
            )
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            write_fake_tools(fake_bin, Path(tmp) / "cargo.log")

            result = self.run_fixture(
                root,
                fake_bin,
                metadata_path,
                coverage_path,
                extra_env={"COVERAGE_SCOPE": "package"},
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn("virtual workspace", result.stderr)

    def test_config_can_exclude_packages_and_add_source_roots(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root, fake_bin, log_path, metadata_path, coverage_path = (
                self.create_fixture(tmp)
            )
            generated = root / "derive" / "generated"
            generated.mkdir()
            generated_file = generated / "schema.rs"
            generated_file.write_text("pub fn generated() {}\n", encoding="utf-8")
            write_coverage_fixture(
                coverage_path,
                [
                    coverage_file(root / "src" / "lib.rs"),
                    coverage_file(root / "derive" / "src" / "lib.rs"),
                    coverage_file(generated_file),
                ],
            )
            (root / ".rs-ci-coverage.json").write_text(
                json.dumps(
                    {
                        "scope": "workspace",
                        "exclude_packages": ["qubit-workspace-xtask"],
                        "source_dirs": {
                            "qubit-workspace-derive": ["src", "generated"]
                        },
                    }
                ),
                encoding="utf-8",
            )

            result = self.run_fixture(
                root,
                fake_bin,
                metadata_path,
                coverage_path,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            for command in cargo_commands(log_path):
                self.assertIn("--workspace", command)
                self.assertIn("--exclude qubit-workspace-xtask", command)
            self.assertIn("derive/generated/schema.rs", result.stdout)

    def test_environment_scope_overrides_config_scope(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root, fake_bin, log_path, metadata_path, coverage_path = (
                self.create_fixture(tmp, include_xtask_coverage=True)
            )
            (root / ".rs-ci-coverage.json").write_text(
                json.dumps({"scope": "package"}),
                encoding="utf-8",
            )

            result = self.run_fixture(
                root,
                fake_bin,
                metadata_path,
                coverage_path,
                extra_env={"COVERAGE_SCOPE": "workspace"},
            )

            self.assertEqual(0, result.returncode, result.stderr)
            for command in cargo_commands(log_path):
                self.assertIn("--workspace", command)
                self.assertNotIn("--package qubit-workspace", command)

    def test_rejects_invalid_coverage_config(self) -> None:
        invalid_configs = (
            ({"scope": "members"}, "scope"),
            ({"exclude_packages": ["missing"]}, "missing"),
            ({"source_dirs": {"missing": ["src"]}}, "missing"),
            (
                {"source_dirs": {"qubit-workspace": ["/absolute"]}},
                "relative",
            ),
        )

        for config, expected in invalid_configs:
            with self.subTest(config=config):
                with tempfile.TemporaryDirectory() as tmp:
                    root, fake_bin, _, metadata_path, coverage_path = (
                        self.create_fixture(tmp)
                    )
                    (root / ".rs-ci-coverage.json").write_text(
                        json.dumps(config),
                        encoding="utf-8",
                    )

                    result = self.run_fixture(
                        root,
                        fake_bin,
                        metadata_path,
                        coverage_path,
                    )

                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(expected, result.stderr)

    def test_every_selected_source_root_must_match_coverage_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root, fake_bin, _, metadata_path, coverage_path = (
                self.create_fixture(tmp)
            )
            write_coverage_fixture(
                coverage_path,
                [coverage_file(root / "src" / "lib.rs")],
            )

            result = self.run_fixture(
                root,
                fake_bin,
                metadata_path,
                coverage_path,
                extra_env={"COVERAGE_ENFORCE_THRESHOLDS": "0"},
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn("derive/src", result.stderr)
            self.assertIn("matched no coverage files", result.stderr)

    def test_collection_and_report_commands_use_supported_scope_arguments(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root, fake_bin, log_path, metadata_path, coverage_path = (
                self.create_fixture(tmp)
            )

            result = self.run_fixture(
                root,
                fake_bin,
                metadata_path,
                coverage_path,
                report_format="all",
            )

            self.assertEqual(0, result.returncode, result.stderr)
            commands = cargo_commands(log_path)
            self.assertGreaterEqual(len(commands), 6)
            collection_commands = [
                command
                for command in commands
                if "llvm-cov report" not in command
            ]
            report_commands = [
                command
                for command in commands
                if "llvm-cov report" in command
            ]
            self.assertEqual(1, len(collection_commands))
            for command in collection_commands:
                self.assertIn("--workspace", command)
                self.assertIn("--exclude qubit-workspace-xtask", command)
            self.assertGreaterEqual(len(report_commands), 5)
            for command in report_commands:
                self.assertNotIn("--workspace", command)
                self.assertNotIn("--exclude", command)
                self.assertIn("--package qubit-workspace", command)
                self.assertIn("--package qubit-workspace-derive", command)
                self.assertNotIn("--package qubit-workspace-xtask", command)

    def test_reusable_workflow_exposes_coverage_threshold_input(self) -> None:
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "rust-ci.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("coverage_enforce_thresholds:", workflow)
        self.assertIn(
            "COVERAGE_ENFORCE_THRESHOLDS: "
            "${{ inputs.coverage_enforce_thresholds }}",
            workflow,
        )
        self.assertIn(
            "COVERAGE_OPEN_HTML=0 ./coverage.sh all",
            workflow,
        )
        self.assertNotIn(
            "COVERAGE_ENFORCE_THRESHOLDS=0 "
            "COVERAGE_OPEN_HTML=0 ./coverage.sh all",
            workflow,
        )


if __name__ == "__main__":
    unittest.main()
