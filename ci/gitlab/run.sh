#!/usr/bin/env bash
# Script invoked by ci/gitlab/megalint.yml. Installs Task, runs the
# shared MegaLinter Taskfile, and relocates reports if requested.
set -euo pipefail

: "${MEGALINT_WORKING_DIRECTORY:?must be set by the template}"
: "${MEGALINT_REPORTS_DIR:?must be set by the template}"
: "${MEGALINTER_IMAGE:?must be set by the template}"
: "${MEGALINT_PULL_POLICY:?must be set by the template}"
: "${MEGALINT_VALIDATE_ALL_CODEBASE:=false}"

# Pin Task version. Update via Task 0 verification process when bumping.
TASK_VERSION='v3.51.1'

# Install Task to /usr/local/bin. The installer flag for bindir is -b
# (not -d -b — -d is the installer's debug flag, easy mistake to make).
# Fetch the installer separately so a curl failure surfaces under set -e
# instead of being masked by the surrounding sh -c command substitution.
task_installer=$(curl -fsSL https://taskfile.dev/install.sh)
sh -c "${task_installer}" -- -b /usr/local/bin "${TASK_VERSION}"

cd /tmp/megalint-runner

VALIDATE_ALL_CODEBASE="${MEGALINT_VALIDATE_ALL_CODEBASE}" \
	task -y megalint:run \
	TARGET="${MEGALINT_WORKING_DIRECTORY}" \
	MEGALINTER_IMAGE="${MEGALINTER_IMAGE}" \
	PULL_POLICY="${MEGALINT_PULL_POLICY}"

# Always move the log into the default reports-dir first (if both exist),
# so the log travels with the reports regardless of relocation.
default_reports="${MEGALINT_WORKING_DIRECTORY}/megalinter-reports"
if [[ -f "${MEGALINT_WORKING_DIRECTORY}/mega-linter.log" && -d "${default_reports}" ]]; then
	mv "${MEGALINT_WORKING_DIRECTORY}/mega-linter.log" "${default_reports}/"
fi

# Then optionally relocate the whole reports-dir to a non-default target.
# Guard with -d so a MegaLinter crash before reports were written doesn't
# mask the original failure with a missing-source mv error.
default_abs="$(realpath -m "${default_reports}")"
target_abs="$(realpath -m "${MEGALINT_REPORTS_DIR}")"
if [[ "${default_abs}" != "${target_abs}" && -d "${default_reports}" ]]; then
	mkdir -p "$(dirname "${MEGALINT_REPORTS_DIR}")"
	rm -rf "${MEGALINT_REPORTS_DIR}"
	mv "${default_reports}" "${MEGALINT_REPORTS_DIR}"
fi
