"""Shared test fixtures and utilities."""

from pathlib import Path

import pytest


@pytest.fixture
def flavor_files_factory(tmp_path):
    """Factory fixture for creating test flavor files.

    Returns a function that creates flavor files with given content
    in a temporary directory.

    Example:
        def test_something(flavor_files_factory):
            temp_dir = flavor_files_factory({
                "mega-linter-flavor.yml": "flavor: test\\nlinters: [BASH]",
                "Dockerfile": "FROM oxsecurity/megalinter:v9"
            })
    """
    def _create_files(
        files_content: dict[str, str],
        base_dir: Path | None = None,
    ) -> Path:
        """Create files with given content.

        Args:
            files_content: Dict mapping filename to content
            base_dir: Base directory (uses tmp_path if None)

        Returns:
            Path to the directory containing the files
        """
        target_dir = base_dir or tmp_path
        for filename, content in files_content.items():
            file_path = Path(target_dir) / filename
            file_path.write_text(content)
        return target_dir

    return _create_files


@pytest.fixture
def valid_flavor_files() -> dict[str, str]:
    """Default content for valid flavor files."""
    return {
        "mega-linter-flavor.yml": (
            "flavor: test\n"
            "linters: [BASH_SHELLCHECK]"
        ),
        "Dockerfile": (
            "FROM oxsecurity/megalinter:v9\n"
            "COPY . /tmp/lint"
        ),
    }


@pytest.fixture
def minimal_dockerfile() -> str:
    """Minimal valid Dockerfile content."""
    return "FROM oxsecurity/megalinter:v9"


@pytest.fixture
def minimal_flavor_yml() -> str:
    """Minimal valid mega-linter-flavor.yml content."""
    return "flavor: test\nlinters: [BASH_SHELLCHECK]"
