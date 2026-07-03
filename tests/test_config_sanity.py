# tests/test_config_sanity.py
"""Sanity checks for the shared MegaLinter config and its overrides.

Structural tests run everywhere (pure YAML). Descriptor-backed tests need the
pinned MegaLinter clone (task flavor:clone) and skip with a reason when it is
absent, so they gate the flavor-validation workflow without breaking the
clone-free unit gate.
"""

import importlib.util
import json
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent

script_path = REPO_ROOT / "scripts" / "validate_config.py"
spec = importlib.util.spec_from_file_location("validate_config", script_path)
validate_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validate_config)

BASE_CONFIG = REPO_ROOT / ".mega-linter.yml"
CHANGED_CONFIG = REPO_ROOT / ".mega-linter.d" / ".mega-linter-changed.yml"
LOCAL_CONFIG = REPO_ROOT / ".mega-linter.local.yml"
JSCPD_CONFIG = REPO_ROOT / ".mega-linter.d" / ".jscpd.json"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def base_config() -> dict:
    return validate_config.load_config(BASE_CONFIG)


@pytest.fixture(scope="module")
def changed_config() -> dict:
    return validate_config.load_config(CHANGED_CONFIG)


@pytest.fixture(scope="module")
def descriptors_dir() -> Path:
    """Descriptors dir from the cached clone, or skip if unavailable."""
    found = validate_config.find_descriptors_dir(REPO_ROOT / ".cache")
    if found is None:
        pytest.skip(
            "MegaLinter clone not found; run 'task flavor:clone' to enable"
            " descriptor-backed linter-key validation.",
        )
    return found


@pytest.fixture(scope="module")
def valid_keys(descriptors_dir: Path) -> set[str]:
    return validate_config.load_valid_linter_keys(descriptors_dir)


@pytest.fixture(scope="module")
def descriptor_ids(descriptors_dir: Path) -> set[str]:
    return validate_config.load_descriptor_ids(descriptors_dir)


# ---------------------------------------------------------------------------
# Structural tests (no MegaLinter clone required)
# ---------------------------------------------------------------------------


def test_base_config_parses(base_config: dict):
    assert isinstance(base_config, dict)
    enable = validate_config.linter_list(base_config, "ENABLE_LINTERS")
    assert enable, "ENABLE_LINTERS must not be empty"


def test_enable_linters_no_duplicates(base_config: dict):
    enable = validate_config.linter_list(base_config, "ENABLE_LINTERS")
    assert validate_config.duplicate_keys(enable) == []


def test_disable_linters_no_duplicates(base_config: dict):
    disable = validate_config.linter_list(base_config, "DISABLE_LINTERS")
    assert validate_config.duplicate_keys(disable) == []


def test_no_enable_disable_overlap(base_config: dict):
    enable = validate_config.linter_list(base_config, "ENABLE_LINTERS")
    disable = validate_config.linter_list(base_config, "DISABLE_LINTERS")
    assert validate_config.enable_disable_overlap(enable, disable) == []


def test_changed_override_extends_base(changed_config: dict):
    assert validate_config.extends_errors(
        changed_config, BASE_CONFIG.name,
    ) == []


def test_changed_override_preserves_invariant(
    base_config: dict,
    changed_config: dict,
):
    """Override must equal base minus REPOSITORY_* — no leak, none missing."""
    enable = validate_config.linter_list(base_config, "ENABLE_LINTERS")
    changed_enable = validate_config.linter_list(
        changed_config, "ENABLE_LINTERS",
    )
    assert validate_config.override_invariant_errors(
        enable, changed_enable,
    ) == []


def test_changed_override_has_no_repository_linters(changed_config: dict):
    changed_enable = validate_config.linter_list(
        changed_config, "ENABLE_LINTERS",
    )
    leaked = [
        k
        for k in changed_enable
        if k.startswith(validate_config.REPOSITORY_PREFIX)
    ]
    assert leaked == []


def test_kics_removed_from_enabled_linters(base_config: dict):
    """KICS must not be built or run after its upstream supply-chain compromise.

    The slim flavor is generated from ENABLE_LINTERS alone (see
    scripts/build_flavor_dockerfile.py), so absence here is what keeps the
    KICS binary out of the published image. The DISABLE_LINTERS entry is
    documentation and defense-in-depth. IaC coverage is retained via
    REPOSITORY_CHECKOV and REPOSITORY_TRIVY.
    """
    enable = validate_config.linter_list(base_config, "ENABLE_LINTERS")
    disable = validate_config.linter_list(base_config, "DISABLE_LINTERS")
    assert "REPOSITORY_KICS" not in enable
    assert "REPOSITORY_KICS" in disable


