#!/usr/bin/env bats
# Tests for .taskfiles/scripts/megalint-relocate-reports.sh

setup() {
  BATS_TEST_TMPDIR="$(mktemp -d)"
  export BATS_TEST_TMPDIR
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  RELOCATE="${REPO_ROOT}/.taskfiles/scripts/megalint-relocate-reports.sh"
  WORKDIR="${BATS_TEST_TMPDIR}/work"
  mkdir -p "${WORKDIR}/megalinter-reports"
  echo "report" > "${WORKDIR}/megalinter-reports/megalinter-report.sarif"
  echo "log" > "${WORKDIR}/mega-linter.log"
}

teardown() { rm -rf "${BATS_TEST_TMPDIR}"; }

@test "moves the log into the default reports dir" {
  run bash "${RELOCATE}" "${WORKDIR}" \
    "${WORKDIR}/megalinter-reports" "${WORKDIR}/megalinter-reports"
  [ "$status" -eq 0 ]
  [ -f "${WORKDIR}/megalinter-reports/mega-linter.log" ]
  [ ! -f "${WORKDIR}/mega-linter.log" ]
}

@test "relocates reports dir to a non-default target" {
  target="${BATS_TEST_TMPDIR}/out/reports"
  run bash "${RELOCATE}" "${WORKDIR}" "${WORKDIR}/megalinter-reports" "${target}"
  [ "$status" -eq 0 ]
  [ -f "${target}/megalinter-report.sarif" ]
  [ ! -d "${WORKDIR}/megalinter-reports" ]
}

@test "no-ops cleanly when reports dir is absent (lint crashed early)" {
  rm -rf "${WORKDIR}/megalinter-reports" "${WORKDIR}/mega-linter.log"
  run bash "${RELOCATE}" "${WORKDIR}" \
    "${WORKDIR}/megalinter-reports" "${BATS_TEST_TMPDIR}/out/reports"
  [ "$status" -eq 0 ]
}
