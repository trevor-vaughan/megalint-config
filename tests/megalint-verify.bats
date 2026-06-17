#!/usr/bin/env bats
# Tests for .taskfiles/scripts/megalint-verify.sh

setup() {
  BATS_TEST_TMPDIR="$(mktemp -d)"
  export BATS_TEST_TMPDIR

  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  VERIFY="${REPO_ROOT}/.taskfiles/scripts/megalint-verify.sh"

  # Stub cosign: records calls, exits based on STUB_COSIGN_EXIT
  STUB_DIR="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_DIR}"
  cat > "${STUB_DIR}/cosign" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${COSIGN_CALLS_FILE}"
exit "${STUB_COSIGN_EXIT:-0}"
STUB
  chmod +x "${STUB_DIR}/cosign"
  export COSIGN_CALLS_FILE="${BATS_TEST_TMPDIR}/cosign-calls"
  export STUB_COSIGN_EXIT=0

  # Ensure no real cosign interferes
  export PATH="${STUB_DIR}:${PATH}"
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}"
  unset MEGALINT_VERIFY MEGALINT_VERIFY_STRICT
}

# --- MEGALINT_VERIFY=skip ---

@test "MEGALINT_VERIFY=skip bypasses verification entirely" {
  export MEGALINT_VERIFY=skip
  run bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
  [ ! -f "${COSIGN_CALLS_FILE}" ]
}

# --- cosign not found ---

@test "cosign missing + trevor-vaughan image = hard fail" {
  export PATH="/usr/bin:/bin"  # no stub cosign
  run bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cosign"* ]]
}

@test "cosign missing + third-party image = warn and pass" {
  export PATH="/usr/bin:/bin"  # no stub cosign
  run bash "${VERIFY}" "ghcr.io/oxsecurity/megalinter:v9"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cosign"* ]]
}

# --- cosign available, all pass ---

@test "all 4 attestations pass for trevor-vaughan image" {
  run bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 0 ]
  # Should have called cosign 4 times (one per attestation type)
  [ "$(wc -l < "${COSIGN_CALLS_FILE}")" -eq 4 ]
}

# --- cosign available, one fails ---

@test "attestation failure + trevor-vaughan image = hard fail" {
  export STUB_COSIGN_EXIT=1
  run bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 1 ]
}

@test "attestation failure + third-party image = warn and pass" {
  export STUB_COSIGN_EXIT=1
  run bash "${VERIFY}" "ghcr.io/oxsecurity/megalinter:v9"
  [ "$status" -eq 0 ]
}

# --- MEGALINT_VERIFY_STRICT ---

@test "MEGALINT_VERIFY_STRICT=true + attestation failure + third-party image = hard fail" {
  export MEGALINT_VERIFY_STRICT=true
  export STUB_COSIGN_EXIT=1
  run bash "${VERIFY}" "ghcr.io/oxsecurity/megalinter:v9"
  [ "$status" -eq 1 ]
}

# --- Argument validation ---

@test "missing image argument = error" {
  run bash "${VERIFY}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}
