#!/usr/bin/env python3
"""Parse MegaLinter configuration and extract linter information."""

import logging
import sys
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)


class ConfigError(Exception):
    """Configuration parsing error."""


def parse_config(config_path: str) -> dict[str, Any]:
    """Parse MegaLinter configuration file and return linter info.

    Args:
        config_path: Path to .mega-linter.yml file

    Returns:
        Dict containing:
        - linters: List of enabled linter names
        - base_config: Original config content as string

    Raises:
        ConfigError: If file not found, invalid YAML,
            or missing ENABLE_LINTERS
    """
    config_file = Path(config_path)

    if not config_file.exists():
        msg = (
            "Configuration file not found:"
            f" {config_path}"
        )
        raise ConfigError(msg)

    try:
        with config_file.open(encoding="utf-8") as f:
            content = f.read()
            config = yaml.safe_load(content)
    except yaml.YAMLError as e:
        msg = f"Invalid YAML in {config_path}: {e}"
        raise ConfigError(msg) from e

    if not isinstance(config, dict):
        msg = (
            "Configuration must be a YAML dictionary:"
            f" {config_path}"
        )
        raise ConfigError(msg)

    if "ENABLE_LINTERS" not in config:
        msg = "ENABLE_LINTERS not found in configuration"
        raise ConfigError(msg)

    linters = config["ENABLE_LINTERS"]
    if not isinstance(linters, list):
        msg = "ENABLE_LINTERS must be a list"
        raise ConfigError(msg)

    if not linters:
        msg = "ENABLE_LINTERS cannot be empty"
        raise ConfigError(msg)

    return {
        "linters": linters,
        "base_config": content.strip(),
    }


def main():
    """CLI entry point."""
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    if len(sys.argv) != 2:  # noqa: PLR2004
        logger.error(
            "Usage: parse_megalinter_config.py"
            " <config-file>",
        )
        sys.exit(1)

    try:
        result = parse_config(sys.argv[1])
        logger.info(
            "Found %d enabled linters:",
            len(result["linters"]),
        )
        for linter in result["linters"]:
            logger.info("  - %s", linter)
    except ConfigError:
        logger.exception("Configuration error")
        sys.exit(1)


if __name__ == "__main__":
    main()