def test_rust_clippy_removed_from_enabled_linters(base_config: dict):
    """RUST_CLIPPY needs a full rustup toolchain the slim flavor can't build.

    The flavor generator emits a bare `cargo install` with no rustup bootstrap
    (scripts/build_flavor_dockerfile.py), so an enabled cargo-based linter
    breaks the image build with `cargo: not found`. RUST_CLIPPY is dropped from
    the shared profile; a consuming Rust repo can re-enable it and build its own
    flavor. See test_no_enabled_linter_requires_cargo_toolchain for the general,
    descriptor-backed guard against re-introducing this class of failure.
    """
    enable = validate_config.linter_list(base_config, "ENABLE_LINTERS")
    disable = validate_config.linter_list(base_config, "DISABLE_LINTERS")
    assert "RUST_CLIPPY" not in enable
    assert "RUST_CLIPPY" in disable


def test_trufflehog_disables_verification(base_config: dict):
    """CI-safe default: TruffleHog must not verify results.

    Verification calls arbitrary external APIs (AWS STS, Slack, GitHub, ...)
    to confirm a discovered secret is live. Those endpoints can block GitHub
    Actions runner IPs and hang the run indefinitely, and MegaLinter has no
    per-linter timeout.

    --no-update is deliberately absent here: the descriptor's own
    cli_lint_extra_args already passes --no-update, and repeating it makes
    trufflehog exit with "flag 'no-update' cannot be repeated" (verified
    against trufflehog 3.95.6, the pinned descriptor version).
    """
    args = base_config.get("REPOSITORY_TRUFFLEHOG_ARGUMENTS", [])
    assert "--no-verification" in args
    assert "--no-update" not in args


def test_trufflehog_scans_git_history_not_filesystem(base_config: dict):
    """TruffleHog must scan committed git objects, not the raw filesystem.

    The descriptor defaults to `filesystem .`, which walks the working tree
    including gitignored/untracked content (.venv/, node_modules/, build
    output, ...). trufflehog's filesystem mode has no .gitignore support
    (upstream issue, unresolved: trufflehog#3356), so those directories
    become false positives with no generic way to exclude them across
    arbitrary target repos.

    "git file://." reads git objects directly, so anything not committed is
    invisible to it by construction. --branch=HEAD bounds the scan to the
    currently checked-out ref instead of every branch in the mounted .git.
    "filesystem" and "." are stripped via COMMAND_REMOVE_ARGUMENTS since the
    descriptor hardcodes them as the scan source.
    """
    args = base_config.get("REPOSITORY_TRUFFLEHOG_ARGUMENTS", [])
    assert args[:3] == ["git", "file://.", "--branch=HEAD"]
    remove_args = base_config.get(
        "REPOSITORY_TRUFFLEHOG_COMMAND_REMOVE_ARGUMENTS", [],
    )
    assert "filesystem" in remove_args
    assert "." in remove_args


def test_trufflehog_removes_only_verified(base_config: dict):
    """--only-verified is incompatible with --no-verification.

    The descriptor's cli_lint_extra_args passes --only-verified by default.
    Combined with --no-verification, nothing is ever "verified", so every
    result would be silently filtered out and --fail would never trigger
    even with real secrets present (verified against trufflehog 3.95.6).
    """
    remove_args = base_config.get(
        "REPOSITORY_TRUFFLEHOG_COMMAND_REMOVE_ARGUMENTS", [],
    )
    assert "--only-verified" in remove_args


def test_local_override_extends_shared_config():
    """The repo-local override inherits from the staged shared config name."""
    local = validate_config.load_config(LOCAL_CONFIG)
    assert validate_config.extends_errors(
        local, ".mega-linter.shared.yml",
    ) == []


# ---------------------------------------------------------------------------
# Vendor-directory exclusion
# ---------------------------------------------------------------------------
#
# Go repos commit their module-root `vendor/` tree of third-party sources;
# consuming repos must not lint it. The exclusion is ROOT-ANCHORED on purpose:
# Go treats only `<module-root>/vendor/` (marked by vendor/modules.txt) as
# vendored — a `vendor` segment nested deeper (pkg/foo/vendor/impl.go) is an
# ordinary first-party package that `go build` and golangci-lint lint normally,
# so it must NOT be skipped.
#
# Two facts drive the mechanism:
#   - ADDITIONAL_EXCLUDED_DIRECTORIES matches by directory *basename* at every
#     depth and cannot be root-anchored, so `vendor` must NOT be listed there
#     (it would over-exclude nested first-party packages).
#   - Changed-files runs (task megalint:changed, VALIDATE_ALL_CODEBASE=false)
#     build the file list from `git diff`, which never consults
#     ADDITIONAL_EXCLUDED_DIRECTORIES anyway — only FILTER_REGEX_EXCLUDE filters
#     it. A root-anchored FILTER_REGEX_EXCLUDE covers every file/list_of_files
#     linter in both modes. Project-mode jscpd needs its own root-anchored glob.


