#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:?Usage: megalinter-sarif-chunk.sh <root-dir>}"
REPORT_DIR="${ROOT_DIR}/megalinter-reports"
SARIF="${REPORT_DIR}/megalinter-report.sarif"
CHUNK_DIR="${REPORT_DIR}/llm-sarif"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# This script is chained after `megalint:run` via `defer`, so it runs
# even when the lint exits non-zero. If the lint never wrote a SARIF
# (e.g., container init failure, signal interrupt), there's nothing to
# chunk — exit cleanly so callers don't see a spurious error.
if [[ ! -f "${SARIF}" ]]; then
	echo "No SARIF report at ${SARIF}; skipping chunk."
	exit 0
fi

# Discover findings up front from both sources before touching the
# chunk directory:
#   1. SARIF linters with non-empty `.results` in megalinter-report.sarif.
#   2. ERROR logs at linters_logs/*-ERROR.log not already represented
#      in a per-linter SARIF (those would be double-reported).
# If both sources are empty we announce that plainly and leave no
# llm-sarif/ behind — including a stale one from a previous run.
# Capture via $(...) rather than `mapfile < <(...)` so a failing jq
# (e.g., malformed SARIF) propagates under `set -e` instead of being
# silently swallowed by the process substitution.
sarif_linter_names=$(
	jq -r '.runs[] | select((.results // []) | length > 0) | .tool.driver.name' \
		"${SARIF}" | sort -u
)
sarif_linters=()
if [[ -n "${sarif_linter_names}" ]]; then
	mapfile -t sarif_linters <<<"${sarif_linter_names}"
fi

log_linters=()
shopt -s nullglob
for logfile in "${REPORT_DIR}/linters_logs"/*-ERROR.log; do
	linter_key=$(basename "${logfile}" | sed 's/-ERROR\.log$//')
	if [[ -f "${REPORT_DIR}/sarif/${linter_key}.sarif" ]]; then
		continue
	fi
	log_linters+=("${linter_key}")
done
shopt -u nullglob

if [[ ${#sarif_linters[@]} -eq 0 && ${#log_linters[@]} -eq 0 ]]; then
	rm -rf "${CHUNK_DIR}"
	echo "No findings discovered."
	exit 0
fi

echo "Splitting SARIF report into per-linter chunks..."
rm -rf "${CHUNK_DIR}"
mkdir -p "${CHUNK_DIR}"
cp "${SCRIPT_DIR}/templates/megalinter-agents.md" "${CHUNK_DIR}/AGENTS.md"

for linter in "${sarif_linters[@]}"; do
	echo "  Processing ${linter}..."
	outname=$(echo "${linter}" | sed 's/.*(MegaLinter \([^)]*\)).*/\1/' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
	jq -r --arg linter "${linter}" -f "${SCRIPT_DIR}/sarif-to-markdown.jq" \
		"${SARIF}" >"${CHUNK_DIR}/${outname}.md"
done

if ((${#log_linters[@]} > 0)); then
	echo "Processing non-SARIF error logs..."
	for linter_key in "${log_linters[@]}"; do
		logfile="${REPORT_DIR}/linters_logs/${linter_key}-ERROR.log"
		outname=$(echo "${linter_key}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
		description=$(head -1 "${logfile}")
		docs_url=$(sed -n '2p' "${logfile}")
		{
			printf '# Linter: %s (from log)\n\n' "${linter_key}"
			printf '**Source:** Log file (no SARIF output available for this linter)\n\n'
			printf -- '%s\n' "${description}"
			printf -- '%s\n\n' "${docs_url}"
			printf -- '---\n\n'
			sed '1,/^-\{3,\}/d' "${logfile}"
		} >"${CHUNK_DIR}/${outname}.md"
		echo "  Processing ${linter_key} (from log)..."
	done
fi

echo "Chunked reports written to ${CHUNK_DIR}:"
echo "Files created:"
find "${CHUNK_DIR}" -maxdepth 1 -type f -printf '%f\n' | sort | sed 's/^/  - /'
