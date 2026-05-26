"""Tests for version management logic.

The custom flavor version is derived from the upstream MegaLinter
base image tag at CI build time.  These tests verify the parsing,
normalisation, and validation logic in isolation.
"""

import re

import pytest

_SEMVER_PATTERN = r"^\d+\.\d+\.\d+$"


def _is_semver(version: str) -> bool:
    """Return True if version matches semver format."""
    return bool(re.match(_SEMVER_PATTERN, version))


def _tag_to_semver(tag: str) -> str:
    """Normalise a Docker image tag to semver.

    Mirrors the shell logic in
    custom-flavor-release.yml: strip leading 'v',
    split on '.', pad missing components with 0.
    """
    raw = tag.lstrip("v")
    parts = raw.split(".")
    major = parts[0] if len(parts) > 0 else "0"
    minor = parts[1] if len(parts) > 1 else "0"
    patch = parts[2] if len(parts) > 2 else "0"  # noqa: PLR2004
    return f"{major}.{minor}.{patch}"


def test_tag_to_semver_normalisation():
    """Test upstream image tag to semver conversion."""
    assert _tag_to_semver("v9") == "9.0.0"
    assert _tag_to_semver("v9.5.0") == "9.5.0"
    assert _tag_to_semver("v8.1.2") == "8.1.2"
    assert _tag_to_semver("9.5.0") == "9.5.0"
    assert _tag_to_semver("v10") == "10.0.0"
    assert _tag_to_semver("v9.5") == "9.5.0"


def test_semantic_version_format_validation():
    """Test semantic version format validation."""
    valid = ["1.0.0", "9.5.0", "10.20.30", "0.0.1"]
    invalid = [
        "1.0", "v1.0.0", "1.0.0-beta",
        "abc", "1.0.0.0", "",
    ]

    for v in valid:
        assert _is_semver(v), (
            f"{v} should be valid semver"
        )
    for v in invalid:
        assert not _is_semver(v), (
            f"{v} should be invalid semver"
        )


def test_normalised_tags_are_valid_semver():
    """Normalised tags must always pass validation."""
    tags = [
        "v9", "v9.5.0", "v8.1.2",
        "9.5.0", "v10", "v9.5",
    ]
    for tag in tags:
        result = _tag_to_semver(tag)
        assert _is_semver(result), (
            f"tag {tag!r} normalised to {result!r}"
            " which is not valid semver"
        )


if __name__ == "__main__":
    pytest.main([__file__])
