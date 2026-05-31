#!/usr/bin/env bats
# Tests for scripts/compute-release-version.sh

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  SCRIPT="${REPO_ROOT}/scripts/compute-release-version.sh"
  export SCRIPT
}

# Extract the value of a single emitted key from $output (exact line match).
value_of() {
  printf '%s\n' "$output" | grep "^$1=" | cut -d= -f2-
}

@test "release tag: composite, moves latest, creates release" {
  REF_NAME="v0.1.0" UPSTREAM_VERSION="9.5.0" run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(value_of release_version)" = "0.1.0" ]
  [ "$(value_of is_prerelease)" = "false" ]
  [ "$(value_of composite)" = "0.1.0-ml9.5.0" ]
  [ "$(value_of move_latest)" = "true" ]
  [ "$(value_of create_release)" = "true" ]
}

@test "prerelease tag: composite, does NOT move latest, creates release" {
  REF_NAME="v0.1.0-rc1" UPSTREAM_VERSION="9.5.0" run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(value_of release_version)" = "0.1.0-rc1" ]
  [ "$(value_of is_prerelease)" = "true" ]
  [ "$(value_of composite)" = "0.1.0-rc1-ml9.5.0" ]
  [ "$(value_of move_latest)" = "false" ]
  [ "$(value_of create_release)" = "true" ]
}

@test "refresh lane (empty ref): moves latest, no release, empty composite" {
  REF_NAME="" UPSTREAM_VERSION="9.5.0" run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(value_of composite)" = "" ]
  [ "$(value_of release_version)" = "" ]
  [ "$(value_of is_prerelease)" = "false" ]
  [ "$(value_of move_latest)" = "true" ]
  [ "$(value_of create_release)" = "false" ]
}

@test "malformed tag v1.0 exits non-zero" {
  REF_NAME="v1.0" UPSTREAM_VERSION="9.5.0" run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
}

@test "tag without leading v exits non-zero" {
  REF_NAME="1.0.0" UPSTREAM_VERSION="9.5.0" run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
}

@test "non-numeric tag exits non-zero" {
  REF_NAME="vabc" UPSTREAM_VERSION="9.5.0" run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
}

@test "four-component tag exits non-zero" {
  REF_NAME="v1.0.0.0" UPSTREAM_VERSION="9.5.0" run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
}

@test "invalid upstream version exits non-zero" {
  REF_NAME="v0.1.0" UPSTREAM_VERSION="v9" run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
}
