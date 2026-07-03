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

@test "runner accepts 7 args (with config_file)" {
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none" \
    "never" \
    ".mega-linter-custom.yml"

  [ "$status" -eq 0 ]
  grep -qE '^MEGALINTER_CONFIG=\.mega-linter-custom\.yml$' "${ENGINE_ARGS_FILE}"
}

@test "runner rejects 8+ args" {
  run bash "${RUNNER}" a b c d e f g h
  [ "$status" -eq 2 ]
}

# Regression: Checkov 3.x's Github.setup_conf_dir() ignores
# CKV_GITHUB_CONF_DIR_PATH and computes the path as os.path.join(os.getcwd(),
# CKV_GITHUB_CONF_DIR_NAME). On a read-only workspace mount that lands the
# directory on `/tmp/lint/github_conf` and crashes with EROFS. Passing
# CKV_GITHUB_CONF_DIR_NAME as an absolute path exploits POSIX os.path.join
# semantics to redirect the directory onto the writable tmpfs.
@test "runner forwards CKV_GITHUB_CONF_DIR_NAME=/tmp/checkov-github-conf when apply_fixes=none" {
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none"

  [ "$status" -eq 0 ]
  grep -qE '^CKV_GITHUB_CONF_DIR_NAME=/tmp/checkov-github-conf$' "${ENGINE_ARGS_FILE}"
  # The PATH variant is a no-op (Checkov overwrites it); ensure we are not
  # advertising a knob that does nothing.
  ! grep -qE '^CKV_GITHUB_CONF_DIR_PATH=' "${ENGINE_ARGS_FILE}"
}

@test "runner skips Checkov tmpfs env vars when apply_fixes=all (rw mount)" {
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "all"

  [ "$status" -eq 0 ]
  ! grep -qE '^CKV_GITHUB_CONF_DIR_NAME=' "${ENGINE_ARGS_FILE}"
  ! grep -qE '^CKV_GITHUB_CONF_DIR_PATH=' "${ENGINE_ARGS_FILE}"
}

@test "config_file takes precedence over .mega-linter.local.yml" {
  touch "${TARGET}/.mega-linter.local.yml"
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none" \
    "never" \
    ".mega-linter-changed.yml"

  [ "$status" -eq 0 ]
  # Only one MEGALINTER_CONFIG should appear (the explicit one, not local.yml)
  local count
  count=$(grep -c '^MEGALINTER_CONFIG=' "${ENGINE_ARGS_FILE}" || true)
  [ "$count" -eq 1 ]
  grep -qE '^MEGALINTER_CONFIG=\.mega-linter-changed\.yml$' "${ENGINE_ARGS_FILE}"
}

@test "handles empty CONFIG_FILE parameter correctly" {
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none" \
    "never" \
    ""

  [ "$status" -eq 0 ]
  ! grep -qE '^MEGALINTER_CONFIG=' "${ENGINE_ARGS_FILE}"
}

@test "runner forwards DISABLE_LINTERS env var to container" {
  DISABLE_LINTERS="REPOSITORY_CHECKOV,REPOSITORY_TRIVY" \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none"

  [ "$status" -eq 0 ]
  grep -qE '^DISABLE_LINTERS=REPOSITORY_CHECKOV,REPOSITORY_TRIVY$' "${ENGINE_ARGS_FILE}"
}

@test "runner accepts 6 args (pull_policy, no config_file)" {
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none" \
    "always"

  [ "$status" -eq 0 ]
  grep -qE '^--pull=always$' "${ENGINE_ARGS_FILE}"
  ! grep -qE '^MEGALINTER_CONFIG=' "${ENGINE_ARGS_FILE}"
}

@test "runner prints diagnostic when VALIDATE_ALL_CODEBASE=false requires git write access" {
  # Create a .git directory to trigger git mount behavior
  mkdir -p "${TARGET}/.git"
  
  # Create a stub rsync that just succeeds (for tempdir staging)
  cat > "${STUB_DIR}/rsync" <<'EOF'
#!/usr/bin/env bash
# Stub rsync that does nothing but succeed
exit 0
EOF
  chmod +x "${STUB_DIR}/rsync"
  PATH="${STUB_DIR}:${PATH}"
  
  # Enable tempdir staging and set VALIDATE_ALL_CODEBASE=false
  MEGALINT_TMPDIR=1 VALIDATE_ALL_CODEBASE=false \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none"

  [ "$status" -eq 0 ]
  # Should print diagnostic message about git mount
  [[ "$output" =~ "Mounting .git read-write for git diff operations" ]]
  # Should mount .git read-write (rw) not read-only (ro)
  grep -qE '\.git:/tmp/lint/\.git:rw,z$' "${ENGINE_ARGS_FILE}"
  ! grep -qE '\.git:/tmp/lint/\.git:ro,z$' "${ENGINE_ARGS_FILE}"
}

