"""Tests for custom-flavor-release.yml workflow."""

from pathlib import Path

import pytest
import yaml

_EXPECTED_CRON = "0 6 * * 0"


def test_release_workflow_file_exists():
    """Test that the release workflow file exists."""
    workflow_path = Path(
        ".github/workflows/custom-flavor-release.yml",
    )

    assert workflow_path.exists(), (
        "Release workflow file should exist"
    )


def test_release_workflow_structure():
    """Test release workflow has correct structure."""
    workflow_path = Path(
        ".github/workflows/custom-flavor-release.yml",
    )

    with workflow_path.open() as f:
        workflow = yaml.safe_load(f)

    # Test basic structure
    assert "name" in workflow
    assert workflow["name"] == "Custom Flavor Release"

    # Test triggers
    assert "on" in workflow
    triggers = workflow["on"]

    # Schedule trigger
    assert "schedule" in triggers
    assert len(triggers["schedule"]) == 1
    assert (
        triggers["schedule"][0]["cron"] == _EXPECTED_CRON
    )

    # Push trigger for .mega-linter.yml changes
    assert "push" in triggers
    push_config = triggers["push"]
    assert "branches" in push_config
    assert push_config["branches"] == ["main"]
    assert "paths" in push_config
    assert ".mega-linter.yml" in push_config["paths"]

    # Manual dispatch
    assert "workflow_dispatch" in triggers

    # Test permissions
    assert "permissions" in workflow
    perms = workflow["permissions"]
    expected_perms = {
        "contents": "write",
        "packages": "write",
        "id-token": "write",
        "attestations": "write",
    }
    for perm, level in expected_perms.items():
        assert perms[perm] == level

    # Test jobs
    assert "jobs" in workflow
    assert "release" in workflow["jobs"]


def test_release_job_steps():
    """Test release job has all required steps."""
    workflow_path = Path(
        ".github/workflows/custom-flavor-release.yml",
    )

    with workflow_path.open() as f:
        workflow = yaml.safe_load(f)

    release_job = workflow["jobs"]["release"]

    # Check runs-on
    assert release_job["runs-on"] == "ubuntu-latest"

    # Check steps exist
    steps = release_job["steps"]
    step_names = [step["name"] for step in steps]

    required_steps = [
        "Checkout",
        "Organization membership check",
        "Determine version from upstream base image",
        "Generate custom flavor",
        "Validate flavor",
        "Set up Docker Buildx",
        "Login to GHCR",
        "Build image for testing",
        "Smoke-test image",
        "Push multi-platform image",
        "Generate SLSA provenance",
        "Generate SBOM",
        "Create GitHub release",
    ]

    for required_step in required_steps:
        assert any(
            required_step in name
            for name in step_names
        ), f"Missing step: {required_step}"


def test_organization_membership_step():
    """Test organization membership step structure."""
    workflow_path = Path(
        ".github/workflows/custom-flavor-release.yml",
    )

    with workflow_path.open() as f:
        workflow = yaml.safe_load(f)

    steps = workflow["jobs"]["release"]["steps"]
    org_check_step = next(
        step
        for step in steps
        if "Organization membership check"
        in step["name"]
    )

    # Should have conditional logic
    assert "if" in org_check_step
    # Should use GitHub API
    assert "run" in org_check_step
    assert (
        "GITHUB_TOKEN" in org_check_step["run"]
        or "env" in org_check_step
    )


def test_docker_build_step():
    """Test Docker build step has multi-platform."""
    workflow_path = Path(
        ".github/workflows/custom-flavor-release.yml",
    )

    with workflow_path.open() as f:
        workflow = yaml.safe_load(f)

    steps = workflow["jobs"]["release"]["steps"]
    build_step = next(
        step
        for step in steps
        if "Push multi-platform image" in step["name"]
    )

    # Should have platforms configured
    assert "with" in build_step
    with_params = build_step["with"]
    assert "platforms" in with_params
    platforms = with_params["platforms"]
    assert "linux/amd64" in platforms
    assert "linux/arm64" in platforms


def test_supply_chain_attestation_steps():
    """Test supply chain attestation steps exist."""
    workflow_path = Path(
        ".github/workflows/custom-flavor-release.yml",
    )

    with workflow_path.open() as f:
        workflow = yaml.safe_load(f)

    steps = workflow["jobs"]["release"]["steps"]
    step_names = [step["name"] for step in steps]

    # SLSA provenance
    assert any(
        "SLSA provenance" in name
        for name in step_names
    )

    # SBOM generation
    assert any(
        "SBOM" in name for name in step_names
    )


if __name__ == "__main__":
    pytest.main([__file__])
