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
                "STYLE_SOURCE_DIR": "src",
                "STYLE_TEST_DIR": "tests",
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

    def run_style_check(
        self,
        project_root: Path,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["RS_CI_PROJECT_ROOT"] = str(project_root)
        for variable in (
            "STYLE_SOURCE_DIR",
            "STYLE_TEST_DIR",
            "STYLE_ENFORCE_INLINE_TESTS",
            "STYLE_ENFORCE_TEST_FILE_NAMES",
            "STYLE_ENFORCE_TEST_REDIRECTS",
            "STYLE_ENFORCE_SOURCE_TEST_PAIRS",
            "STYLE_ENFORCE_PUBLIC_TYPE_FILES",
            "STYLE_ENFORCE_EXPLICIT_IMPORTS",
            "STYLE_ENFORCE_AGGREGATION_FILES",
            "STYLE_ENFORCE_COVERAGE_CFG",
        ):
            environment.pop(variable, None)
        return subprocess.run(
            ["bash", str(STYLE_CHECK_SCRIPT)],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def run_import_style_check(
        self,
        project_root: Path,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "RS_CI_PROJECT_ROOT": str(project_root),
                "STYLE_SOURCE_DIR": "src",
                "STYLE_TEST_DIR": "tests",
                "STYLE_ENFORCE_INLINE_TESTS": "0",
                "STYLE_ENFORCE_TEST_FILE_NAMES": "0",
                "STYLE_ENFORCE_TEST_REDIRECTS": "0",
                "STYLE_ENFORCE_SOURCE_TEST_PAIRS": "0",
                "STYLE_ENFORCE_PUBLIC_TYPE_FILES": "0",
                "STYLE_ENFORCE_AGGREGATION_FILES": "0",
                "STYLE_ENFORCE_COVERAGE_CFG": "0",
                "STYLE_ENFORCE_EXPLICIT_IMPORTS": "1",
            }
        )
        return subprocess.run(
            ["bash", str(STYLE_CHECK_SCRIPT)],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def run_aggregation_style_check(
        self,
        project_root: Path,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "RS_CI_PROJECT_ROOT": str(project_root),
                "STYLE_SOURCE_DIR": "src",
                "STYLE_TEST_DIR": "tests",
                "STYLE_ENFORCE_INLINE_TESTS": "0",
                "STYLE_ENFORCE_TEST_FILE_NAMES": "0",
                "STYLE_ENFORCE_TEST_REDIRECTS": "0",
                "STYLE_ENFORCE_SOURCE_TEST_PAIRS": "0",
                "STYLE_ENFORCE_PUBLIC_TYPE_FILES": "0",
                "STYLE_ENFORCE_AGGREGATION_FILES": "1",
                "STYLE_ENFORCE_COVERAGE_CFG": "0",
                "STYLE_ENFORCE_EXPLICIT_IMPORTS": "0",
            }
        )
        return subprocess.run(
            ["bash", str(STYLE_CHECK_SCRIPT)],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def test_import_style_rules_reject_invalid_imports(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "lib.rs").write_text(
                "#[allow(unused_imports)]\n"
                "use serde::{Deserialize, Serialize};\n"
                "use qubit_types::EntityId;\n"
                "use std::time::Duration;\n"
                "use crate::model::App;\n"
                "\n"
                "pub struct Widget {\n"
                "    /// The entity information.\n"
                "    pub info: Option<qubit_mixin::InfoWithEntity>,\n"
                "}\n",
                encoding="utf-8",
            )

            result = self.run_import_style_check(project_root)

        self.assertEqual(1, result.returncode)
        self.assertIn("unused_imports", result.stdout)
        self.assertIn("brace lists", result.stdout)
        self.assertIn("standard-library imports must precede external imports", result.stdout)
        self.assertIn("fully qualified external crate path", result.stdout)

    def test_import_style_rules_accept_canonical_imports(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "lib.rs").write_text(
                "use std::time::Duration;\n"
                "\n"
                "use chrono::DateTime;\n"
                "use qubit_types::EntityId;\n"
                "use serde::Deserialize;\n"
                "\n"
                "use self::internal::Helper;\n"
                "use super::Category;\n"
                "use crate::model::App;\n"
                "\n"
                "pub mod nested {\n"
                "    pub use super::atomic_bool::AtomicBool;\n"
                "    pub use super::atomic_f32::AtomicF32;\n"
                "}\n",
                encoding="utf-8",
            )

            result = self.run_import_style_check(project_root)

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_import_style_rules_accept_rustfmt_2024_version_ordering(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "lib.rs").write_text(
                "use super::atomic_i8;\n"
                "use super::atomic_i16;\n"
                "use super::atomic_i32;\n"
                "use super::atomic_i64;\n"
                "use super::atomic_i128;\n",
                encoding="utf-8",
            )

            result = self.run_import_style_check(project_root)

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_rustdoc_rule_rejects_attributes_after_docs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "lib.rs").write_text(
                "#[derive(Debug)]\n"
                "/// Represents a widget.\n"
                "pub struct Widget {\n"
                "    /// The first value.\n"
                "    pub first: String,\n"
                "    /// The second value.\n"
                "    pub second: String,\n"
                "}\n",
                encoding="utf-8",
            )

            result = self.run_import_style_check(project_root)

        self.assertEqual(1, result.returncode)
        self.assertIn("Rustdoc comments must precede attributes", result.stdout)
        self.assertNotIn("struct fields must be separated by blank lines", result.stdout)

    def test_rustdoc_rule_accepts_canonical_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "lib.rs").write_text(
                "/// Represents a widget.\n"
                "#[derive(Debug)]\n"
                "pub struct Widget {\n"
                "    /// The first value.\n"
                "    pub first: String,\n"
                "\n"
                "    /// The second value.\n"
                "    pub second: String,\n"
                "}\n",
                encoding="utf-8",
            )

            result = self.run_import_style_check(project_root)

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_source_test_pairs_are_disabled_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "widget.rs").write_text(
                "pub struct Widget;\n",
                encoding="utf-8",
            )

            result = self.run_source_test_pair_check(project_root, None)

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_source_test_pairs_can_be_enabled_explicitly(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "widget.rs").write_text(
                "pub struct Widget;\n",
                encoding="utf-8",
            )

            result = self.run_source_test_pair_check(project_root, "1")

        self.assertEqual(1, result.returncode)
        self.assertIn("missing corresponding test file", result.stdout)

    def test_internal_and_inline_tests_are_allowed_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src" / "tests").mkdir(parents=True)
            (project_root / "tests").mkdir()
            (project_root / "Cargo.toml").write_text(
                '[package]\nname = "tiered-tests"\nversion = "0.1.0"\n'
                'edition = "2024"\n',
                encoding="utf-8",
            )
            (project_root / "src" / "lib.rs").write_text(
                "#[cfg(test)]\nmod tests;\n\n"
                "#[cfg(test)]\nmod private_tests {\n"
                "    #[test]\n    fn test_private_contract() {}\n}\n",
                encoding="utf-8",
            )
            (project_root / "src" / "tests" / "mod.rs").write_text(
                "mod widget_tests;\n",
                encoding="utf-8",
            )
            (project_root / "src" / "tests" / "widget_tests.rs").write_text(
                "pub struct FirstHelper;\n"
                "pub struct SecondHelper;\n\n"
                "#[test]\nfn test_crate_contract() {}\n",
                encoding="utf-8",
            )

            result = self.run_style_check(project_root)

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_internal_tests_must_be_cfg_test_gated(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src" / "tests").mkdir(parents=True)
            (project_root / "tests").mkdir()
            (project_root / "Cargo.toml").write_text(
                '[package]\nname = "ungated-tests"\nversion = "0.1.0"\n'
                'edition = "2024"\n',
                encoding="utf-8",
            )
            (project_root / "src" / "lib.rs").write_text(
                "pub mod tests;\n",
                encoding="utf-8",
            )
            (project_root / "src" / "tests" / "mod.rs").write_text(
                "pub struct FirstProductionType;\n"
                "pub struct SecondProductionType;\n",
                encoding="utf-8",
            )

            result = self.run_style_check(project_root)

        self.assertEqual(1, result.returncode)
        self.assertIn(
            "src/tests must be connected from the crate root with "
            "#[cfg(test)] mod tests;",
            result.stdout,
        )

    def test_aggregation_rule_does_not_treat_cfg_not_test_as_test_code(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "lib.rs").write_text(
                "#[cfg(not(test))]\nmod production {\n"
                "    pub fn production_function() {}\n}\n",
                encoding="utf-8",
            )

            result = self.run_aggregation_style_check(project_root)

        self.assertEqual(1, result.returncode)
        self.assertIn("production_function", result.stdout)

    def test_inline_test_string_braces_do_not_hide_production_items(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "lib.rs").write_text(
                "#[cfg(test)]\nmod private_tests {\n"
                "    #[test]\n    fn test_brace_input() {\n"
                '        assert_eq!("{", "{");\n'
                "    }\n}\n\n"
                "pub fn production_function() {}\n",
                encoding="utf-8",
            )

            result = self.run_aggregation_style_check(project_root)

        self.assertEqual(1, result.returncode)
        self.assertIn("production_function", result.stdout)

    def test_workspace_default_members_are_checked(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "first" / "src").mkdir(parents=True)
            (project_root / "member" / "src").mkdir(parents=True)
            (project_root / "member" / "tests").mkdir()
            (project_root / "Cargo.toml").write_text(
                '[workspace]\nmembers = ["first", "member"]\nresolver = "3"\n',
                encoding="utf-8",
            )
            (project_root / "first" / "Cargo.toml").write_text(
                '[package]\nname = "first"\nversion = "0.1.0"\nedition = "2024"\n',
                encoding="utf-8",
            )
            (project_root / "first" / "src" / "lib.rs").write_text(
                "",
                encoding="utf-8",
            )
            (project_root / "member" / "Cargo.toml").write_text(
                '[package]\nname = "member"\nversion = "0.1.0"\nedition = "2024"\n',
                encoding="utf-8",
            )
            (project_root / "member" / "src" / "lib.rs").write_text(
                "mod misnamed;\n",
                encoding="utf-8",
            )
            (project_root / "member" / "src" / "misnamed.rs").write_text(
                "pub struct Widget;\n",
                encoding="utf-8",
            )

            result = self.run_style_check(project_root)

        self.assertEqual(1, result.returncode)
        self.assertIn("member/src/misnamed.rs", result.stdout)

    def test_parent_module_test_covers_internal_source_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src" / "parser" / "internal").mkdir(parents=True)
            (project_root / "tests").mkdir()
            (project_root / "src" / "parser.rs").write_text(
                "mod internal;\n",
                encoding="utf-8",
            )
            (project_root / "src" / "parser" / "internal" / "token.rs").write_text(
                "pub struct Token;\n",
                encoding="utf-8",
            )
            (project_root / "tests" / "parser_tests.rs").write_text(
                "#[test]\nfn test_parser() {}\n",
                encoding="utf-8",
            )

            result = self.run_source_test_pair_check(project_root, "1")

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_include_redirect_is_allowed_when_file_has_direct_tests(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "tests" / "widget_tests.rs").write_text(
                'include!("shared.rs");\n\n#[test]\nfn test_widget() {}\n',
                encoding="utf-8",
            )

            environment = os.environ.copy()
            environment.update(
                {
                    "RS_CI_PROJECT_ROOT": str(project_root),
                    "STYLE_SOURCE_DIR": "src",
                    "STYLE_TEST_DIR": "tests",
                    "STYLE_ENFORCE_INLINE_TESTS": "0",
                    "STYLE_ENFORCE_TEST_FILE_NAMES": "0",
                    "STYLE_ENFORCE_SOURCE_TEST_PAIRS": "0",
                    "STYLE_ENFORCE_PUBLIC_TYPE_FILES": "0",
                    "STYLE_ENFORCE_EXPLICIT_IMPORTS": "0",
                    "STYLE_ENFORCE_AGGREGATION_FILES": "0",
                    "STYLE_ENFORCE_COVERAGE_CFG": "0",
                }
            )
            result = subprocess.run(
                ["bash", str(STYLE_CHECK_SCRIPT)],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_proc_macro_entrypoints_are_allowed_in_lib_rs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "src").mkdir()
            (project_root / "tests").mkdir()
            (project_root / "src" / "lib.rs").write_text(
                "#[proc_macro_derive(Example)]\n"
                "#[inline]\n"
                "pub fn derive_example() {}\n",
                encoding="utf-8",
            )

            environment = os.environ.copy()
            environment.update(
                {
                    "RS_CI_PROJECT_ROOT": str(project_root),
                    "STYLE_SOURCE_DIR": "src",
                    "STYLE_TEST_DIR": "tests",
                    "STYLE_ENFORCE_INLINE_TESTS": "0",
                    "STYLE_ENFORCE_TEST_FILE_NAMES": "0",
                    "STYLE_ENFORCE_TEST_REDIRECTS": "0",
                    "STYLE_ENFORCE_SOURCE_TEST_PAIRS": "0",
                    "STYLE_ENFORCE_PUBLIC_TYPE_FILES": "0",
                    "STYLE_ENFORCE_EXPLICIT_IMPORTS": "0",
                    "STYLE_ENFORCE_COVERAGE_CFG": "0",
                }
            )
            result = subprocess.run(
                ["bash", str(STYLE_CHECK_SCRIPT)],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