@test "runner mounts .git read-only when VALIDATE_ALL_CODEBASE is not false" {
  # Create a .git directory to trigger git mount behavior  
  mkdir -p "${TARGET}/.git"
  
  # Create a stub rsync that just succeeds (for tempdir staging)
  cat > "${STUB_DIR}/rsync" <<'EOF'
#!/usr/bin/env bash
# Stub rsync that does nothing but succeed
exit 0
EOF
  chmod +x "${STUB_DIR}/rsync"
  PATH="${STUB_DIR}:${PATH}"
  
  # Enable tempdir staging but leave VALIDATE_ALL_CODEBASE at default (true)
  MEGALINT_TMPDIR=1 \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none"

  [ "$status" -eq 0 ]
  # Should NOT print the diagnostic message
  ! [[ "$output" =~ "Mounting .git read-write for git diff operations" ]]
  # Should mount .git read-only (ro) not read-write (rw)
  grep -qE '\.git:/tmp/lint/\.git:ro,z$' "${ENGINE_ARGS_FILE}"
  ! grep -qE '\.git:/tmp/lint/\.git:rw,z$' "${ENGINE_ARGS_FILE}"
}

@test "runner skips git mount when no .git directory exists" {
  # Create a stub rsync that just succeeds (for tempdir staging)
  cat > "${STUB_DIR}/rsync" <<'EOF'
#!/usr/bin/env bash
# Stub rsync that does nothing but succeed
exit 0
EOF
  chmod +x "${STUB_DIR}/rsync"
  PATH="${STUB_DIR}:${PATH}"
  
  # Do NOT create .git directory
  MEGALINT_TMPDIR=1 VALIDATE_ALL_CODEBASE=false \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none"

  [ "$status" -eq 0 ]
  # Should not mount .git at all
  ! grep -qE '\.git:/tmp/lint/\.git:' "${ENGINE_ARGS_FILE}"
}

@test "runner works in in-target staging mode with VALIDATE_ALL_CODEBASE=false" {
  # Create a .git directory to trigger git mount behavior
  mkdir -p "${TARGET}/.git"
  
  # Use in-target staging (no MEGALINT_TMPDIR)
  VALIDATE_ALL_CODEBASE=false \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none"

  [ "$status" -eq 0 ]
  # In-target changed-files mode overlays a nested rw .git mount so MegaLinter
  # can write .git/FETCH_HEAD during git fetch (see megalint-run.sh).
  grep -qE '\.git:/tmp/lint/\.git:rw,z$' "${ENGINE_ARGS_FILE}"
  ! grep -qE '\.git:/tmp/lint/\.git:ro,z$' "${ENGINE_ARGS_FILE}"
}

@test "tempdir mode warns (does not silently swallow) when report persist fails" {
  cat > "${STUB_DIR}/rsync" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${STUB_DIR}/rsync"
  PATH="${STUB_DIR}:${PATH}"

  # Make the target unwritable so the cleanup cp/rm cannot persist reports.
  chmod 500 "${TARGET}"

  MEGALINT_TMPDIR=1 \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" \
    "fake/image:latest" "none"

  chmod 700 "${TARGET}"  # restore so teardown can clean up
  [[ "$output" == *"WARNING"* && "$output" == *"persist"* ]]
}

@test "tempdir staging refuses APPLY_FIXES (fixes would be discarded)" {
  cat > "${STUB_DIR}/rsync" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${STUB_DIR}/rsync"
  PATH="${STUB_DIR}:${PATH}"

  MEGALINT_TMPDIR=1 \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" \
    "fake/image:latest" "all"

  [ "$status" -ne 0 ]
  [[ "$output" == *"APPLY_FIXES"* && "$output" == *"MEGALINT_TMPDIR"* ]]
}
