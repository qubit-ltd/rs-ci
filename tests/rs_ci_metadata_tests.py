#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
METADATA_SCRIPT = REPO_ROOT / "rs-ci-metadata.sh"


def package(
    root: Path,
    name: str,
    package_id: str,
    rs_ci: object | None = None,
) -> dict[str, object]:
    metadata = None if rs_ci is None else {"rs-ci": rs_ci}
    return {
        "id": package_id,
        "name": name,
        "manifest_path": str(root / name / "Cargo.toml"),
        "metadata": metadata,
    }


class RsCiMetadataTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name) / "project"
        self.root.mkdir()
        (self.root / "Cargo.toml").write_text(
            "[workspace]\nmembers = []\n",
            encoding="utf-8",
        )
        self.bin_dir = Path(self.temp_dir.name) / "bin"
        self.bin_dir.mkdir()
        self.metadata_file = Path(self.temp_dir.name) / "metadata.json"
        cargo = self.bin_dir / "cargo"
        cargo.write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                if [ "${1:-}" = "metadata" ]; then
                    cat "$FAKE_CARGO_METADATA"
                    exit "${FAKE_METADATA_STATUS:-0}"
                fi
                exit 91
                """
            ),
            encoding="utf-8",
        )
        cargo.chmod(0o755)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_metadata(
        self,
        command: str,
        *arguments: str,
        metadata: dict[str, object],
    ) -> subprocess.CompletedProcess[str]:
        self.metadata_file.write_text(
            json.dumps(metadata),
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env['PATH']}"
        env["FAKE_CARGO_METADATA"] = str(self.metadata_file)
        env["RS_CI_PROJECT_ROOT"] = str(self.root)
        return subprocess.run(
            ["bash", str(METADATA_SCRIPT), command, *arguments],
            cwd="/",
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    @staticmethod
    def metadata(
        packages: list[dict[str, object]],
        members: list[str],
    ) -> dict[str, object]:
        return {
            "packages": packages,
            "workspace_members": members,
            "workspace_default_members": members,
            "workspace_root": "/workspace",
        }

    def test_lists_only_workspace_packages_with_miri_enabled(self) -> None:
        root_id = "root 0.1.0 (path+file:///root)"
        member_id = "member 0.1.0 (path+file:///member)"
        dependency_id = "dependency 1.0.0 (registry+example)"
        result = self.run_metadata(
            "miri-packages",
            metadata=self.metadata(
                [
                    package(self.root, "root", root_id, {"miri": False}),
                    package(self.root, "member", member_id, {"miri": True}),
                    package(
                        self.root,
                        "dependency",
                        dependency_id,
                        {"miri": True},
                    ),
                ],
                [root_id, member_id],
            ),
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["member"], result.stdout.splitlines())

    def test_absent_metadata_produces_empty_lists(self) -> None:
        package_id = "demo 0.1.0 (path+file:///demo)"
        metadata = self.metadata(
            [package(self.root, "demo", package_id)],
            [package_id],
        )

        miri = self.run_metadata("miri-packages", metadata=metadata)
        sanitizer = self.run_metadata(
            "sanitizer-packages",
            "address",
            metadata=metadata,
        )

        self.assertEqual(0, miri.returncode, miri.stderr)
        self.assertEqual("", miri.stdout)
        self.assertEqual(0, sanitizer.returncode, sanitizer.stderr)
        self.assertEqual("", sanitizer.stdout)

    def test_lists_packages_configured_for_address_sanitizer(self) -> None:
        first_id = "first 0.1.0 (path+file:///first)"
        second_id = "second 0.1.0 (path+file:///second)"
        result = self.run_metadata(
            "sanitizer-packages",
            "address",
            metadata=self.metadata(
                [
                    package(
                        self.root,
                        "first",
                        first_id,
                        {"sanitizers": ["address"]},
                    ),
                    package(
                        self.root,
                        "second",
                        second_id,
                        {"sanitizers": []},
                    ),
                ],
                [first_id, second_id],
            ),
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["first"], result.stdout.splitlines())

    def test_rejects_non_boolean_miri_value(self) -> None:
        package_id = "demo 0.1.0 (path+file:///demo)"
        result = self.run_metadata(
            "miri-packages",
            metadata=self.metadata(
                [package(self.root, "demo", package_id, {"miri": "true"})],
                [package_id],
            ),
        )

        self.assertNotIn(result.returncode, (0, 1))
        self.assertIn("miri", result.stderr)
        self.assertIn("boolean", result.stderr)

    def test_rejects_non_array_sanitizers(self) -> None:
        package_id = "demo 0.1.0 (path+file:///demo)"
        result = self.run_metadata(
            "sanitizer-packages",
            "address",
            metadata=self.metadata(
                [
                    package(
                        self.root,
                        "demo",
                        package_id,
                        {"sanitizers": "address"},
                    )
                ],
                [package_id],
            ),
        )

        self.assertNotIn(result.returncode, (0, 1))
        self.assertIn("sanitizers", result.stderr)
        self.assertIn("array", result.stderr)

    def test_rejects_non_string_duplicate_and_unknown_sanitizers(self) -> None:
        package_id = "demo 0.1.0 (path+file:///demo)"
        invalid_values = (
            (["address", 7], "strings"),
            (["address", "address"], "duplicate"),
            (["thread"], "unsupported"),
        )

        for sanitizers, expected in invalid_values:
            with self.subTest(sanitizers=sanitizers):
                result = self.run_metadata(
                    "sanitizer-packages",
                    "address",
                    metadata=self.metadata(
                        [
                            package(
                                self.root,
                                "demo",
                                package_id,
                                {"sanitizers": sanitizers},
                            )
                        ],
                        [package_id],
                    ),
                )

                self.assertNotIn(result.returncode, (0, 1))
                self.assertIn(expected, result.stderr)

    def test_rejects_non_object_rs_ci_metadata(self) -> None:
        package_id = "demo 0.1.0 (path+file:///demo)"
        result = self.run_metadata(
            "miri-packages",
            metadata=self.metadata(
                [package(self.root, "demo", package_id, "enabled")],
                [package_id],
            ),
        )

        self.assertNotIn(result.returncode, (0, 1))
        self.assertIn("object", result.stderr)

    def test_rejects_unknown_command_and_sanitizer_query(self) -> None:
        metadata = self.metadata([], [])

        command = self.run_metadata("unknown", metadata=metadata)
        sanitizer = self.run_metadata(
            "sanitizer-packages",
            "thread",
            metadata=metadata,
        )

        self.assertNotEqual(0, command.returncode)
        self.assertIn("Usage", command.stderr)
        self.assertNotEqual(0, sanitizer.returncode)
        self.assertIn("unsupported sanitizer", sanitizer.stderr)


if __name__ == "__main__":
    unittest.main()
