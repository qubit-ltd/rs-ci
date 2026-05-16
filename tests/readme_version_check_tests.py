#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "readme-version-check.py"


def write_project(
    root: Path,
    *,
    package_name: str = "qubit-demo",
    package_version: str = "1.2.3",
    readme: str | None = None,
    readme_zh: str | None = None,
) -> None:
    (root / "Cargo.toml").write_text(
        textwrap.dedent(
            f"""\
            [package]
            name = "{package_name}"
            version = "{package_version}"
            edition = "2024"
            readme = "README.md"
            """
        ),
        encoding="utf-8",
    )
    if readme is not None:
        (root / "README.md").write_text(readme, encoding="utf-8")
    if readme_zh is not None:
        (root / "README.zh_CN.md").write_text(readme_zh, encoding="utf-8")


def run_checker(root: Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["RS_CI_PROJECT_ROOT"] = str(root)
    return subprocess.run(
        [sys.executable, str(CHECKER)],
        cwd=root,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


class ReadmeVersionCheckTests(unittest.TestCase):
    def test_accepts_minor_dependency_versions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_project(
                root,
                readme='qubit-demo = "1.2"\n',
                readme_zh='qubit-demo = "1.2"\n',
            )

            result = run_checker(root)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_inline_table_minor_dependency_versions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_project(
                root,
                readme='qubit-demo = { version = "1.2", features = ["std"] }\n',
                readme_zh='qubit-demo = { features = ["std"], version = "1.2" }\n',
            )

            result = run_checker(root)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_patch_dependency_versions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_project(
                root,
                readme='qubit-demo = "1.2.3"\n',
                readme_zh='qubit-demo = "1.2"\n',
            )

            result = run_checker(root)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn('expected "1.2"', result.stderr)
            self.assertIn('found "1.2.3"', result.stderr)

    def test_allows_readmes_without_dependency_declarations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_project(
                root,
                readme="No dependency snippet here.\n",
                readme_zh="No dependency snippet here.\n",
            )

            result = run_checker(root)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_allows_missing_chinese_readme(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_project(
                root,
                readme='qubit-demo = "1.2"\n',
                readme_zh=None,
            )

            result = run_checker(root)

            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
