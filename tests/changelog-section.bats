#!/usr/bin/env bats
# Tests for .taskfiles/scripts/changelog-section.sh

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  SCRIPT="${REPO_ROOT}/.taskfiles/scripts/changelog-section.sh"
  export SCRIPT

  CHANGELOG="${BATS_TEST_TMPDIR}/CHANGELOG.md"
  export CHANGELOG
  cat >"${CHANGELOG}" <<'EOF'
# Changelog

Preamble text that belongs to no release.

## [0.3.0] - 2026-08-01

### Features

- Third feature

## [0.2.0] - 2026-07-01

### Bug Fixes

- Second fix

## [0.1.0-rc1] - 2026-06-02

### Features

- Release candidate only

## [0.1.0] - 2026-06-01

### Features

- First feature
EOF
}

# bats collapses blank entries out of the `lines` array, so structure is
# asserted against "$output" as a whole. That is the stronger check anyway: it
# pins the interior blank line *and* the absence of leading/trailing ones.

@test "extracts the newest section" {
  run bash "${SCRIPT}" 0.3.0 "${CHANGELOG}"
  [ "$status" -eq 0 ]
  [ "$output" = "### Features

- Third feature" ]
}

@test "extracts a middle section" {
  run bash "${SCRIPT}" 0.2.0 "${CHANGELOG}"
  [ "$status" -eq 0 ]
  [ "$output" = "### Bug Fixes

- Second fix" ]
}

@test "extracts the oldest section without trailing blank lines" {
  run bash "${SCRIPT}" 0.1.0 "${CHANGELOG}"
  [ "$status" -eq 0 ]
  [ "$output" = "### Features

- First feature" ]
}

@test "a stable version does not match a pre-release of the same number" {
  run bash "${SCRIPT}" 0.1.0 "${CHANGELOG}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Release candidate only"* ]]
}

@test "extracts a pre-release section" {
  run bash "${SCRIPT}" 0.1.0-rc1 "${CHANGELOG}"
  [ "$status" -eq 0 ]
  [ "$output" = "### Features

- Release candidate only" ]
}

@test "unknown version exits 1" {
  run bash "${SCRIPT}" 9.9.9 "${CHANGELOG}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no section for version 9.9.9"* ]]
}

@test "missing changelog exits 1" {
  run bash "${SCRIPT}" 0.1.0 "${BATS_TEST_TMPDIR}/absent.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "missing version argument exits non-zero" {
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
}