def test_base_config_does_not_basename_exclude_vendor(base_config: dict):
    """`vendor` must not be in ADDITIONAL_EXCLUDED_DIRECTORIES: basename
    matching there would skip nested first-party `vendor` packages, not just
    the module-root vendored tree."""
    excluded = base_config.get("ADDITIONAL_EXCLUDED_DIRECTORIES", [])
    assert "vendor" not in excluded


def test_base_config_filter_regex_excludes_root_vendor_only(base_config: dict):
    """Root-anchored FILTER_REGEX_EXCLUDE skips the module-root vendored tree in
    both run modes, without swallowing nested or lookalike paths."""
    pattern = base_config.get("FILTER_REGEX_EXCLUDE")
    assert pattern is not None, "FILTER_REGEX_EXCLUDE must be set"
    compiled = re.compile(pattern)
    # Module-root vendored tree -> excluded.
    assert compiled.search("vendor/modules.txt")
    assert compiled.search("vendor/github.com/x/y.go")
    # Nested first-party `vendor` package -> MUST still be linted.
    assert not compiled.search("pkg/foo/vendor/github.com/x/y.go")
    assert not compiled.search("my/pkg/vendor/bobs_burgers.go")
    # Lookalikes / unrelated -> not matched.
    assert not compiled.search("src/app.go")
    assert not compiled.search("myvendor/x.go")
    assert not compiled.search("docs/vendor.md")


def test_changed_config_inherits_vendor_exclusion(
    base_config: dict,
    changed_config: dict,
):
    """The changed-files override must not shadow the base's vendor regex.

    It EXTENDS the base (scalars inherited, lists replaced). It deliberately
    replaces ENABLE_LINTERS but must leave FILTER_REGEX_EXCLUDE inherited so
    changed-files runs still skip the module-root vendor tree.
    """
    effective = changed_config.get(
        "FILTER_REGEX_EXCLUDE",
        base_config.get("FILTER_REGEX_EXCLUDE"),
    )
    assert effective is not None
    compiled = re.compile(effective)
    assert compiled.search("vendor/modules.txt")
    assert not compiled.search("my/pkg/vendor/bobs_burgers.go")


def test_jscpd_ignores_root_vendor_only():
    """COPYPASTE_JSCPD is project-mode: it walks the tree itself and ignores
    the MegaLinter file list, so vendor needs a native ignore glob. It is
    root-anchored (`vendor/**`, verified to skip only root vendor while still
    scanning nested/vendor) to match the FILTER_REGEX_EXCLUDE semantics."""
    ignore = json.loads(JSCPD_CONFIG.read_text()).get("ignore", [])
    assert "vendor/**" in ignore
    assert "**/vendor/**" not in ignore


# ---------------------------------------------------------------------------
# Descriptor-backed tests (require the pinned MegaLinter clone)
# ---------------------------------------------------------------------------


@pytest.mark.integration
def test_all_enabled_keys_are_real_linters(
    base_config: dict,
    valid_keys: set[str],
):
    enable = validate_config.linter_list(base_config, "ENABLE_LINTERS")
    assert validate_config.unknown_linter_keys(enable, valid_keys) == []


@pytest.mark.integration
def test_all_disabled_keys_are_real_linters(
    base_config: dict,
    valid_keys: set[str],
):
    disable = validate_config.linter_list(base_config, "DISABLE_LINTERS")
    assert validate_config.unknown_linter_keys(disable, valid_keys) == []


@pytest.mark.integration
def test_all_enabled_keys_are_installable(
    base_config: dict,
    descriptor_ids: set[str],
):
    """Every enabled key must map to a descriptor the slim flavor can build."""
    enable = validate_config.linter_list(base_config, "ENABLE_LINTERS")
    assert validate_config.uninstallable_linter_keys(
        enable, descriptor_ids,
    ) == []


@pytest.mark.integration
def test_changed_override_keys_are_installable(
    changed_config: dict,
    descriptor_ids: set[str],
):
    changed_enable = validate_config.linter_list(
        changed_config, "ENABLE_LINTERS",
    )
    assert validate_config.uninstallable_linter_keys(
        changed_enable, descriptor_ids,
    ) == []


