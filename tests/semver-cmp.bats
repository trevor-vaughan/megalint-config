#!/usr/bin/env bats
# Tests for the semver §11 precedence comparator in release-bump.sh.
#
# Sourced with RELEASE_BUMP_LIB_ONLY=1 so the script defines its functions and
# returns without running any release logic.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  # shellcheck disable=SC1090
  RELEASE_BUMP_LIB_ONLY=1 source "${REPO_ROOT}/.taskfiles/scripts/release-bump.sh"
  # The script sets `-euo pipefail` for its own use. Sourcing leaks those into
  # the test shell, where `-u` trips bats' own bookkeeping and `-e` aborts the
  # test on the first non-zero status `run` is meant to capture.
  set +eu
}

# Assert that $1 sorts strictly before $2.
assert_lt() {
  run is_greater "$1" "$2"
  [ "$status" -eq 0 ] || {
    echo "expected ${1} < ${2}" >&2
    return 1
  }
  run is_greater "$2" "$1"
  [ "$status" -ne 0 ] || {
    echo "expected NOT ${2} < ${1}" >&2
    return 1
  }
}

@test "numeric core: patch, minor, major" {
  assert_lt 0.5.0 0.5.1
  assert_lt 0.5.9 0.6.0
  assert_lt 0.9.9 1.0.0
}

@test "numeric core compares numerically, not lexically" {
  assert_lt 0.9.0 0.10.0
  assert_lt 0.1.9 0.1.10
  assert_lt 9.0.0 10.0.0
}

@test "a pre-release is lower than the same version without one" {
  assert_lt 1.0.0-alpha 1.0.0
  assert_lt 1.0.0-rc.1 1.0.0
}

@test "pre-release identifiers compare in ASCII order" {
  assert_lt 1.0.0-alpha 1.0.0-beta
  assert_lt 1.0.0-beta 1.0.0-rc.1
  assert_lt 1.0.0-a.1 1.0.0-b.1
}

@test "numeric pre-release identifiers compare numerically" {
  assert_lt 1.0.0-rc.9 1.0.0-rc.10
  assert_lt 1.0.0-alpha.1 1.0.0-alpha.2
}

@test "numeric identifiers rank below alphanumeric ones" {
  assert_lt 1.0.0-1 1.0.0-alpha
}

@test "a longer identifier list wins when shared segments are equal" {
  assert_lt 1.0.0-alpha 1.0.0-alpha.1
}

@test "the full semver spec example ordering holds" {
  assert_lt 1.0.0-alpha 1.0.0-alpha.1
  assert_lt 1.0.0-alpha.1 1.0.0-alpha.beta
  assert_lt 1.0.0-alpha.beta 1.0.0-beta
  assert_lt 1.0.0-beta 1.0.0-beta.2
  assert_lt 1.0.0-beta.2 1.0.0-beta.11
  assert_lt 1.0.0-beta.11 1.0.0-rc.1
  assert_lt 1.0.0-rc.1 1.0.0
}

@test "patch_bump increments the patch of a stable version" {
  [ "$(patch_bump 0.5.0)" = "0.5.1" ]
  [ "$(patch_bump 1.2.9)" = "1.2.10" ]
}

@test "patch_bump finalises a pre-release instead of moving the patch" {
  [ "$(patch_bump 0.6.0-rc.1)" = "0.6.0" ]
  [ "$(patch_bump 0.6.0-alpha)" = "0.6.0" ]
}

@test "equal versions are not greater in either direction" {
  run is_greater 1.2.3 1.2.3
  [ "$status" -ne 0 ]
  run is_greater 1.2.3-rc.1 1.2.3-rc.1
  [ "$status" -ne 0 ]
}

@test "the four orderings sort -V gets wrong" {
  # sort -V puts 1.0.0 before 1.0.0-alpha and 1.0.0-rc1 before 1.0.0-rc.1.
  assert_lt 1.0.0-alpha 1.0.0
  assert_lt 1.0.0-rc1 1.0.0
  assert_lt 1.0.0-rc.1 1.0.0-rc1
  assert_lt 1.0.0-beta 1.0.0
}
