"""Tests for custom-flavor-release.yml workflow."""

import re
from pathlib import Path

import pytest
import yaml

_EXPECTED_CRON = "0 6 * * 0"


def _release_workflow():
    workflow_path = Path(".github/workflows/custom-flavor-release.yml")
    with workflow_path.open() as f:
        return yaml.safe_load(f)


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

    # Push trigger fires on version tags only (releases are tag-driven).
    assert "push" in triggers
    push_config = triggers["push"]
    assert "tags" in push_config
    assert push_config["tags"] == ["v*"]
    # The old main-branch / .mega-linter.yml auto-publish trigger is removed.
    assert "branches" not in push_config

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
        "Verify actor has write access",
        "Resolve upstream base version",
        "Compute release identity",
        "Generate custom flavor",
        "Validate flavor",
        "Set up Docker Buildx",
        "Login to GHCR",
        "Assemble image tags",
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


def test_actor_write_access_step():
    """Release must be gated on the actor's repo write access.

    The repo owner is a user account (not an org), so an org-membership
    check would 404 and block every release. The gate instead verifies the
    triggering actor has write/maintain/admin permission via the GitHub API.
    """
    workflow_path = Path(
        ".github/workflows/custom-flavor-release.yml",
    )

    with workflow_path.open() as f:
        workflow = yaml.safe_load(f)

    steps = workflow["jobs"]["release"]["steps"]
    access_step = next(
        step
        for step in steps
        if "Verify actor has write access" in step["name"]
    )

    # Uses the GitHub API to check permission, authenticated with the token.
    assert "run" in access_step
    assert "permission" in access_step["run"]
    assert "GH_TOKEN" in access_step.get("env", {})


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


def test_create_release_step_gated_on_identity():
    """Release creation must be gated on the computed identity, not a ref.

    Regression guard: the previous design gated this step on
    `github.ref == 'refs/heads/main'`, so a tag push could never create a
    release. It must now depend on the `create_release` output.
    """
    workflow_path = Path(
        ".github/workflows/custom-flavor-release.yml",
    )

    with workflow_path.open() as f:
        workflow = yaml.safe_load(f)

    steps = workflow["jobs"]["release"]["steps"]
    release_step = next(
        step
        for step in steps
        if "Create GitHub release" in step["name"]
    )

    assert "if" in release_step
    assert "create_release" in release_step["if"]
    assert "refs/heads/main" not in release_step["if"]


def test_base_image_pinned_to_validated_version():
    """Release base image must pin the exact version PR-validation clones."""
    workflow = _release_workflow()
    default_base = workflow["env"]["DEFAULT_BASE_IMAGE"]
    flavor_yml = Path(".taskfiles/flavor.yml").read_text(encoding="utf-8")
    m = re.search(
        r'MEGALINTER_VERSION[^\n]*default\s+"([0-9]+\.[0-9]+\.[0-9]+)"',
        flavor_yml,
    )
    assert m, "could not read pinned MEGALINTER_VERSION default from flavor.yml"
    pinned = m.group(1)
    assert default_base == f"ghcr.io/oxsecurity/megalinter:v{pinned}", (
        f"DEFAULT_BASE_IMAGE must pin v{pinned} to match PR validation"
    )


def test_repo_scan_uses_freshly_built_test_image():
    """Finding #1: the repo scan must run the :test image built this run."""
    workflow = _release_workflow()
    steps = workflow["jobs"]["release"]["steps"]
    scan = next(s for s in steps if s.get("id") == "repo-scan")
    with_params = scan["with"]
    assert with_params["megalinter-image"] == "megalinter-custom-flavor:test"
    assert with_params["pull-policy"] == "never"
    assert with_params["verify"] == "skip"


if __name__ == "__main__":
    pytest.main([__file__])