@pytest.mark.integration
def test_no_enabled_linter_requires_cargo_toolchain(
    base_config: dict,
    descriptors_dir: Path,
):
    """No enabled linter may need `cargo install`.

    The slim flavor generator cannot bootstrap a Rust/cargo toolchain, so a
    cargo-based linter (e.g. RUST_CLIPPY) breaks the image build with
    `cargo: not found`. This guards the whole class, not just clippy.
    """
    enable = validate_config.linter_list(base_config, "ENABLE_LINTERS")
    assert validate_config.cargo_toolchain_linters(
        enable, descriptors_dir,
    ) == []


# ---------------------------------------------------------------------------
# Negative tests (validators must reject bad input)
# ---------------------------------------------------------------------------


def test_unknown_linter_keys_flags_typo():
    valid = {"GO_GOLANGCI_LINT", "RUBY_RUBOCOP"}
    keys = ["GO_GOLANGCI_LINT", "GO_GOLANGCILINT", "RUST_CLIPPY"]
    assert validate_config.unknown_linter_keys(keys, valid) == [
        "GO_GOLANGCILINT",
        "RUST_CLIPPY",
    ]


def test_uninstallable_flags_schema_alias_without_descriptor():
    """OPENAPI_SPECTRAL passes the schema but has no descriptor; flag it."""
    ids = {"API", "MARKDOWN", "GO"}
    keys = ["API_SPECTRAL", "MARKDOWN_MARKDOWN_LINK_CHECK", "OPENAPI_SPECTRAL"]
    assert validate_config.uninstallable_linter_keys(keys, ids) == [
        "OPENAPI_SPECTRAL",
    ]


def test_duplicate_keys_detected():
    assert validate_config.duplicate_keys(
        ["A", "B", "A", "C", "B"],
    ) == ["A", "B"]


def test_enable_disable_overlap_detected():
    assert validate_config.enable_disable_overlap(
        ["A", "B", "C"], ["B", "D"],
    ) == ["B"]


def test_override_invariant_flags_repository_leak():
    base = ["BASH_SHELLCHECK", "REPOSITORY_TRIVY"]
    override = ["BASH_SHELLCHECK", "REPOSITORY_TRIVY"]
    errors = validate_config.override_invariant_errors(base, override)
    assert any("REPOSITORY_TRIVY" in e for e in errors)


def test_override_invariant_flags_missing_linter():
    base = ["BASH_SHELLCHECK", "PYTHON_RUFF", "REPOSITORY_TRIVY"]
    override = ["BASH_SHELLCHECK"]
    errors = validate_config.override_invariant_errors(base, override)
    assert any("PYTHON_RUFF" in e for e in errors)


def test_override_invariant_accepts_correct_override():
    base = ["BASH_SHELLCHECK", "PYTHON_RUFF", "REPOSITORY_TRIVY"]
    override = ["BASH_SHELLCHECK", "PYTHON_RUFF"]
    assert validate_config.override_invariant_errors(base, override) == []


def test_load_config_rejects_missing_file(tmp_path: Path):
    with pytest.raises(validate_config.ConfigError, match="not found"):
        validate_config.load_config(tmp_path / "nope.yml")


def test_load_config_rejects_non_mapping(tmp_path: Path):
    bad = tmp_path / "bad.yml"
    bad.write_text("- just\n- a\n- list\n")
    with pytest.raises(validate_config.ConfigError, match="must be a YAML mapping"):
        validate_config.load_config(bad)


def test_find_descriptors_dir_picks_highest_version(tmp_path: Path):
    # "1.0.0" is included because plain lexical sort ranks
    # "megalinter-v1.0.0" first (its "." byte sorts below "0"), which would
    # make a naive fix that only reorders "2"/"9.6.0"/"10.0.0" pass by luck.
    cache = tmp_path / ".cache"
    for ver in ("1.0.0", "2", "9.6.0", "10.0.0"):
        d = cache / f"megalinter-v{ver}" / "megalinter" / "descriptors"
        d.mkdir(parents=True)
    result = validate_config.find_descriptors_dir(cache)
    assert result == cache / "megalinter-v10.0.0" / "megalinter" / "descriptors"


def test_resolve_ref_strips_only_pointer_prefix():
    # A $ref pointing at a definitions key literally named "#foo".
    # lstrip("#/") would wrongly strip the leading '#' of that key too.
    schema = {"#foo": {"ok": 1}}
    result = validate_config._resolve_ref(schema, "#/#foo")  # noqa: SLF001
    assert result == {"ok": 1}
