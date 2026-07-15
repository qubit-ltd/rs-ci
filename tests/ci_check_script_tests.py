#!/usr/bin/env python3
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CI_CHECK_SCRIPT = REPO_ROOT / "ci-check.sh"


class CiCheckScriptTests(unittest.TestCase):
    def test_documentation_build_checks_all_features_and_missing_docs(self) -> None:
        script = CI_CHECK_SCRIPT.read_text(encoding="utf-8")

        self.assertEqual(
            2,
            script.count('RUSTDOCFLAGS="-D warnings -D missing-docs"'),
        )
        self.assertEqual(
            2,
            script.count("doc --all-features --no-deps --verbose"),
        )


if __name__ == "__main__":
    unittest.main()
