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

# Regression: Checkov's github_configuration framework computes its conf dir
# as os.path.join(os.getcwd(), CKV_GITHUB_CONF_DIR_NAME); on a read-only
# workspace mount that crashes with EROFS. The primary fix is skipping that
# framework in the Checkov config (see test_config_sanity.py); this env var is
# a defence-in-depth backstop that redirects the dir onto the writable tmpfs
# via POSIX os.path.join semantics (absolute second arg wins). It is defeated
# on MegaLinter >= v9.6.0, whose CheckovLinter.before_lint_files() overwrites
# CKV_GITHUB_CONF_DIR_NAME with a relative path, so the config skip carries the
# pinned base image; the runner still forwards it for older images.
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

@test "config_file arg wins over a present .mega-linter.local.yml" {
  # A local override is present, yet the explicit config_file arg must be the
  # single MEGALINTER_CONFIG (runner logs "ignoring .mega-linter.local.yml").
  touch "${TARGET}/.mega-linter.local.yml"
  run bash "${RUNNER}" \
    "${REPO_ROOT}" \
    "${TARGET}" \
    "${STUB_DIR}/fake-engine" \
    "fake/image:latest" \
    "none" \
    "never" \
    ".mega-linter-custom.yml"

  [ "$status" -eq 0 ]
  local count
  count=$(grep -c '^MEGALINTER_CONFIG=' "${ENGINE_ARGS_FILE}" || true)
  [ "$count" -eq 1 ]
  grep -qE '^MEGALINTER_CONFIG=\.mega-linter-custom\.yml$' "${ENGINE_ARGS_FILE}"
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

@test "runner forwards a MEGALINT_EXTRA_ENV_VARS name that is set" {
  MEGALINT_EXTRA_ENV_VARS="GOPROXY" GOPROXY="https://proxy.example/mod" \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" \
    "fake/image:latest" "none"

  [ "$status" -eq 0 ]
  grep -qE '^GOPROXY=https://proxy\.example/mod$' "${ENGINE_ARGS_FILE}"
}

@test "runner does not forward a listed extra var that is unset" {
  MEGALINT_EXTRA_ENV_VARS="GOPROXY" \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" \
    "fake/image:latest" "none"

  [ "$status" -eq 0 ]
  ! grep -qE '^GOPROXY=' "${ENGINE_ARGS_FILE}"
}

@test "runner handles empty MEGALINT_EXTRA_ENV_VARS as a no-op" {
  MEGALINT_EXTRA_ENV_VARS="   " \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" \
    "fake/image:latest" "none"

  [ "$status" -eq 0 ]
}

@test "runner forwards multiple extra vars with mixed comma/space delimiters" {
  MEGALINT_EXTRA_ENV_VARS="GOPROXY, GONOSUMCHECK" \
  GOPROXY="https://proxy.example/mod" GONOSUMCHECK="1" \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" \
    "fake/image:latest" "none"

  [ "$status" -eq 0 ]
  grep -qE '^GOPROXY=https://proxy\.example/mod$' "${ENGINE_ARGS_FILE}"
  grep -qE '^GONOSUMCHECK=1$' "${ENGINE_ARGS_FILE}"
}

@test "runner skips an invalid MEGALINT_EXTRA_ENV_VARS entry without aborting" {
  MEGALINT_EXTRA_ENV_VARS="GOPROXY=oops, GONOSUMCHECK" GONOSUMCHECK="1" \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" \
    "fake/image:latest" "none"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring invalid"* ]]
  grep -qE '^GONOSUMCHECK=1$' "${ENGINE_ARGS_FILE}"
  ! grep -q 'oops' "${ENGINE_ARGS_FILE}"
}

@test "runner forwards ENABLE_LINTERS when set" {
  ENABLE_LINTERS="BASH_SHELLCHECK,PYTHON_RUFF" \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" \
    "fake/image:latest" "none"

  [ "$status" -eq 0 ]
  grep -qE '^ENABLE_LINTERS=BASH_SHELLCHECK,PYTHON_RUFF$' "${ENGINE_ARGS_FILE}"
}

@test "runner does not forward ENABLE_LINTERS when unset" {
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" \
    "fake/image:latest" "none"

  [ "$status" -eq 0 ]
  ! grep -qE '^ENABLE_LINTERS=' "${ENGINE_ARGS_FILE}"
}

@test "runner logs the ENABLE_LINTERS override when set" {
  ENABLE_LINTERS="BASH_SHELLCHECK,PYTHON_RUFF" \
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" \
    "fake/image:latest" "none"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ENABLE_LINTERS override active: BASH_SHELLCHECK,PYTHON_RUFF"* ]]
}

# --- Changed-run FILTER_REGEX_EXCLUDE injection (excluded-dir workaround) ---

