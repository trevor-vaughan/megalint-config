#!/usr/bin/env bats
# Tests for cliff.toml's handling of conventional-commit bullets in commit
# bodies.
#
# Squash-merged branches carry their individual changes as a bullet list in the
# commit body rather than as separate commits. These tests pin that each such
# bullet reaches the changelog under the group its own type selects, that its
# sub-bullets follow it, and that the surrounding prose and trailers do not.
#
# Unlike release-bump.bats these run the real git-cliff: the behaviour under
# test *is* cliff.toml, which a stub cannot exercise.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT

  # Never let the caller's git identity or config reach these repositories.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME="megalint-config tests"
  export GIT_AUTHOR_EMAIL="megalint-config@invalid"
  export GIT_COMMITTER_NAME="megalint-config tests"
  export GIT_COMMITTER_EMAIL="megalint-config@invalid"

  GIT_CLIFF="${GIT_CLIFF:-uvx git-cliff@2.13.1}"
  export GIT_CLIFF

  ROOT_DIR="${BATS_TEST_TMPDIR}/repo"
  export ROOT_DIR
  mkdir -p "${ROOT_DIR}"
  git -C "${ROOT_DIR}" init -q -b main
  printf 'seed\n' >"${ROOT_DIR}/seed.txt"
  git -C "${ROOT_DIR}" add seed.txt
  git -C "${ROOT_DIR}" commit -qm "feat: seed the repository"
  git -C "${ROOT_DIR}" tag -a v0.1.0 -m v0.1.0
}

# Commit <message> as the sole unreleased change.
commit_message() {
  printf '%s' "${1}" >"${ROOT_DIR}/msg.txt"
  printf 'change\n' >>"${ROOT_DIR}/seed.txt"
  git -C "${ROOT_DIR}" add seed.txt
  git -C "${ROOT_DIR}" commit -q -F "${ROOT_DIR}/msg.txt"
}

# Render the unreleased section with the project's real cliff.toml.
#
# cliff.toml's postprocessor puts a blank line before every `## [`, which the
# header normally absorbs as the separator between releases. `--strip header`
# leaves it exposed as a leading blank line, so it is dropped here rather than
# written into every expectation.
render() {
  # Unquoted on purpose: the default is the two-word command
  # `uvx git-cliff@2.13.1` and has to split into argv.
  # shellcheck disable=SC2086
  ${GIT_CLIFF} \
    --config "${REPO_ROOT}/cliff.toml" \
    --repository "${ROOT_DIR}" \
    --unreleased --strip header 2>/dev/null | sed '1{/^$/d;}'
}

@test "body bullets are grouped by their own conventional type" {
  commit_message 'feat(release): add release:bump task for cutting releases

`task release:bump` bumps `pyproject.toml` and `uv.lock`, regenerates
`CHANGELOG.md` from the Conventional Commits since the last tag.

- feat(release): add changelog-section.sh to extract one release'"'"'s notes
- ci(release): fail the release when the tag and committed version differ
- test(release): add bats coverage for release-bump.sh

Assisted-by: Nobody <nobody@invalid>
'

  run render
  [ "$status" -eq 0 ]
  [ "$output" = "## [unreleased]

### 🚀 Features

- *(release)* Add release:bump task for cutting releases
- *(release)* Add changelog-section.sh to extract one release's notes

### 🧪 Testing

- *(release)* Add bats coverage for release-bump.sh

### ⚙️ Miscellaneous Tasks

- *(release)* Fail the release when the tag and committed version differ" ]
}

@test "sub-bullets follow their bullet and are unwrapped onto one line" {
  commit_message 'fix: disable updated-sources reporter on read-only runs

- fix(flavor): pin runtime python deps to upstream uv.lock
  - MEGALINTER_VERSION pins the upstream source, not the shipped
    image, so the lock its builder stage consumes never reaches it.
  - The generator now exports the lock to a constraints file.
- docs: document the reporter toggle and uv.lock pinning
'

  run render
  [ "$status" -eq 0 ]
  [ "$output" = "## [unreleased]

### 🐛 Bug Fixes

- Disable updated-sources reporter on read-only runs
- *(flavor)* Pin runtime python deps to upstream uv.lock
  - MEGALINTER_VERSION pins the upstream source, not the shipped image, so the lock its builder stage consumes never reaches it.
  - The generator now exports the lock to a constraints file.

### 📚 Documentation

- Document the reporter toggle and uv.lock pinning" ]
}

@test "a hard-wrapped bullet is unwrapped into a single entry" {
  commit_message 'feat: add a thing

- docs(release): rewrite the README release section and add
  docs/dev/releasing.md covering the invariants the script enforces
'

  run render
  [ "$status" -eq 0 ]
  [ "$output" = "## [unreleased]

### 🚀 Features

- Add a thing

### 📚 Documentation

- *(release)* Rewrite the README release section and add docs/dev/releasing.md covering the invariants the script enforces" ]
}

@test "prose paragraphs and trailers stay out of the changelog" {
  commit_message 'fix: retry transient attestation-verify failures

gh attestation verify and cosign verify-attestation both reach the network.
A transient blip there failed verification outright.

Tests: transient-then-pass, and persistent failure is bounded.
Assisted-By: Nobody <nobody@invalid>
'

  run render
  [ "$status" -eq 0 ]
  [ "$output" = "## [unreleased]

### 🐛 Bug Fixes

- Retry transient attestation-verify failures" ]
}

@test "a merge commit does not repeat the branch's own entries" {
  git -C "${ROOT_DIR}" checkout -q -b topic
  commit_message 'fix: disable updated-sources reporter on read-only runs
'
  git -C "${ROOT_DIR}" checkout -q main
  git -C "${ROOT_DIR}" merge -q --no-ff topic -m 'Merge pull request #21 from x/topic

fix: disable updated-sources reporter on read-only runs
'

  run render
  [ "$status" -eq 0 ]
  [ "$output" = "## [unreleased]

### 🐛 Bug Fixes

- Disable updated-sources reporter on read-only runs" ]
}

@test "a word broken across a hard wrap is rejoined without a space" {
  commit_message 'fix: pin runtime deps

- fix(flavor): pin runtime python deps to upstream uv.lock
  - On 2026-08-19 multiprocessing-
    logging 0.4.0 added a fork-only assertion.
'

  run render
  [ "$status" -eq 0 ]
  [ "$output" = "## [unreleased]

### 🐛 Bug Fixes

- Pin runtime deps
- *(flavor)* Pin runtime python deps to upstream uv.lock
  - On 2026-08-19 multiprocessing-logging 0.4.0 added a fork-only assertion." ]
}

@test "a build bullet is grouped rather than falling through to Other" {
  commit_message 'feat: add a thing

- build(megalinter): exclude the generated CHANGELOG.md from markdownlint
'

  run render
  [ "$status" -eq 0 ]
  [ "$output" = "## [unreleased]

### 🚀 Features

- Add a thing

### ⚙️ Miscellaneous Tasks

- *(megalinter)* Exclude the generated CHANGELOG.md from markdownlint" ]
}

@test "a bullet that is not a conventional commit is dropped" {
  commit_message 'feat: add a thing

- just a plain bullet, not conventional
- another one: with a colon but no type
- feat(real): a real one
'

  run render
  [ "$status" -eq 0 ]
  [ "$output" = "## [unreleased]

### 🚀 Features

- Add a thing
- *(real)* A real one" ]
}
