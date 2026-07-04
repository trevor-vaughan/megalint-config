#!/usr/bin/env bash
# Relocate MegaLinter reports after a run. Pure function of its three args so
# both the GitHub composite action and the GitLab run.sh share one
# implementation. Safe to call even when the lint failed or wrote nothing.
#
# Usage: megalint-relocate-reports.sh <working_dir> <default_reports> <target_reports>
set -euo pipefail

working_dir="${1:?working_dir required}"
default="${2:?default_reports dir required}"
target="${3:?target_reports dir required}"

default="$(realpath -m "${default}")"
target="$(realpath -m "${target}")"

# Move the log into the default reports-dir first (if both exist), so it
# travels with the reports regardless of relocation.
if [[ -f "${working_dir}/mega-linter.log" && -d "${default}" ]]; then
	mv "${working_dir}/mega-linter.log" "${default}/"
fi

# Then optionally relocate the whole reports-dir to a non-default target.
# Guard with -d so a crash before reports were written doesn't mask the
# original failure with a missing-source mv error.
if [[ "${default}" != "${target}" && -d "${default}" ]]; then
	mkdir -p "$(dirname "${target}")"
	rm -rf "${target}"
	mv "${default}" "${target}"
fi
