"""Test cases for validate_custom_flavor.py script."""

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

# Import the hyphenated script file via importlib
_script_path = (
    Path(__file__).parent.parent
    / "scripts"
    / "validate_custom_flavor.py"
)
_spec = importlib.util.spec_from_file_location(
    "validate_custom_flavor", _script_path,
)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

ValidationError = _mod.ValidationError
validate_flavor = _mod.validate_flavor
main = _mod.main


def test_validation_error_exception_exists():
    """Test ValidationError can be imported/raised."""
    msg = "Test error message"
    with pytest.raises(ValidationError):
        raise ValidationError(msg)


def test_validation_error_has_message():
    """Test that ValidationError preserves messages."""
    error_msg = "Custom validation error"

    with pytest.raises(ValidationError) as exc_info:
        raise ValidationError(error_msg)

    assert str(exc_info.value) == error_msg


def test_validate_flavor_missing_directory():
    """Test validate_flavor for non-existent dir."""
    non_existent_dir = "/path/that/does/not/exist"

    with pytest.raises(ValidationError) as exc_info:
        validate_flavor(non_existent_dir)

    assert "does not exist" in str(
        exc_info.value,
    ).lower()


def test_validate_flavor_missing_required_files():
    """Test validate_flavor with missing files."""
    with tempfile.TemporaryDirectory() as temp_dir:
        # Empty directory missing all required files
        with pytest.raises(
            ValidationError,
        ) as exc_info:
            validate_flavor(temp_dir)

        assert "missing required files" in str(
            exc_info.value,
        ).lower()


def test_validate_flavor_success_with_all_files(
    flavor_files_factory, valid_flavor_files,
):
    """Test validate_flavor with all required files."""
    temp_dir = flavor_files_factory(valid_flavor_files)
    result = validate_flavor(temp_dir)

    assert isinstance(result, dict)
    assert result["success"] is True
    assert result["checks"]["files_exist"] is True


def test_validate_flavor_invalid_yaml_syntax(
    flavor_files_factory, minimal_dockerfile,
):
    """Test validate_flavor with invalid YAML."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": "invalid: yaml: [syntax here}",
        "Dockerfile": minimal_dockerfile,
    })

    with pytest.raises(ValidationError) as exc_info:
        validate_flavor(temp_dir)

    error_msg = str(exc_info.value).lower()
    assert "yaml" in error_msg
    assert "syntax" in error_msg or "parsing" in error_msg


def test_validate_flavor_valid_yaml_syntax(
    flavor_files_factory, valid_flavor_files,
):
    """Test validate_flavor with valid YAML syntax."""
    temp_dir = flavor_files_factory(valid_flavor_files)
    result = validate_flavor(temp_dir)

    assert result["success"] is True
    assert result["checks"]["yaml_valid"] is True


def test_validate_flavor_missing_flavor_field(
    flavor_files_factory, minimal_dockerfile,
):
    """Test missing 'flavor' field."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": "linters: [BASH_SHELLCHECK]",
        "Dockerfile": minimal_dockerfile,
    })

    with pytest.raises(ValidationError) as exc_info:
        validate_flavor(temp_dir)

    error_msg = str(exc_info.value).lower()
    assert "flavor" in error_msg
    assert "field" in error_msg


def test_validate_flavor_missing_linters_field(
    flavor_files_factory, minimal_dockerfile,
):
    """Test missing 'linters' field."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": "flavor: test",
        "Dockerfile": minimal_dockerfile,
    })

    with pytest.raises(ValidationError) as exc_info:
        validate_flavor(temp_dir)

    error_msg = str(exc_info.value).lower()
    assert "linters" in error_msg
    assert "field" in error_msg


def test_validate_flavor_empty_linters(
    flavor_files_factory, minimal_dockerfile,
):
    """Test empty linters list."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": "flavor: test\nlinters: []",
        "Dockerfile": minimal_dockerfile,
    })

    with pytest.raises(ValidationError) as exc_info:
        validate_flavor(temp_dir)

    error_msg = str(exc_info.value).lower()
    assert "linters" in error_msg
    assert "empty" in error_msg or "least 1" in error_msg


def test_validate_flavor_valid_content(flavor_files_factory):
    """Test validate_flavor with valid content."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": (
            "flavor: test-flavor\n"
            "linters: [BASH_SHELLCHECK, PYTHON_PYLINT]"
        ),
        "Dockerfile": "FROM oxsecurity/megalinter:v9\nCOPY . /tmp/lint",
    })

    result = validate_flavor(temp_dir)
    assert result["success"] is True
    assert result["checks"]["content_valid"] is True


def test_validate_flavor_dockerfile_missing_from(
    flavor_files_factory, minimal_flavor_yml,
):
    """Test Dockerfile missing FROM directive."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": minimal_flavor_yml,
        "Dockerfile": "RUN echo 'missing FROM directive'",
    })

    with pytest.raises(ValidationError) as exc_info:
        validate_flavor(temp_dir)

    error_msg = str(exc_info.value).lower()
    assert "dockerfile" in error_msg
    assert "from" in error_msg
    assert "at least one" in error_msg


