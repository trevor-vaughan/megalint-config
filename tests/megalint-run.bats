#!/usr/bin/env bats
# Tests for .taskfiles/scripts/megalint-run.sh

setup() {
  BATS_TEST_TMPDIR="$(mktemp -d)"
  export BATS_TEST_TMPDIR

  # Repo root (this file lives at <root>/tests/megalint-run.bats).
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  RUNNER="${REPO_ROOT}/.taskfiles/scripts/megalint-run.sh"

  # Stub engine: writes its args to a file so the test can inspect them.
  STUB_DIR="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_DIR}"
  cat > "${STUB_DIR}/fake-engine" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${ENGINE_ARGS_FILE}"
EOF
  chmod +x "${STUB_DIR}/fake-engine"
  export ENGINE_ARGS_FILE="${BATS_TEST_TMPDIR}/engine-args"

  # Minimal target directory.
  TARGET="${BATS_TEST_TMPDIR}/target"
  mkdir -p "${TARGET}"
  export TARGET
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}"
}

@test "runner forwards pull_policy=missing as --pull=missing to engine" {
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none" \
    "missing"

  [ "$status" -eq 0 ]
  grep -qE '^--pull=missing$' "${ENGINE_ARGS_FILE}"
}

@test "runner defaults pull_policy to never when omitted (5 args)" {
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none"

  [ "$status" -eq 0 ]
  grep -qE '^--pull=never$' "${ENGINE_ARGS_FILE}"
}

@test "runner rejects unknown number of args (0)" {
  run bash "${RUNNER}"
  [ "$status" -eq 2 ]
}

@test "runner rejects 7+ args" {
  run bash "${RUNNER}" a b c d e f g
  [ "$status" -eq 2 ]
}
