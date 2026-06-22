#!/usr/bin/env bats
# Tests for .taskfiles/scripts/megalint-verify.sh
#
# The verify script uses a mixed verification strategy:
#   - cosign verify-attestation for vuln scan + repo scan + SBOM (hard-fail, 3 calls)
#   - gh attestation verify for SLSA provenance (1 call)
# The release pipeline signs cosign attestations without a Rekor tlog entry
# (TSA timestamp only), so every verify-attestation call must pass
# --insecure-ignore-tlog=true --use-signed-timestamps.
# Tests stub both tools to validate all code paths.

setup() {
  BATS_TEST_TMPDIR="$(mktemp -d)"
  export BATS_TEST_TMPDIR

  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  VERIFY="${REPO_ROOT}/.taskfiles/scripts/megalint-verify.sh"

  # Stub directory — both cosign and gh stubs live here
  STUB_DIR="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_DIR}"

  # Stub cosign: records calls, exits based on STUB_COSIGN_EXIT
  cat > "${STUB_DIR}/cosign" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${COSIGN_CALLS_FILE}"
exit "${STUB_COSIGN_EXIT:-0}"
STUB
  chmod +x "${STUB_DIR}/cosign"
  export COSIGN_CALLS_FILE="${BATS_TEST_TMPDIR}/cosign-calls"
  export STUB_COSIGN_EXIT=0

  # Stub gh: records calls, exits based on STUB_GH_EXIT
  cat > "${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit "${STUB_GH_EXIT:-0}"
STUB
  chmod +x "${STUB_DIR}/gh"
  export GH_CALLS_FILE="${BATS_TEST_TMPDIR}/gh-calls"
  export STUB_GH_EXIT=0

  # Ensure no real cosign/gh interferes
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
  [ ! -f "${GH_CALLS_FILE}" ]
}

# --- cosign not found ---

@test "cosign missing + trevor-vaughan image = hard fail" {
  export PATH="/usr/bin:/bin"  # no stub cosign or gh
  run bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cosign"* ]]
}

@test "cosign missing + third-party image = warn and pass" {
  export PATH="/usr/bin:/bin"  # no stub cosign or gh
  run bash "${VERIFY}" "ghcr.io/oxsecurity/megalinter:v9"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cosign"* ]]
}

# --- cosign + gh available, all pass ---

@test "all attestations pass for trevor-vaughan image (cosign + gh)" {
  run bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 0 ]
  # 3 cosign calls (2 hard-fail: vuln + repo scan, 1 warn-only: SBOM)
  [ "$(wc -l < "${COSIGN_CALLS_FILE}")" -eq 3 ]
  # 1 gh call (SLSA provenance)
  [ "$(wc -l < "${GH_CALLS_FILE}")" -eq 1 ]
}

# --- cosign available, gh missing — SLSA skipped gracefully ---

@test "gh missing = SLSA provenance skipped, cosign attestations still checked" {
  # Remove gh stub; restrict PATH so no gh is found anywhere
  rm "${STUB_DIR}/gh"
  local SAFE_DIR="${BATS_TEST_TMPDIR}/safe-bin"
  mkdir -p "${SAFE_DIR}"
  for cmd in bash env wc cat; do
    ln -sf "$(command -v "${cmd}")" "${SAFE_DIR}/${cmd}"
  done
  # Use env to set PATH only for the subshell (avoids leaking into teardown)
  run env PATH="${STUB_DIR}:${SAFE_DIR}" bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 0 ]
  # 3 cosign calls still happen (2 hard-fail + 1 warn-only)
  [ "$(wc -l < "${COSIGN_CALLS_FILE}")" -eq 3 ]
  # SLSA skipped, not failed
  [[ "$output" == *"SKIP"*"SLSA"* ]]
  [[ "$output" != *"FAIL"*"SLSA"* ]]
}

# --- cosign available, all cosign calls fail ---

@test "attestation failure + trevor-vaughan image = hard fail" {
  export STUB_COSIGN_EXIT=1
  run bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 1 ]
  # All three cosign attestations now hard-fail (vuln, repo scan, SBOM)
  echo "$output" | grep -q "FAIL.*Vulnerability scan"
  echo "$output" | grep -q "FAIL.*Repository scan"
  echo "$output" | grep -q "FAIL.*SBOM"
}

@test "attestation failure + third-party image = warn and pass" {
  export STUB_COSIGN_EXIT=1
  run bash "${VERIFY}" "ghcr.io/oxsecurity/megalinter:v9"
  [ "$status" -eq 0 ]
}

# --- SBOM is hard-fail (no longer warn-only) ---

@test "SBOM failure blocks verification for trevor-vaughan image" {
  # Use a smarter cosign stub that fails only for SBOM predicate type
  cat > "${STUB_DIR}/cosign" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${COSIGN_CALLS_FILE}"
# Fail if this call is for the SBOM predicate type
for arg in "$@"; do
  if [[ "${arg}" == *"spdx.dev"* ]]; then
    exit 1
  fi
done
exit 0
STUB
  chmod +x "${STUB_DIR}/cosign"
  run bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"SBOM"* ]]
  [[ "$output" == *"PASS"*"Vulnerability scan"* ]]
  [[ "$output" == *"PASS"*"Repository scan"* ]]
}

# --- cosign verify flags match the no-Rekor (TSA-only) signing config ---

@test "every cosign verify-attestation call ignores tlog and uses signed timestamps" {
  run bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 0 ]
  [ -f "${COSIGN_CALLS_FILE}" ]
  # Every recorded cosign call must carry both flags — otherwise keyless
  # leaf-certificate verification fails against TSA-timestamped attestations.
  while IFS= read -r line; do
    [[ "${line}" == *"--insecure-ignore-tlog=true"* ]] || {
      echo "missing --insecure-ignore-tlog in: ${line}"
      return 1
    }
    [[ "${line}" == *"--use-signed-timestamps"* ]] || {
      echo "missing --use-signed-timestamps in: ${line}"
      return 1
    }
  done < "${COSIGN_CALLS_FILE}"
}

# --- gh attestation verify failure ---

@test "gh attestation failure + trevor-vaughan image = hard fail" {
  export STUB_GH_EXIT=1
  run bash "${VERIFY}" "ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"SLSA"* ]]
}

@test "gh attestation failure + third-party image = warn and pass" {
  export STUB_GH_EXIT=1
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
