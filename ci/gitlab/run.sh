#!/usr/bin/env bash
# Script invoked by ci/gitlab/megalint.yml. Installs Task, runs the
# shared MegaLinter Taskfile, and relocates reports if requested.
set -euo pipefail

: "${MEGALINT_WORKING_DIRECTORY:?must be set by the template}"
: "${MEGALINT_REPORTS_DIR:?must be set by the template}"
: "${MEGALINTER_IMAGE:?must be set by the template}"
: "${MEGALINT_PULL_POLICY:?must be set by the template}"
: "${MEGALINT_VALIDATE_ALL_CODEBASE:=false}"
: "${MEGALINT_VERIFY:=}"

# Pin Task version. Update via Task 0 verification process when bumping.
TASK_VERSION='v3.51.1'

# Install Task to /usr/local/bin. The installer flag for bindir is -b
# (not -d -b — -d is the installer's debug flag, easy mistake to make).
# Fetch the installer separately so a curl failure surfaces under set -e
# instead of being masked by the surrounding sh -c command substitution.
task_installer=$(curl -fsSL https://taskfile.dev/install.sh)
sh -c "${task_installer}" -- -b /usr/local/bin "${TASK_VERSION}"

cd /tmp/megalint-runner

lint_rc=0
VALIDATE_ALL_CODEBASE="${MEGALINT_VALIDATE_ALL_CODEBASE}" \
	task -y megalint:run \
	TARGET="${MEGALINT_WORKING_DIRECTORY}" \
	MEGALINTER_IMAGE="${MEGALINTER_IMAGE}" \
	PULL_POLICY="${MEGALINT_PULL_POLICY}" \
	MEGALINT_VERIFY="${MEGALINT_VERIFY}" || lint_rc=$?

# Relocate reports regardless of lint outcome (parallels action.yml's
# always()). A relocation failure must not mask the lint's exit code.
bash /tmp/megalint-runner/.taskfiles/scripts/megalint-relocate-reports.sh \
	"${MEGALINT_WORKING_DIRECTORY}" \
	"${MEGALINT_WORKING_DIRECTORY}/megalinter-reports" \
	"${MEGALINT_REPORTS_DIR}" ||
	echo "WARNING: report relocation failed (rc=$?); preserving lint exit code" >&2

exit "${lint_rc}"
