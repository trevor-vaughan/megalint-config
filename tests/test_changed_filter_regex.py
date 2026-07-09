# tests/test_changed_filter_regex.py
"""Unit tests for scripts/changed_filter_regex.py."""

import importlib.util
import re
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).parent.parent
_script = REPO_ROOT / "scripts" / "changed_filter_regex.py"
_spec = importlib.util.spec_from_file_location("changed_filter_regex", _script)
cfr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cfr)


# --- effective() merge semantics (mirrors MegaLinter merge_dicts) ---

def test_append_when_key_in_config_properties_to_append():
    base = {"ADDITIONAL_EXCLUDED_DIRECTORIES": ["a", "b"]}
    entry = {
        "CONFIG_PROPERTIES_TO_APPEND": ["ADDITIONAL_EXCLUDED_DIRECTORIES"],
        "ADDITIONAL_EXCLUDED_DIRECTORIES": ["c"],
    }
    dirs, regex = cfr.effective(entry, base)
    assert dirs == ["a", "b", "c"]
    assert regex == ""


def test_replace_when_key_not_in_append_list():
    base = {"ADDITIONAL_EXCLUDED_DIRECTORIES": ["a", "b"]}
    entry = {"ADDITIONAL_EXCLUDED_DIRECTORIES": ["c"]}
    dirs, _ = cfr.effective(entry, base)
    assert dirs == ["c"]


def test_base_absent_uses_entry_only():
    entry = {"ADDITIONAL_EXCLUDED_DIRECTORIES": ["c"], "FILTER_REGEX_EXCLUDE": "^x/"}
    dirs, regex = cfr.effective(entry, None)
    assert dirs == ["c"]
    assert regex == "^x/"


def test_filter_regex_exclude_entry_overrides_base():
    base = {"FILTER_REGEX_EXCLUDE": "^vendor/"}
    entry = {"FILTER_REGEX_EXCLUDE": "^dist/"}
    _, regex = cfr.effective(entry, base)
    assert regex == "^dist/"


def test_filter_regex_exclude_inherited_from_base():
    base = {"FILTER_REGEX_EXCLUDE": "^vendor/"}
    entry = {"ADDITIONAL_EXCLUDED_DIRECTORIES": ["c"]}
    _, regex = cfr.effective(entry, base)
    assert regex == "^vendor/"


def test_filter_regex_exclude_list_is_coerced():
    _, regex = cfr.effective({"FILTER_REGEX_EXCLUDE": ["^a/", "^b/"]}, None)
    assert regex == "^a/|^b/"


# --- build() regex construction ---

def test_build_empty_dirs_returns_empty_even_with_existing_regex():
    # Regression guard: never emit a match-everything pattern like (?:^v/)|()
    assert cfr.build([], "^vendor/") == ""
    assert cfr.build([], "") == ""


def test_build_dedupes_and_drops_blanks():
    assert cfr.build(["a", "a", "", "b"], "") == "(^|/)(?:a|b)/"


def test_build_folds_in_existing_regex_non_capturing():
    out = cfr.build([".lola-eval"], "^vendor/")
    assert out == r"(?:^vendor/)|(^|/)(?:\.lola\-eval)/"


def test_build_regex_basename_at_any_depth_semantics():
    rx = re.compile(cfr.build([".lola-eval"], ""))
    assert rx.search(".lola-eval/x.py")          # root
    assert rx.search("a/b/.lola-eval/x.py")       # nested
    assert not rx.search("notlola-eval/x.py")     # substring, no boundary
    assert not rx.search(".lola-eval-extra/x.py") # prefix, no boundary


def test_build_preserves_existing_vendor_match():
    rx = re.compile(cfr.build(["custom-flavor"], "^vendor/"))
    assert rx.search("vendor/mod.go")
    assert rx.search("custom-flavor/Dockerfile")


# --- main() / CLI exit contract ---

def test_main_missing_entry_exits_nonzero(caplog):
    with caplog.at_level("ERROR"):
        assert cfr.main(["/no/such/config.yml"]) == 1
    assert "changed_filter_regex" in caplog.text
    assert "config not found" in caplog.text


def test_main_invalid_yaml_exits_nonzero(tmp_path, caplog):
    p = tmp_path / "bad.yml"
    p.write_text("this: [unclosed\n")
    with caplog.at_level("ERROR"):
        assert cfr.main([str(p)]) == 1
    assert "invalid YAML" in caplog.text


def test_main_missing_optional_base_is_not_error(tmp_path, capsys):
    entry = tmp_path / "e.yml"
    entry.write_text("ADDITIONAL_EXCLUDED_DIRECTORIES: [foo]\n")
    assert cfr.main([str(entry), str(tmp_path / "nope.yml")]) == 0
    assert capsys.readouterr().out.strip() == "(^|/)(?:foo)/"


def test_main_empty_output_prints_nothing(tmp_path, capsys):
    entry = tmp_path / "e.yml"
    entry.write_text("FILTER_REGEX_EXCLUDE: '^vendor/'\n")  # no excluded dirs
    assert cfr.main([str(entry)]) == 0
    assert capsys.readouterr().out == ""


def test_main_bad_arg_count_exits_2():
    assert cfr.main([]) == 2  # noqa: PLR2004  # usage-error exit code
    assert cfr.main(["a", "b", "c"]) == 2  # noqa: PLR2004  # usage-error exit code


# --- Regression pin against this repo's REAL config ---

def test_repo_config_changed_regex_excludes_custom_flavor_and_vendor():
    base = yaml.safe_load((REPO_ROOT / ".mega-linter.yml").read_text())
    entry = yaml.safe_load((REPO_ROOT / ".mega-linter.local.yml").read_text())
    dirs, regex = cfr.effective(entry, base)
    out = cfr.build(dirs, regex)
    assert out, "expected a non-empty changed-run FILTER_REGEX_EXCLUDE"
    rx = re.compile(out)
    assert rx.search("custom-flavor/Dockerfile")   # local's exclusion
    assert rx.search("vendor/mod.go")              # shared's ^vendor/
    assert not rx.search("scripts/parse_megalinter_config.py")
