#!/usr/bin/env python3
"""Validate custom MegaLinter flavor files."""

import argparse
import logging
import re
import sys
from pathlib import Path

import yaml

logger = logging.getLogger(__name__)


class ValidationError(Exception):
    """Exception raised for validation-specific errors."""


def _check_required_files(
    flavor_path: Path,
    required_files: list[str],
) -> list[str]:
    """Check that all required files exist.

    Args:
        flavor_path: Path to flavor directory
        required_files: List of required filenames

    Returns:
        List of checked file paths

    Raises:
        ValidationError: If any files are missing
    """
    missing_files = []
    files_checked = []

    for filename in required_files:
        file_path = flavor_path / filename
        files_checked.append(str(file_path))
        if not file_path.exists():
            missing_files.append(filename)

    if missing_files:
        msg = (
            "Missing required files:"
            f" {', '.join(missing_files)}"
        )
        raise ValidationError(msg)

    return files_checked


def _validate_yaml_files(
    flavor_path: Path,
    yaml_files: list[str],
) -> dict:
    """Parse and validate YAML files.

    Args:
        flavor_path: Path to flavor directory
        yaml_files: List of YAML filenames to validate

    Returns:
        Dict mapping filenames to parsed YAML data

    Raises:
        ValidationError: If any YAML files have errors
    """
    yaml_errors = []
    yaml_data = {}

    for yaml_file in yaml_files:
        yaml_path = flavor_path / yaml_file
        try:
            with yaml_path.open(encoding="utf-8") as f:
                yaml_data[yaml_file] = yaml.safe_load(f)
        except yaml.YAMLError as e:
            yaml_errors.append(
                f"YAML parsing error in {yaml_file}:"
                f" {e}",
            )
        except OSError as e:
            yaml_errors.append(
                f"Error reading {yaml_file}: {e}",
            )

    if yaml_errors:
        msg = (
            "YAML syntax errors:"
            f" {'; '.join(yaml_errors)}"
        )
        raise ValidationError(msg)

    return yaml_data


def _validate_content(yaml_data: dict) -> None:
    """Validate content fields in parsed YAML data.

    Args:
        yaml_data: Dict mapping filenames to parsed YAML

    Raises:
        ValidationError: If content validation fails
    """
    content_errors = []

    # Validate mega-linter-flavor.yml content
    flavor_config = (
        yaml_data.get("mega-linter-flavor.yml") or {}
    )
    if not isinstance(flavor_config, dict):
        msg = "mega-linter-flavor.yml must be a YAML mapping"
        raise ValidationError(msg)
    if not flavor_config.get("flavor"):
        content_errors.append(
            "mega-linter-flavor.yml is missing"
            " required 'flavor' field",
        )

    linters = flavor_config.get("linters")
    if linters is None:
        content_errors.append(
            "mega-linter-flavor.yml is missing"
            " required 'linters' field",
        )
    elif not isinstance(linters, list):
        content_errors.append(
            "mega-linter-flavor.yml 'linters'"
            " field must be a list",
        )
    elif len(linters) == 0:
        content_errors.append(
            "mega-linter-flavor.yml 'linters' field"
            " must contain at least 1 linter",
        )

    if content_errors:
        msg = (
            "Content validation errors:"
            f" {'; '.join(content_errors)}"
        )
        raise ValidationError(msg)