def test_validate_flavor_multistage_dockerfile(
    flavor_files_factory, minimal_flavor_yml,
):
    """Test Dockerfile with ARG before FROM passes."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": minimal_flavor_yml,
        "Dockerfile": (
            "ARG SHELLCHECK_VERSION=v0.11.0\n"
            "FROM koalaman/shellcheck:${SHELLCHECK_VERSION} AS shellcheck\n"
            "FROM python:3.14-alpine3.23\n"
            "COPY --from=shellcheck /bin/shellcheck /usr/bin/shellcheck\n"
            "RUN rm -rf /var/cache/apk/*"
        ),
    })

    result = validate_flavor(temp_dir)
    assert result["success"] is True


def test_validate_flavor_dockerfile_legitimate_cleanup(
    flavor_files_factory, minimal_flavor_yml,
):
    """Test Dockerfile with legitimate rm -rf patterns passes."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": minimal_flavor_yml,
        "Dockerfile": (
            "FROM python:3.14-alpine3.23\n"
            "RUN apk add --no-cache bash \\\n"
            "    && rm -rf /var/cache/apk/* \\\n"
            "    && rm -rf /root/.cache \\\n"
            "    && rm -rf /tmp/*\n"
            "COPY . /app"
        ),
    })

    result = validate_flavor(temp_dir)
    assert result["success"] is True


def test_validate_flavor_dockerfile_missing_copy(
    flavor_files_factory, minimal_flavor_yml,
):
    """Test Dockerfile missing COPY or ADD commands."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": minimal_flavor_yml,
        "Dockerfile": (
            "FROM oxsecurity/megalinter:v9\n"
            "RUN echo 'no copy or add'"
        ),
    })

    with pytest.raises(ValidationError) as exc_info:
        validate_flavor(temp_dir)

    error_msg = str(exc_info.value).lower()
    assert "dockerfile" in error_msg
    assert "copy" in error_msg or "add" in error_msg


def test_validate_flavor_dockerfile_invalid_syntax(
    flavor_files_factory, minimal_flavor_yml,
):
    """Test Dockerfile with invalid syntax."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": minimal_flavor_yml,
        "Dockerfile": (
            "FROM oxsecurity/megalinter:v9\n"
            "RUN rm -rf / # dangerous command injection"
        ),
    })

    with pytest.raises(ValidationError) as exc_info:
        validate_flavor(temp_dir)

    error_msg = str(exc_info.value).lower()
    assert "dockerfile" in error_msg
    assert "dangerous" in error_msg or "security" in error_msg


def test_validate_flavor_valid_dockerfile(flavor_files_factory):
    """Test validate_flavor with valid Dockerfile."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": (
            "flavor: test-flavor\n"
            "linters: [BASH_SHELLCHECK, PYTHON_PYLINT]"
        ),
        "Dockerfile": (
            "FROM oxsecurity/megalinter:v9\n"
            "COPY . /tmp/lint\n"
            "WORKDIR /tmp/lint"
        ),
    })

    result = validate_flavor(temp_dir)
    assert result["success"] is True
    assert result["checks"]["dockerfile_valid"] is True


def test_validate_flavor_config_must_be_a_mapping(flavor_files_factory):
    """Test flavor config as a YAML list raises a clear error."""
    temp_dir = flavor_files_factory({
        "mega-linter-flavor.yml": "- a\n- b\n",
        "Dockerfile": "FROM oxsecurity/megalinter:v9\nCOPY . /tmp/lint",
    })

    with pytest.raises(ValidationError, match="mapping"):
        validate_flavor(temp_dir)


def test_cli_main_function_exists():
    """Test that the main function exists."""
    assert callable(main)


def test_cli_script_execution():
    """Test that CLI script can be executed."""
    result = subprocess.run(
        [
            sys.executable,
            str(_script_path),
            "--help",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert (
        "usage:" in result.stdout.lower()
        or "validate" in result.stdout.lower()
    )


def test_cli_missing_directory():
    """Test CLI with missing directory."""
    result = subprocess.run(
        [
            sys.executable,
            str(_script_path),
            "/nonexistent/path",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Should exit with error code
    assert result.returncode != 0
    assert (
        "error" in result.stderr.lower()
        or "does not exist" in result.stderr.lower()
    )


def test_cli_successful_validation(flavor_files_factory, valid_flavor_files):
    """Test CLI with valid flavor."""
    temp_dir = flavor_files_factory(valid_flavor_files)

    result = subprocess.run(
        [sys.executable, str(_script_path), str(temp_dir)],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    output = (result.stdout + result.stderr).lower()
    assert "success" in output or "valid" in output
