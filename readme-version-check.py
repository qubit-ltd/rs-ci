#!/usr/bin/env python3
"""Check README dependency snippets use the current crate minor version."""

from __future__ import annotations

import os
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class DependencyVersion:
    """A README dependency declaration for the current crate."""

    line_number: int
    version: str | None


def project_root() -> Path:
    """Return the Rust project root to check."""
    return Path(os.environ.get("RS_CI_PROJECT_ROOT", os.getcwd())).resolve()


def load_package(root: Path) -> tuple[str, str, object]:
    """Read package name, version, and readme metadata from Cargo.toml."""
    manifest_path = root / "Cargo.toml"
    if not manifest_path.is_file():
        raise ValueError(f"Cargo.toml not found in {root}")

    manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    package = manifest.get("package")
    if not isinstance(package, dict):
        raise ValueError("Cargo.toml does not contain a [package] table")

    name = package.get("name")
    version = package.get("version")
    if not isinstance(name, str) or not name:
        raise ValueError("Cargo.toml [package] does not declare a valid name")
    if not isinstance(version, str) or not version:
        raise ValueError("Cargo.toml [package] does not declare a valid version")

    return name, version, package.get("readme")


def minor_version(version: str) -> str:
    """Return the major.minor version used in README dependency snippets."""
    match = re.match(r"^(\d+)\.(\d+)(?:[.\-+]|$)", version)
    if not match:
        raise ValueError(f"package version {version!r} does not start with major.minor")
    return f"{match.group(1)}.{match.group(2)}"


def readme_paths(root: Path, readme_metadata: object) -> list[Path]:
    """Return existing README files that should contain dependency snippets."""
    candidates: list[Path] = []
    if isinstance(readme_metadata, str):
        candidates.append(root / readme_metadata)
    elif readme_metadata is not False:
        candidates.append(root / "README.md")
    candidates.append(root / "README.zh_CN.md")

    seen: set[Path] = set()
    existing: list[Path] = []
    for path in candidates:
        resolved = path.resolve()
        if resolved not in seen and path.is_file():
            seen.add(resolved)
            existing.append(path)
    return existing


def dependency_versions(content: str, package_name: str) -> list[DependencyVersion]:
    """Extract current-crate dependency versions from README text."""
    line_pattern = re.compile(
        rf"^\s*{re.escape(package_name)}\s*=\s*(?P<value>.+?)\s*(?:#.*)?$"
    )
    versions: list[DependencyVersion] = []
    for line_number, line in enumerate(content.splitlines(), start=1):
        match = line_pattern.match(line)
        if match is None:
            continue

        value = match.group("value").strip()
        string_match = re.match(r'^"([^"]+)"\s*$', value)
        if string_match is not None:
            versions.append(DependencyVersion(line_number, string_match.group(1)))
            continue

        inline_match = re.search(r'\bversion\s*=\s*"([^"]+)"', value)
        versions.append(
            DependencyVersion(
                line_number,
                inline_match.group(1) if inline_match is not None else None,
            )
        )
    return versions


def validate_readme(path: Path, package_name: str, expected_version: str) -> list[str]:
    """Validate one README file and return human-readable errors."""
    content = path.read_text(encoding="utf-8")
    versions = dependency_versions(content, package_name)
    if not versions:
        return []

    errors: list[str] = []
    for dependency in versions:
        if dependency.version is None:
            errors.append(
                f"{path.name}:{dependency.line_number}: dependency declaration for "
                f"{package_name} must include version = \"{expected_version}\""
            )
        elif dependency.version != expected_version:
            errors.append(
                f"{path.name}:{dependency.line_number}: expected \"{expected_version}\" "
                f"for {package_name}, found \"{dependency.version}\""
            )
    return errors


def main() -> int:
    """Run README version checks for the current Rust project."""
    root = project_root()
    try:
        package_name, package_version, readme_metadata = load_package(root)
        expected_version = minor_version(package_version)
        paths = readme_paths(root, readme_metadata)
        if not paths:
            print("No README files found; skipping README dependency version check.")
            return 0

        errors: list[str] = []
        for path in paths:
            errors.extend(validate_readme(path, package_name, expected_version))
        if errors:
            for error in errors:
                print(f"error: {error}", file=sys.stderr)
            return 1

        checked_paths = [
            path
            for path in paths
            if dependency_versions(path.read_text(encoding="utf-8"), package_name)
        ]
        if not checked_paths:
            print(
                f"No README dependency declarations found for {package_name}; "
                "skipping README dependency version check."
            )
            return 0

        checked = ", ".join(path.name for path in checked_paths)
        print(
            f"README dependency versions match {package_name} "
            f"minor version {expected_version}: {checked}"
        )
        return 0
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
