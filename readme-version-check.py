#!/usr/bin/env python3
"""Check README dependency snippets use the current crate minor version."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class DependencyVersion:
    """A README dependency declaration for the current crate."""

    line_number: int
    version: str | None


@dataclass(frozen=True)
class Package:
    """Cargo metadata required for README dependency validation."""

    name: str
    version: str
    root: Path
    readme: Path | None


def project_root() -> Path:
    """Return the Rust project root to check."""
    return Path(os.environ.get("RS_CI_PROJECT_ROOT", os.getcwd())).resolve()


def load_packages(root: Path) -> list[Package]:
    """Resolve all workspace packages and inherited fields with Cargo metadata."""
    manifest_path = root / "Cargo.toml"
    if not manifest_path.is_file():
        raise ValueError(f"Cargo.toml not found in {root}")

    result = subprocess.run(
        [
            "cargo",
            "metadata",
            "--no-deps",
            "--format-version",
            "1",
            "--manifest-path",
            str(manifest_path),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "cargo metadata failed"
        raise ValueError(detail)

    metadata = json.loads(result.stdout)
    workspace_members = set(metadata["workspace_members"])
    packages: list[Package] = []
    for package in metadata["packages"]:
        if package["id"] not in workspace_members:
            continue
        package_root = Path(package["manifest_path"]).resolve().parent
        readme_value = package.get("readme")
        readme = (
            (package_root / readme_value).resolve()
            if isinstance(readme_value, str)
            else None
        )
        packages.append(
            Package(
                name=package["name"],
                version=package["version"],
                root=package_root,
                readme=readme,
            )
        )
    if not packages:
        raise ValueError("Cargo metadata did not report any workspace packages")
    return packages


def minor_version(version: str) -> str:
    """Return the major.minor version used in README dependency snippets."""
    match = re.match(r"^(\d+)\.(\d+)(?:[.\-+]|$)", version)
    if not match:
        raise ValueError(f"package version {version!r} does not start with major.minor")
    return f"{match.group(1)}.{match.group(2)}"


def readme_paths(packages: list[Package]) -> list[Path]:
    """Return existing README files declared by workspace packages."""
    candidates: list[Path] = []
    for package in packages:
        candidates.append(package.readme or package.root / "README.md")
        candidates.append(package.root / "README.zh_CN.md")

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


def validate_readme(
    path: Path,
    display_path: Path,
    package_name: str,
    expected_version: str,
) -> list[str]:
    """Validate one README file and return human-readable errors."""
    content = path.read_text(encoding="utf-8")
    versions = dependency_versions(content, package_name)
    if not versions:
        return []

    errors: list[str] = []
    for dependency in versions:
        if dependency.version is None:
            errors.append(
                f"{display_path}:{dependency.line_number}: dependency declaration for "
                f"{package_name} must include version = \"{expected_version}\""
            )
        elif dependency.version != expected_version:
            errors.append(
                f"{display_path}:{dependency.line_number}: expected \"{expected_version}\" "
                f"for {package_name}, found \"{dependency.version}\""
            )
    return errors


def main() -> int:
    """Run README version checks for the current Rust project."""
    root = project_root()
    try:
        packages = load_packages(root)
        paths = readme_paths(packages)
        if not paths:
            print("No README files found; skipping README dependency version check.")
            return 0

        errors: list[str] = []
        for path in paths:
            display_path = path.relative_to(root)
            for package in packages:
                errors.extend(
                    validate_readme(
                        path,
                        display_path,
                        package.name,
                        minor_version(package.version),
                    )
                )
        if errors:
            for error in errors:
                print(f"error: {error}", file=sys.stderr)
            return 1

        checked_declarations = [
            (path, package)
            for path in paths
            for package in packages
            if dependency_versions(path.read_text(encoding="utf-8"), package.name)
        ]
        if not checked_declarations:
            print(
                "No README dependency declarations found for workspace packages; "
                "skipping README dependency version check."
            )
            return 0

        checked = ", ".join(
            f"{package.name} in {path.relative_to(root)}"
            for path, package in checked_declarations
        )
        print(f"README dependency versions match workspace package versions: {checked}")
        return 0
    except (json.JSONDecodeError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
