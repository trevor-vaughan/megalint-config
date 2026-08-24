#!/usr/bin/env bats
# Tests for .taskfiles/scripts/release-bump.sh
#
# Each test builds a throwaway git repository with a pyproject.toml and a
# stub git-cliff, so nothing here touches the real checkout or the network.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  SCRIPT="${REPO_ROOT}/.taskfiles/scripts/release-bump.sh"
  export SCRIPT

  # Never let the caller's git identity or config reach these repositories.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME="megalint-config tests"
  export GIT_AUTHOR_EMAIL="megalint-config@invalid"
  export GIT_COMMITTER_NAME="megalint-config tests"
  export GIT_COMMITTER_EMAIL="megalint-config@invalid"

  ROOT_DIR="${BATS_TEST_TMPDIR}/repo"
  export ROOT_DIR
  mkdir -p "${ROOT_DIR}"
  git -C "${ROOT_DIR}" init -q -b main

  cat >"${ROOT_DIR}/pyproject.toml" <<'EOF'
[project]
name = "megalinter-shared-config"
version = "0.5.0"
requires-python = ">=3.10"
dependencies = []
EOF
  cp "${REPO_ROOT}/cliff.toml" "${ROOT_DIR}/cliff.toml"
  printf '# Changelog\n' >"${ROOT_DIR}/CHANGELOG.md"

  git -C "${ROOT_DIR}" add pyproject.toml cliff.toml CHANGELOG.md
  git -C "${ROOT_DIR}" commit -qm "feat: initial"
  git -C "${ROOT_DIR}" tag -a v0.5.0 -m v0.5.0

  # Stub git-cliff: writes a fixed changelog, and answers --bumped-version
  # with whatever STUB_BUMPED_VERSION says.
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  export STUB_BIN
  mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/git-cliff" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
tag=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in
    --bumped-version)
      printf '%s\n' "${STUB_BUMPED_VERSION:-v0.5.1}"
      exit 0
      ;;
    --output) j=$((i + 1)); out="${!j}" ;;
    --tag) j=$((i + 1)); tag="${!j}" ;;
  esac
done
if [[ -n "${out}" ]]; then
  printf '# Changelog\n\n## [%s] - 2026-08-24\n\n### Features\n\n- Stub entry\n' \
    "${tag#v}" >"${out}"
fi
EOF
  chmod +x "${STUB_BIN}/git-cliff"
  GIT_CLIFF="${STUB_BIN}/git-cliff"
  export GIT_CLIFF
}

# Current version recorded in the scratch repository's pyproject.toml.
current_version() {
  grep -E '^version = ' "${ROOT_DIR}/pyproject.toml" | cut -d'"' -f2
}

# Assert the scratch repository was not modified at all.
assert_untouched() {
  run git -C "${ROOT_DIR}" status --porcelain
  [ -z "$output" ]
  run git -C "${ROOT_DIR}" tag --list
  [ "$output" = "v0.5.0" ]
  [ "$(current_version)" = "0.5.0" ]
}

@test "explicit stable version bumps files, commits and tags" {
  run bash "${SCRIPT}" 0.6.0
  [ "$status" -eq 0 ]
  [ "$(current_version)" = "0.6.0" ]
  run git -C "${ROOT_DIR}" tag --list
  [[ "$output" == *"v0.6.0"* ]]
  run git -C "${ROOT_DIR}" log -1 --format=%s
  [ "$output" = "chore(release): v0.6.0" ]
  run git -C "${ROOT_DIR}" status --porcelain
  [ -z "$output" ]
}

@test "the release commit contains pyproject, lock and changelog" {
  run bash "${SCRIPT}" 0.6.0
  [ "$status" -eq 0 ]
  run git -C "${ROOT_DIR}" show --name-only --format= HEAD
  [[ "$output" == *"pyproject.toml"* ]]
  [[ "$output" == *"CHANGELOG.md"* ]]
  [[ "$output" == *"uv.lock"* ]]
}

