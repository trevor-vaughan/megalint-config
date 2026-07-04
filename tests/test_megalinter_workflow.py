"""Tests for the MegaLinter dogfooding workflow and its SARIF-upload gate.

These guard the fix for the code-scanning upload failure ("1 item required;
only 0 were supplied"): GitHub rejects a SARIF whose ``runs`` array is empty,
which MegaLinter emits when a changed-files run matches zero lint-relevant
files. Pull requests are the only diff-linting trigger — there is no push
trigger — so the empty-diff runs (tag pushes, post-merge pushes to ``main``)
and the duplicate feature-branch push that produced that SARIF cannot occur,
and the upload step is additionally gated on the report having results.
"""

from pathlib import Path

import yaml

_WORKFLOW = Path(".github/workflows/megalinter.yml")
_ACTION = Path("action.yml")
_UPLOAD_ACTION = "github/codeql-action/upload-sarif"


def _load(path: Path):
    with path.open() as f:
        return yaml.safe_load(f)


def test_megalinter_workflow_file_exists():
    assert _WORKFLOW.exists(), "MegaLinter workflow file should exist"


def test_no_push_trigger_pr_is_the_gate():
    """Pull requests are the only diff-linting trigger; no push trigger.

    A push trigger would lint feature-branch commits twice (once on the push,
    once on the pull_request run) and, on ``main`` or tags, produce an
    empty-``runs`` SARIF that fails the code-scanning upload. Pull requests
    lint every change before merge; the weekly schedule refreshes ``main``'s
    Code Scanning baseline.
    """
    workflow = _load(_WORKFLOW)

    # PyYAML (YAML 1.1) parses a bare ``on:`` key as boolean True; the repo
    # convention is to quote ``"on":`` so it stays a string key.
    assert "on" in workflow, 'workflow trigger key must be quoted as "on":'
    triggers = workflow["on"]

    # No push trigger: the PR run is the gate, the schedule is the baseline.
    assert "push" not in triggers, (
        "push trigger must be removed; the PR run already lints every change"
    )

    # Pull requests to main remain the real gate; schedule keeps the full scan.
    assert triggers["pull_request"]["branches"] == ["main"]
    assert "schedule" in triggers


def test_sarif_upload_is_gated_on_results():
    """The upload step must only run when the SARIF has results."""
    workflow = _load(_WORKFLOW)
    steps = workflow["jobs"]["megalinter"]["steps"]

    upload = next(
        (s for s in steps if str(s.get("uses", "")).startswith(_UPLOAD_ACTION)),
        None,
    )
    assert upload is not None, "workflow must upload SARIF to code scanning"
    assert "sarif-has-results" in upload.get("if", ""), (
        "SARIF upload must be gated on the action's sarif-has-results output"
    )


def test_action_exposes_sarif_has_results_output():
    """The composite action must expose the gate signal for callers."""
    action = _load(_ACTION)
    outputs = action["outputs"]
    assert "sarif-has-results" in outputs, (
        "action must expose sarif-has-results so callers can gate the upload"
    )
    assert "publish" in outputs["sarif-has-results"]["value"], (
        "sarif-has-results should come from the publish step"
    )


def test_artifact_validation_rejects_symlinks_not_dead_glob():
    workflow = _load(Path(".github/workflows/custom-flavor-validate.yml"))
    steps = workflow["jobs"]["test-docker-build"]["steps"]
    step = next(s for s in steps if s.get("name") == "Validate artifact contents")
    run = step["run"]
    assert '-name "*/.."' not in run, "dead basename glob must be removed"
    assert "-type l" in run, "must reject symlinks (a check that actually fires)"


def test_timeout_diagnostic_covers_sigkill_137():
    action = _load(_ACTION)
    steps = action["runs"]["steps"]
    step = next(
        s for s in steps if s.get("name") == "Run MegaLinter via shared Taskfile"
    )
    run = step["run"]
    assert "137" in run, "timeout diagnostic must also match SIGKILL (rc 137)"
    assert "124" in run


def test_cache_week_uses_iso_week_year():
    workflow = _load(_WORKFLOW)
    steps = workflow["jobs"]["megalinter"]["steps"]
    step = next(s for s in steps if s.get("name") == "Compute cache week")
    assert "+%G-W%V" in step["run"], "use ISO week-numbering year (%G), not %Y"
    assert "+%Y-W%V" not in step["run"]


def test_setup_build_env_installs_bats():
    action = _load(Path(".github/actions/setup-build-env/action.yml"))
    steps = action["runs"]["steps"]
    joined = " ".join(str(s.get("run", "")) + str(s.get("name", "")) for s in steps)
    assert "bats" in joined, "setup-build-env must install bats for the shell test gate"


def test_check_task_runs_bats_runner():
    root_tf = _load(Path("Taskfile.yml"))
    check = root_tf["tasks"]["check"]
    wiring = str(check.get("deps", "")) + str(check.get("cmds", ""))
    assert "test:runner" in wiring, "check must run the bats runner"


def test_relocate_step_does_not_mask_lint_result():
    action = _load(_ACTION)
    steps = action["runs"]["steps"]
    step = next(s for s in steps if s.get("name") == "Relocate reports if requested")
    run = step["run"]
    # A relocation failure must not fail the job (which would mask the lint result).
    assert "::warning::" in run or "|| " in run, (
        "relocate step must tolerate a relocation failure (warn, not abort)"
    )
