#!/usr/bin/env python3
"""Derive a changed-run FILTER_REGEX_EXCLUDE from a MegaLinter config.

MegaLinter applies ADDITIONAL_EXCLUDED_DIRECTORIES only on full-codebase runs
(the os.walk in MegaLinter.list_files_all). On VALIDATE_ALL_CODEBASE=false runs
the file list comes from `git diff` (list_files_git_diff) and those directories
are never pruned, so excluded-dir files get linted anyway.
FILTER_REGEX_EXCLUDE, by contrast, is honored on both paths (utils.filter_files).

WORKAROUND: remove this script and its runner wiring (the injection block in
.taskfiles/scripts/megalint-run.sh) once the upstream fix ships in a MegaLinter
release the custom flavor pins:
https://github.com/oxsecurity/megalinter/issues/8360

This script computes a FILTER_REGEX_EXCLUDE that folds the effective config's
ADDITIONAL_EXCLUDED_DIRECTORIES into its existing FILTER_REGEX_EXCLUDE. The
runner injects the output as the FILTER_REGEX_EXCLUDE env var; MegaLinter merges
env last (config.init_config: `config_data | env_plus_params`, then combine_config
applies the env-merged config last), so it replaces the file value — hence the
existing value must be folded in here.

Merge model mirrors MegaLinter's combine_config/merge_dicts for two keys:
  - ADDITIONAL_EXCLUDED_DIRECTORIES: entry appends to base iff the key is in the
    entry's CONFIG_PROPERTIES_TO_APPEND, else entry replaces base.
  - FILTER_REGEX_EXCLUDE: entry's value if defined, else base's.
Only a single entry + one base are modeled (the runner stages exactly one
shared base); multi-level/remote EXTENDS is out of scope.

Usage: changed_filter_regex.py <entry-config> [<base-config>]
Prints the combined regex, or nothing when there are no excluded dirs to add.
Exit 0 on success (incl. empty output); non-zero on a missing/invalid entry.
"""

import logging
import re
import sys
from pathlib import Path

import yaml

logger = logging.getLogger(__name__)

DIRS_KEY = "ADDITIONAL_EXCLUDED_DIRECTORIES"
APPEND_KEY = "CONFIG_PROPERTIES_TO_APPEND"
REGEX_KEY = "FILTER_REGEX_EXCLUDE"


class ConfigError(Exception):
    """Raised when a required config file is missing or malformed."""


def _load(path: str, required: bool = True) -> dict:
    """Load a YAML config file into a mapping, or {} when optional and absent."""
    p = Path(path)
    if not p.is_file():
        if required:
            msg = f"config not found: {path}"
            raise ConfigError(msg)
        return {}
    try:
        data = yaml.safe_load(p.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        msg = f"invalid YAML in {path}: {exc}"
        raise ConfigError(msg) from exc
    if data is None:
        return {}
    if not isinstance(data, dict):
        msg = f"config must be a YAML mapping: {path}"
        raise ConfigError(msg)
    return data


def _as_regex_str(value: object) -> str:
    """Coerce a FILTER_REGEX_EXCLUDE value to a string.

    MegaLinter reads the global value as a scalar and re.compile()s it, so a
    YAML list already breaks it upstream; we defensively join a list into an
    alternation instead of crashing. Anything else becomes empty.
    """
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "|".join(str(v) for v in value if str(v))
    return ""


def effective(entry: dict, base: dict | None = None) -> tuple[list, str]:
    """Return (excluded_dirs, filter_regex_exclude) merging base then entry."""
    base = base or {}
    dirs = list(base.get(DIRS_KEY) or [])
    regex = _as_regex_str(base.get(REGEX_KEY, ""))
    if DIRS_KEY in entry:
        entry_dirs = list(entry.get(DIRS_KEY) or [])
        append = DIRS_KEY in (entry.get(APPEND_KEY) or [])
        dirs = dirs + entry_dirs if append else entry_dirs
    if REGEX_KEY in entry:
        regex = _as_regex_str(entry.get(REGEX_KEY, ""))
    return dirs, regex


def build(dirs: list, existing_regex: str) -> str:
    """Build the combined regex; return "" when there are no dirs to exclude."""
    seen = set()
    ordered = []
    for d in dirs:
        s = str(d)
        if s and s not in seen:
            seen.add(s)
            ordered.append(s)
    if not ordered:
        return ""
    alt = "|".join(re.escape(d) for d in ordered)
    dir_regex = f"(^|/)(?:{alt})/"
    if existing_regex:
        return f"(?:{existing_regex})|{dir_regex}"
    return dir_regex


def main(argv: list) -> int:
    """CLI entry point: print the combined regex and return the exit code."""
    if not 1 <= len(argv) <= 2:  # noqa: PLR2004  # 1 entry config, optional base
        logger.error(
            "usage: changed_filter_regex.py <entry-config> [<base-config>]",
        )
        return 2
    try:
        entry = _load(argv[0], required=True)
        base = _load(argv[1], required=False) if len(argv) == 2 else None  # noqa: PLR2004  # 2 == entry + base
    except ConfigError as exc:
        logger.error("changed_filter_regex: %s", exc)  # noqa: TRY400  # exit-code path, not an unexpected exception
        return 1
    dirs, regex = effective(entry, base)
    out = build(dirs, regex)
    if out:
        print(out)  # noqa: T201  # stdout is the resolver's output, captured by the runner
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