@test "pre-release argument tags semver but stores PEP 440" {
  run bash "${SCRIPT}" 0.6.0-rc1
  [ "$status" -eq 0 ]
  [ "$(current_version)" = "0.6.0rc1" ]
  run git -C "${ROOT_DIR}" tag --list
  [[ "$output" == *"v0.6.0-rc1"* ]]
}

@test "prompt default is the git-cliff suggestion" {
  run bash -c "printf '\n' | STUB_BUMPED_VERSION=v0.5.1 bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ "$(current_version)" = "0.5.1" ]
}

@test "prompt accepts an explicit answer over the suggestion" {
  run bash -c "printf '0.7.0\n' | STUB_BUMPED_VERSION=v0.5.1 bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ "$(current_version)" = "0.7.0" ]
}

@test "suggests a patch bump when no release tag exists" {
  git -C "${ROOT_DIR}" tag -d v0.5.0
  run bash -c "printf '\n' | bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ "$(current_version)" = "0.5.1" ]
  [[ "$output" == *"no v* release tag found"* ]]
}

@test "suggests a patch bump when the tag disagrees with the version" {
  git -C "${ROOT_DIR}" tag -a v0.4.0 -m v0.4.0
  git -C "${ROOT_DIR}" tag -d v0.5.0
  run bash -c "printf '\n' | bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ "$(current_version)" = "0.5.1" ]
  [[ "$output" == *"does not match"* ]]
}

@test "suggests a patch bump when nothing is releasable" {
  # git-cliff echoes the tag back when there is nothing to release.
  run bash -c "printf '\n' | STUB_BUMPED_VERSION=v0.5.0 bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ "$(current_version)" = "0.5.1" ]
  [[ "$output" == *"no releasable commits"* ]]
}

@test "refuses a dirty working tree and changes nothing" {
  printf 'dirty\n' >>"${ROOT_DIR}/pyproject.toml"
  run bash "${SCRIPT}" 0.6.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
  run git -C "${ROOT_DIR}" tag --list
  [ "$output" = "v0.5.0" ]
}

@test "refuses a staged change and changes nothing" {
  printf 'x\n' >"${ROOT_DIR}/extra.txt"
  git -C "${ROOT_DIR}" add extra.txt
  run bash "${SCRIPT}" 0.6.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "refuses a non-semver argument" {
  run bash "${SCRIPT}" not-a-version
  [ "$status" -ne 0 ]
  assert_untouched
}

@test "refuses a version that is not greater" {
  run bash "${SCRIPT}" 0.4.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"not greater"* ]]
  assert_untouched
}

@test "refuses the current version" {
  run bash "${SCRIPT}" 0.5.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"not greater"* ]]
  assert_untouched
}

@test "refuses a version whose tag already exists" {
  git -C "${ROOT_DIR}" tag -a v0.6.0 -m v0.6.0
  run bash "${SCRIPT}" 0.6.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(current_version)" = "0.5.0" ]
}

@test "refuses a PEP 440 form outside the supported vocabulary" {
  run bash "${SCRIPT}" 0.6.0-post1
  [ "$status" -ne 0 ]
  assert_untouched
}

@test "refuses no argument with closed stdin" {
  run bash -c "bash '${SCRIPT}' </dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stdin is closed"* ]]
  assert_untouched
}

@test "refuses to run when git-cliff is missing" {
  GIT_CLIFF="${BATS_TEST_TMPDIR}/absent-git-cliff" run bash "${SCRIPT}" 0.6.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"git-cliff not found"* ]]
  assert_untouched
}

@test "refuses to run without cliff.toml" {
  rm "${ROOT_DIR}/cliff.toml"
  git -C "${ROOT_DIR}" commit -qam "chore: drop cliff config"
  run bash "${SCRIPT}" 0.6.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"cliff.toml"* ]]
}
