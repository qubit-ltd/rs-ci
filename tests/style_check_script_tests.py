#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
STYLE_CHECK_SCRIPT = REPO_ROOT / "style-check.sh"


class StyleCheckScriptTests(unittest.TestCase):
    def run_source_test_pair_check(
        self,
        project_root: Path,
        override: str | None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "RS_CI_PROJECT_ROOT": str(project_root),
                "STYLE_ENFORCE_INLINE_TESTS": "0",
                "STYLE_ENFORCE_TEST_FILE_NAMES": "0",
                "STYLE_ENFORCE_TEST_REDIRECTS": "0",
                "STYLE_ENFORCE_PUBLIC_TYPE_FILES": "0",
                "STYLE_ENFORCE_EXPLICIT_IMPORTS": "0",
                "STYLE_ENFORCE_AGGREGATION_FILES": "0",
                "STYLE_ENFORCE_COVERAGE_CFG": "0",
            }
        )
        if override is None:
            environment.pop("STYLE_ENFORCE_SOURCE_TEST_PAIRS", None)
        else:
            environment["STYLE_ENFORCE_SOURCE_TEST_PAIRS"] = override
        return subprocess.run(
            ["bash", str(STYLE_CHECK_SCRIPT)],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def test_source_test_pairs_are_enabled_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "widget.rs").write_text(
                "pub struct Widget;\n",
                encoding="utf-8",
            )

            result = self.run_source_test_pair_check(project_root, None)

        self.assertEqual(1, result.returncode)
        self.assertIn("missing corresponding test file", result.stdout)

    def test_source_test_pairs_can_be_disabled_explicitly(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "widget.rs").write_text(
                "pub struct Widget;\n",
                encoding="utf-8",
            )

            result = self.run_source_test_pair_check(project_root, "0")

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