# A fake `uv` that prints a canned regex, standing in for the resolver so these
# tests exercise the runner's wiring, not PyYAML. Selected via MEGALINT_UV.
_make_fake_uv() {  # $1 = string to print (may be empty)
  cat > "${STUB_DIR}/fake-uv" <<EOF
#!/usr/bin/env bash
printf '%s' '${1}'
[ -n '${1}' ] && printf '\n'
exit 0
EOF
  chmod +x "${STUB_DIR}/fake-uv"
  export MEGALINT_UV="${STUB_DIR}/fake-uv"
}

@test "changed run injects FILTER_REGEX_EXCLUDE from the resolver" {
  _make_fake_uv '(^|/)(?:custom-flavor)/'
  VALIDATE_ALL_CODEBASE=false run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" "fake/image:latest" "none"
  [ "$status" -eq 0 ]
  grep -qF 'FILTER_REGEX_EXCLUDE=(^|/)(?:custom-flavor)/' "${ENGINE_ARGS_FILE}"
}

@test "full run does NOT inject FILTER_REGEX_EXCLUDE" {
  _make_fake_uv '(^|/)(?:custom-flavor)/'
  # VALIDATE_ALL_CODEBASE unset -> full run -> resolver not called.
  run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" "fake/image:latest" "none"
  [ "$status" -eq 0 ]
  ! grep -qE '^FILTER_REGEX_EXCLUDE=' "${ENGINE_ARGS_FILE}"
}

@test "changed run with empty resolver output injects nothing" {
  _make_fake_uv ''
  VALIDATE_ALL_CODEBASE=false run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" "fake/image:latest" "none"
  [ "$status" -eq 0 ]
  ! grep -qE '^FILTER_REGEX_EXCLUDE=' "${ENGINE_ARGS_FILE}"
}

@test "changed run fails loudly when uv is absent" {
  export MEGALINT_UV="${BATS_TEST_TMPDIR}/definitely-not-uv"
  VALIDATE_ALL_CODEBASE=false run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" "fake/image:latest" "none"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found on PATH"* ]]
}

# Records the resolver's argv so we can assert entry/base selection per target
# layout. Prints a canned regex so injection still happens.
_make_recording_uv() {
  export UV_ARGS_FILE="${BATS_TEST_TMPDIR}/uv-args"
  cat > "${STUB_DIR}/fake-uv" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${UV_ARGS_FILE}"
printf '(^|/)(?:x)/\n'
EOF
  chmod +x "${STUB_DIR}/fake-uv"
  export MEGALINT_UV="${STUB_DIR}/fake-uv"
}

@test "changed run with a local override resolves staged local as entry and staged shared as base" {
  _make_recording_uv
  printf 'EXTENDS: .mega-linter.shared.yml\n' > "${TARGET}/.mega-linter.local.yml"
  VALIDATE_ALL_CODEBASE=false run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" "fake/image:latest" "none"
  [ "$status" -eq 0 ]
  # In-target mode: workspace == TARGET. Entry = staged local; base = staged shared.
  grep -qF "${TARGET}/.mega-linter.local.yml" "${UV_ARGS_FILE}"
  grep -qF "${TARGET}/.mega-linter.shared.yml" "${UV_ARGS_FILE}"
  grep -qF 'FILTER_REGEX_EXCLUDE=(^|/)(?:x)/' "${ENGINE_ARGS_FILE}"
}

@test "changed run with explicit config_file skips the excluded-dirs workaround" {
  _make_recording_uv
  printf 'ADDITIONAL_EXCLUDED_DIRECTORIES: [foo]\n' > "${TARGET}/.mega-linter-custom.yml"
  VALIDATE_ALL_CODEBASE=false run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" "fake/image:latest" \
    "none" "never" ".mega-linter-custom.yml"
  [ "$status" -eq 0 ]
  # config_file is a full-custom config whose EXTENDS chain we don't resolve, so
  # the workaround is skipped: resolver never invoked, nothing injected (which
  # avoids clobbering a FILTER_REGEX_EXCLUDE the config inherits via EXTENDS).
  [ ! -f "${UV_ARGS_FILE}" ]
  ! grep -qE '^FILTER_REGEX_EXCLUDE=' "${ENGINE_ARGS_FILE}"
}

@test "changed run aborts when the resolver exits non-zero" {
  # Fake uv that fails, simulating a resolver error. set -e + the declaration-
  # split assignment (never `local x=$(...)`) must abort rather than proceed
  # with no exclusion — the silent-false-green mode this feature prevents.
  cat > "${STUB_DIR}/fake-uv" <<'EOF'
#!/usr/bin/env bash
echo "resolver boom" >&2
exit 1
EOF
  chmod +x "${STUB_DIR}/fake-uv"
  export MEGALINT_UV="${STUB_DIR}/fake-uv"
  VALIDATE_ALL_CODEBASE=false run bash "${RUNNER}" \
    "${REPO_ROOT}" "${TARGET}" "${STUB_DIR}/fake-engine" "fake/image:latest" "none"
  [ "$status" -ne 0 ]
  # Aborted before the container ran: the fake engine never wrote its args file.
  [ ! -f "${ENGINE_ARGS_FILE}" ]
}
