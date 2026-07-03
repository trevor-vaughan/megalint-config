# tests/test_parse_megalinter_config.py
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

# Import the renamed script file
script_path = (
    Path(__file__).parent.parent
    / "scripts"
    / "parse_megalinter_config.py"
)
spec = importlib.util.spec_from_file_location(
    "parse_megalinter_config", script_path,
)
parse_megalinter_config = (
    importlib.util.module_from_spec(spec)
)
spec.loader.exec_module(parse_megalinter_config)

parse_config = parse_megalinter_config.parse_config
ConfigError = parse_megalinter_config.ConfigError


def test_parse_valid_config():
    """Test parsing valid configuration."""
    config_content = """
ENABLE_LINTERS:
  - BASH_SHELLCHECK
  - PYTHON_PYLINT
  - YAML_YAMLLINT
DEFAULT_BRANCH: main
"""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yml", delete=False,
    ) as f:
        f.write(config_content)
        f.flush()
        fname = f.name

    try:
        result = parse_config(fname)

        assert result["linters"] == [
            "BASH_SHELLCHECK",
            "PYTHON_PYLINT",
            "YAML_YAMLLINT",
        ]
        assert result["base_config"] == (
            config_content.strip()
        )
    finally:
        Path(fname).unlink()


def test_parse_missing_file():
    """Test parsing non-existent file."""
    with pytest.raises(
        ConfigError,
        match="Configuration file not found",
    ):
        parse_config("nonexistent.yml")


def test_parse_invalid_yaml():
    """Test parsing invalid YAML."""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yml", delete=False,
    ) as f:
        f.write("invalid: yaml: content: [")
        f.flush()
        fname = f.name

    try:
        with pytest.raises(
            ConfigError, match="Invalid YAML",
        ):
            parse_config(fname)
    finally:
        Path(fname).unlink()


def test_parse_missing_enable_linters():
    """Test parsing config missing ENABLE_LINTERS."""
    config_content = """
DEFAULT_BRANCH: main
DISABLE_LINTERS:
  - BASH_SHFMT
"""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yml", delete=False,
    ) as f:
        f.write(config_content)
        f.flush()
        fname = f.name

    try:
        with pytest.raises(
            ConfigError,
            match="ENABLE_LINTERS not found",
        ):
            parse_config(fname)
    finally:
        Path(fname).unlink()


def test_cli_emits_success_output(tmp_path):
    cfg = tmp_path / ".mega-linter.yml"
    cfg.write_text("ENABLE_LINTERS:\n  - BASH_SHELLCHECK\n", encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(script_path), str(cfg)],
        capture_output=True, text=True, check=True,
    )
    combined = proc.stdout + proc.stderr
    assert "Found 1 enabled linters" in combined
    assert "BASH_SHELLCHECK" in combined


def test_parse_empty_enable_linters():
    """Test parsing config with empty linters."""
    config_content = """
ENABLE_LINTERS: []
DEFAULT_BRANCH: main
"""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yml", delete=False,
    ) as f:
        f.write(config_content)
        f.flush()
        fname = f.name

    try:
        with pytest.raises(
            ConfigError,
            match="ENABLE_LINTERS cannot be empty",
        ):
            parse_config(fname)
    finally:
        Path(fname).unlink()
