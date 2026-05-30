# tests/test_templates.py
from pathlib import Path

from jinja2 import Environment, FileSystemLoader


def test_flavor_config_template():
    """Test mega-linter-flavor.yml template renders correctly."""
    template_dir = Path("scripts/templates")
    env = Environment(loader=FileSystemLoader(template_dir))
    template = env.get_template("mega-linter-flavor.yml.j2")

    context = {
        "linters": ["BASH_SHELLCHECK", "PYTHON_PYLINT"],
        "flavor_name": "custom-shared",
        "description": "Custom MegaLinter flavor for shared linting configuration",
    }

    result = template.render(**context)

    assert "flavor: custom-shared" in result
    assert "BASH_SHELLCHECK" in result
    assert "PYTHON_PYLINT" in result
    assert "Custom MegaLinter flavor" in result

def test_action_template():
    """Test action.yml template renders correctly."""
    template_dir = Path("scripts/templates")
    env = Environment(loader=FileSystemLoader(template_dir))
    template = env.get_template("action.yml.j2")

    context = {
        "flavor_name": "custom-shared",
        "description": "Custom MegaLinter flavor for shared configuration",
    }

    result = template.render(**context)

    assert "name: 'MegaLinter (custom-shared)'" in result
    assert "description: 'Custom MegaLinter flavor" in result
    assert "using: 'docker'" in result

def test_readme_template():
    """Test README.md template renders correctly."""
    template_dir = Path("scripts/templates")
    env = Environment(loader=FileSystemLoader(template_dir))
    template = env.get_template("README.md.j2")

    context = {
        "flavor_name": "custom-shared",
        "linters": ["BASH_SHELLCHECK", "PYTHON_PYLINT"],
        "repository": "org/megalinter-config",
        "registry": "ghcr.io",
        "description": "Custom MegaLinter flavor with 2 linters",
        "version": "9.0.0",
    }

    result = template.render(**context)

    assert "# MegaLinter Custom Flavor: custom-shared" in result
    assert "ghcr.io/org/megalinter-config" in result
    assert "BASH_SHELLCHECK" in result
    assert "PYTHON_PYLINT" in result