def _validate_dockerfile(flavor_path: Path) -> None:
    """Validate Dockerfile structure and security.

    Args:
        flavor_path: Path to flavor directory

    Raises:
        ValidationError: If Dockerfile has errors
    """
    dockerfile_errors = []
    dockerfile_path = flavor_path / "Dockerfile"

    try:
        with dockerfile_path.open(encoding="utf-8") as f:
            dockerfile_content = f.read()

        lines = [
            line.strip()
            for line in dockerfile_content.split("\n")
            if line.strip()
            and not line.strip().startswith("#")
        ]

        # Must contain at least one FROM directive
        has_from = any(
            line.upper().startswith("FROM ")
            for line in lines
        )
        if not has_from:
            dockerfile_errors.append(
                "Dockerfile must contain at least"
                " one FROM directive",
            )

        # Check for COPY or ADD commands
        has_copy_or_add = any(
            line.upper().startswith("COPY ")
            or line.upper().startswith("ADD ")
            for line in lines
        )
        if not has_copy_or_add:
            dockerfile_errors.append(
                "Dockerfile must contain at least"
                " one COPY or ADD command",
            )

        # Security: flag dangerous patterns
        # Only flag rm -rf targeting root itself, not subdirectories
        dangerous_patterns = [
            (r"rm\s+-rf\s+/\s", "rm -rf /"),
            (r"rm\s+-rf\s+/\*", "rm -rf /*"),
            (r"rm\s+-rf\s+/$", "rm -rf /"),
            (r"chmod\s+777", "chmod 777"),
            (r"--allow-run-as-root", "--allow-run-as-root"),
        ]

        for pattern, desc in dangerous_patterns:
            if re.search(
                pattern, dockerfile_content,
                re.IGNORECASE | re.MULTILINE,
            ):
                dockerfile_errors.append(
                    "Dockerfile contains potentially"
                    " dangerous command pattern:"
                    f" {desc}",
                )

    except OSError as e:
        dockerfile_errors.append(
            f"Error reading Dockerfile: {e}",
        )

    if dockerfile_errors:
        msg = (
            "Dockerfile validation errors:"
            f" {'; '.join(dockerfile_errors)}"
        )
        raise ValidationError(msg)


def validate_flavor(
    flavor_dir: str,
) -> dict[str, bool | dict | list]:
    """Validate flavor files and return validation report.

    Args:
        flavor_dir: Directory containing flavor files

    Returns:
        Dictionary containing validation results

    Raises:
        ValidationError: If validation fails
    """
    # Check if flavor directory exists
    flavor_path = Path(flavor_dir)
    if not flavor_path.exists():
        msg = (
            "Flavor directory does not exist:"
            f" {flavor_dir}"
        )
        raise ValidationError(msg)

    if not flavor_path.is_dir():
        msg = f"Path is not a directory: {flavor_dir}"
        raise ValidationError(msg)

    # Define required files
    required_files = [
        "mega-linter-flavor.yml",
        "Dockerfile",
    ]

    # Check required files exist
    files_checked = _check_required_files(
        flavor_path, required_files,
    )

    # Validate YAML syntax
    yaml_files = ["mega-linter-flavor.yml"]
    yaml_data = _validate_yaml_files(
        flavor_path, yaml_files,
    )

    # Validate content fields
    _validate_content(yaml_data)

    # Validate Dockerfile
    _validate_dockerfile(flavor_path)

    # Return success report
    return {
        "success": True,
        "checks": {
            "files_exist": True,
            "yaml_valid": True,
            "dockerfile_valid": True,
            "content_valid": True,
        },
        "errors": [],
        "warnings": [],
        "files_checked": files_checked,
    }


def main():
    """CLI entry point."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(message)s",
    )

    parser = argparse.ArgumentParser(
        description=(
            "Validate custom MegaLinter flavor files"
        ),
        formatter_class=(
            argparse.RawDescriptionHelpFormatter
        ),
        epilog=(
            "Examples:\n"
            "  python validate_custom_flavor.py"
            " ./custom-flavor"
        ),
    )

    parser.add_argument(
        "flavor_dir",
        help=(
            "Directory containing flavor files"
            " to validate"
        ),
    )

    args = parser.parse_args()

    try:
        result = validate_flavor(args.flavor_dir)

        logger.info("Flavor validation successful!")
        logger.info(
            "Validated directory: %s", args.flavor_dir,
        )
        logger.info("Checks performed:")
        for check in result["checks"]:
            logger.info("   pass %s", check.replace("_", " ").title())

        logger.info("All validation checks passed!")

    except ValidationError:
        logger.exception("Validation failed")
        sys.exit(1)
    except KeyboardInterrupt:
        logger.warning("Validation cancelled by user")
        sys.exit(1)
    except Exception:
        logger.exception("Unexpected error")
        sys.exit(1)


if __name__ == "__main__":
    main()
