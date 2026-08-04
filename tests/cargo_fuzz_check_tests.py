#!/usr/bin/env python3
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "cargo-fuzz-check.sh"


def write_fuzz_manifest(project_root: Path, marker: bool = True) -> None:
    fuzz_dir = project_root / "fuzz"
    fuzz_dir.mkdir()
    metadata = "cargo-fuzz = true" if marker else "enabled = true"
    (fuzz_dir / "Cargo.toml").write_text(
        textwrap.dedent(
            f"""\
            [package]
            name = "example-fuzz"
            version = "0.0.0"

            [package.metadata]
            {metadata}
            """
        ),
        encoding="utf-8",
    )


def write_fake_cargo(bin_dir: Path, log_path: Path) -> None:
    cargo = bin_dir / "cargo"
    cargo.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            printf '%s\\n' "$*" >> "{log_path}"
            if [ "$2" = "fuzz" ] && [ "$3" = "list" ]; then
                printf '%s\\n' "${{FAKE_FUZZ_TARGETS-}}"
                exit "${{FAKE_LIST_EXIT:-0}}"
            fi
            if [ "$2" = "fuzz" ] && [ "$3" = "build" ]; then
                exit "${{FAKE_BUILD_EXIT:-0}}"
            fi
            if [ "$2" = "fuzz" ] && [ "$3" = "run" ]; then
                exit "${{FAKE_RUN_EXIT:-0}}"
            fi
            exit 0
            """
        ),
        encoding="utf-8",
    )
    cargo.chmod(0o755)


def write_fake_cargo_fuzz(bin_dir: Path) -> None:
    cargo_fuzz = bin_dir / "cargo-fuzz"
    cargo_fuzz.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    cargo_fuzz.chmod(0o755)


class CargoFuzzCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.project_root = self.root / "project"
        self.project_root.mkdir()
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.tmp_dir = self.root / "temporary-corpora"
        self.tmp_dir.mkdir()
        self.log_path = self.root / "cargo.log"
        write_fake_cargo(self.bin_dir, self.log_path)
        write_fake_cargo_fuzz(self.bin_dir)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_checker(
        self,
        *,
        targets: str = "",
        mode: str = "smoke",
        duration: str = "3",
        max_len: str = "4096",
        include_cargo_fuzz: bool = True,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        if not include_cargo_fuzz:
            (self.bin_dir / "cargo-fuzz").unlink(missing_ok=True)
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}/usr/bin{os.pathsep}/bin",
                "RS_CI_PROJECT_ROOT": str(self.project_root),
                "RS_CI_FUZZ_MODE": mode,
                "RS_CI_FUZZ_TOOLCHAIN": "nightly-2099-01-01",
                "RS_CI_FUZZ_SECONDS_PER_TARGET": duration,
                "RS_CI_FUZZ_MAX_LEN": max_len,
                "FAKE_FUZZ_TARGETS": targets,
                "TMPDIR": str(self.tmp_dir),
            }
        )
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", str(CHECKER)],
            cwd="/",
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def command_log(self) -> str:
        return self.log_path.read_text(encoding="utf-8")

    def run_detection(self) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}{env['PATH']}",
                "RS_CI_PROJECT_ROOT": str(self.project_root),
            }
        )
        return subprocess.run(
            ["bash", str(CHECKER), "--is-configured"],
            cwd="/",
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_skips_project_without_fuzz_manifest(self) -> None:
        result = self.run_checker()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("cargo-fuzz is not configured", result.stdout)
        self.assertFalse(self.log_path.exists())

    def test_detection_returns_nonzero_without_fuzz_manifest(self) -> None:
        result = self.run_detection()

        self.assertNotEqual(0, result.returncode)
        self.assertFalse(self.log_path.exists())

    def test_detection_returns_zero_for_enabled_project(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_detection()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(self.log_path.exists())

    def test_skips_manifest_without_cargo_fuzz_marker(self) -> None:
        write_fuzz_manifest(self.project_root, marker=False)

        result = self.run_checker()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("cargo-fuzz is not configured", result.stdout)
        self.assertFalse(self.log_path.exists())

    def test_disabled_mode_skips_enabled_project_without_tool(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker(mode="disabled", include_cargo_fuzz=False)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("cargo-fuzz checks are disabled", result.stdout)
        self.assertFalse(self.log_path.exists())

    def test_smoke_builds_and_runs_each_target(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker(targets="alpha\nbeta\n")

        self.assertEqual(0, result.returncode, result.stderr)
        log = self.command_log()
        self.assertIn("+nightly-2099-01-01 fuzz list", log)
        self.assertIn("+nightly-2099-01-01 fuzz build alpha", log)
        self.assertIn("+nightly-2099-01-01 fuzz build beta", log)
        self.assertIn("+nightly-2099-01-01 fuzz run alpha", log)
        self.assertIn("+nightly-2099-01-01 fuzz run beta", log)
        self.assertEqual(2, log.count("-max_total_time=3"))
        self.assertEqual(2, log.count("-max_len=4096"))
        self.assertEqual([], list(self.tmp_dir.iterdir()))

    def test_smoke_uses_configured_max_input_length(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker(targets="alpha\n", max_len="16384")

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("-max_len=16384", self.command_log())

    def test_build_only_does_not_run_targets(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker(targets="alpha\n", mode="build-only")

        self.assertEqual(0, result.returncode, result.stderr)
        log = self.command_log()
        self.assertIn("+nightly-2099-01-01 fuzz build alpha", log)
        self.assertNotIn("fuzz run", log)

    def test_enabled_project_requires_cargo_fuzz_executable(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker(include_cargo_fuzz=False)

        self.assertNotEqual(0, result.returncode)
        self.assertIn("cargo install cargo-fuzz", result.stderr)

    def test_rejects_unknown_mode(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker(mode="continuous")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("RS_CI_FUZZ_MODE", result.stderr)

    def test_rejects_non_positive_duration(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker(duration="0")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("RS_CI_FUZZ_SECONDS_PER_TARGET", result.stderr)

    def test_rejects_non_positive_max_input_length(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker(max_len="0")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("RS_CI_FUZZ_MAX_LEN", result.stderr)

    def test_rejects_enabled_project_without_targets(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker()

        self.assertNotEqual(0, result.returncode)
        self.assertIn("no fuzz targets", result.stderr)

    def test_propagates_target_build_failure(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker(
            targets="alpha\n",
            extra_env={"FAKE_BUILD_EXIT": "17"},
        )

        self.assertEqual(17, result.returncode)
        self.assertIn("+nightly-2099-01-01 fuzz build alpha", self.command_log())

    def test_propagates_target_run_failure(self) -> None:
        write_fuzz_manifest(self.project_root)

        result = self.run_checker(
            targets="alpha\n",
            extra_env={"FAKE_RUN_EXIT": "19"},
        )

        self.assertEqual(19, result.returncode)
        self.assertIn("+nightly-2099-01-01 fuzz run alpha", self.command_log())

    def test_uses_committed_seed_corpus_without_retaining_temporary_corpus(self) -> None:
        write_fuzz_manifest(self.project_root)
        seed_corpus = self.project_root / "fuzz" / "corpus" / "alpha"
        seed_corpus.mkdir(parents=True)
        (seed_corpus / "seed.json").write_text("{}", encoding="utf-8")

        result = self.run_checker(targets="alpha\n")

        self.assertEqual(0, result.returncode, result.stderr)
        run_command = next(
            line for line in self.command_log().splitlines() if "fuzz run alpha" in line
        )
        self.assertIn(str(seed_corpus), run_command)
        self.assertIn(str(self.tmp_dir), run_command)
        self.assertEqual([], list(self.tmp_dir.iterdir()))


if __name__ == "__main__":
    unittest.main()
