#!/usr/bin/env bash
# Derive the changed-files ENABLE_LINTERS set from a MegaLinter config.
#
# Prints, as a single comma-separated line, the ENABLE_LINTERS entries that are
# NOT repository-scoped (i.e. do not start with REPOSITORY_). The reduced set is
# `full − REPOSITORY_*`: repository linters scan the whole repo regardless of
# VALIDATE_ALL_CODEBASE, so they add no incremental value on a changed-file run.
#
# The changed task injects this as the ENABLE_LINTERS environment variable, which
# MegaLinter honors (as CSV) and merges last, so it wins over the file/EXTENDS
# chain — letting .mega-linter.local.yml stay the entry config while the
# repository linters are stripped. See config.py get_list / combine_config in the
# pinned MegaLinter source.
#
# Reads .mega-linter.yml's block-style ENABLE_LINTERS list. A PyYAML-backed test
# (tests/test_config_sanity.py) pins this output to a real parse, so a future
# reformat to flow style fails CI instead of silently misfiring.
#
# Usage: changed-enable-linters.sh <config-file>
set -euo pipefail

config="${1:?usage: changed-enable-linters.sh <config-file>}"
[[ -f "${config}" ]] || {
	echo "changed-enable-linters: config not found: ${config}" >&2
	exit 1
}

csv="$(awk '
  /^ENABLE_LINTERS:[[:space:]]*$/ { inblock = 1; next }
  inblock && /^[A-Za-z0-9_]/      { inblock = 0 }
  inblock && /^[[:space:]]*-[[:space:]]*[A-Za-z0-9_]+/ {
    name = $0
    sub(/^[[:space:]]*-[[:space:]]*/, "", name)   # drop "  - "
    sub(/[[:space:]].*$/, "", name)               # drop trailing inline comment
    if (name !~ /^REPOSITORY_/) printf "%s\n", name
  }
' "${config}" | paste -sd,)"

# An empty result means the block was absent, reformatted, or held only
# repository linters. Emitting an empty ENABLE_LINTERS would let MegaLinter fall
# back to default activation and run the wrong set, so abort loudly instead.
[[ -n "${csv}" ]] || {
	echo "changed-enable-linters: no non-repository ENABLE_LINTERS found in ${config}" >&2
	exit 1
}

printf '%s\n' "${csv}"
