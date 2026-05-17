#!/usr/bin/env bats
# Tests for .taskfiles/scripts/megalint-sarif-chunk.sh

setup() {
  BATS_TEST_TMPDIR="$(mktemp -d)"
  export BATS_TEST_TMPDIR

  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  CHUNKER="${REPO_ROOT}/.taskfiles/scripts/megalint-sarif-chunk.sh"

  # Fake repo root with the megalinter-reports/ layout the chunker expects.
  FAKE_ROOT="${BATS_TEST_TMPDIR}/fake-root"
  REPORT_DIR="${FAKE_ROOT}/megalinter-reports"
  mkdir -p "${REPORT_DIR}/linters_logs" "${REPORT_DIR}/sarif"
  export FAKE_ROOT REPORT_DIR
  CHUNK_DIR="${REPORT_DIR}/llm-sarif"
  export CHUNK_DIR
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}"
}

# Write a SARIF file with no findings (runs present, .results empty).
write_empty_sarif() {
  cat > "${REPORT_DIR}/megalinter-report.sarif" <<'EOF'
{
  "version": "2.1.0",
  "runs": [
    {"tool": {"driver": {"name": "Test (MegaLinter shellcheck)"}}, "results": []}
  ]
}
EOF
}

# Write a SARIF file with one finding under a known linter.
write_sarif_with_findings() {
  cat > "${REPORT_DIR}/megalinter-report.sarif" <<'EOF'
{
  "version": "2.1.0",
  "runs": [
    {
      "tool": {"driver": {"name": "Test (MegaLinter shellcheck)"}},
      "results": [
        {
          "ruleId": "SC1234",
          "level": "warning",
          "message": {"text": "test finding"},
          "locations": [
            {"physicalLocation": {"artifactLocation": {"uri": "test.sh"}, "region": {"startLine": 1}}}
          ]
        }
      ]
    }
  ]
}
EOF
}

@test "no findings: prints 'No findings discovered' and creates no llm-sarif/" {
  write_empty_sarif
  run bash "${CHUNKER}" "${FAKE_ROOT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"No findings discovered"* ]]
  [ ! -d "${CHUNK_DIR}" ]
}

@test "no findings: removes stale llm-sarif/ from prior run" {
  write_empty_sarif
  mkdir -p "${CHUNK_DIR}"
  echo "stale" > "${CHUNK_DIR}/AGENTS.md"

  run bash "${CHUNKER}" "${FAKE_ROOT}"

  [ "$status" -eq 0 ]
  [ ! -d "${CHUNK_DIR}" ]
}

@test "has SARIF findings: creates llm-sarif/ with AGENTS.md and per-linter chunk" {
  write_sarif_with_findings
  run bash "${CHUNKER}" "${FAKE_ROOT}"

  [ "$status" -eq 0 ]
  [ -f "${CHUNK_DIR}/AGENTS.md" ]
  [ -f "${CHUNK_DIR}/shellcheck.md" ]
}

@test "has only ERROR log findings: creates llm-sarif/ with log-based chunk" {
  write_empty_sarif
  cat > "${REPORT_DIR}/linters_logs/REPOSITORY_TRIVY-ERROR.log" <<'EOF'
Trivy: vulnerability scanner.
https://aquasecurity.github.io/trivy/
---
CVE-2024-XXXX in some/package
EOF

  run bash "${CHUNKER}" "${FAKE_ROOT}"

  [ "$status" -eq 0 ]
  [ -f "${CHUNK_DIR}/AGENTS.md" ]
  [ -f "${CHUNK_DIR}/repository-trivy.md" ]
}

@test "missing SARIF entirely: prints skip message and exits 0" {
  run bash "${CHUNKER}" "${FAKE_ROOT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"No SARIF report"* ]]
  [ ! -d "${CHUNK_DIR}" ]
}
