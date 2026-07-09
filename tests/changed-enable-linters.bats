#!/usr/bin/env bats
# Tests for .taskfiles/scripts/changed-enable-linters.sh

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  EXTRACT="${REPO_ROOT}/.taskfiles/scripts/changed-enable-linters.sh"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "${TMP}"; }

@test "extractor emits non-repository linters as CSV, drops REPOSITORY_*" {
  cat > "${TMP}/cfg.yml" <<'YAML'
ENABLE_LINTERS:
  - BASH_SHELLCHECK
  - PYTHON_RUFF # with an inline comment
  - REPOSITORY_CHECKOV
  - REPOSITORY_TRIVY
DISABLE_LINTERS:
  - SOMETHING
YAML
  run bash "${EXTRACT}" "${TMP}/cfg.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "BASH_SHELLCHECK,PYTHON_RUFF" ]
}

@test "extractor exits non-zero when no ENABLE_LINTERS block is present" {
  cat > "${TMP}/cfg.yml" <<'YAML'
DISABLE_LINTERS:
  - SOMETHING
YAML
  run bash "${EXTRACT}" "${TMP}/cfg.yml"
  [ "$status" -ne 0 ]
}

@test "extractor exits non-zero when block has only REPOSITORY_* linters" {
  cat > "${TMP}/cfg.yml" <<'YAML'
ENABLE_LINTERS:
  - REPOSITORY_CHECKOV
YAML
  run bash "${EXTRACT}" "${TMP}/cfg.yml"
  [ "$status" -ne 0 ]
}
