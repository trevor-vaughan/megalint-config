# Reusable CI Integrations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose this repo's MegaLinter runner as reusable CI units on GitHub
(composite action at repo root `action.yml`) and GitLab (job template at
`ci/gitlab/megalint.yml`), keeping `megalint-run.sh` as the single source of
truth across local, GitHub, and GitLab call sites.

**Architecture:** Both reusable units are thin wrappers around `task megalint:run`.
The runner script gains one new optional argument (`pull_policy`) so CI callers
can request `--pull=missing`; local behavior is unchanged. The GitHub composite
action lives at the repo root for convention; the GitLab template lives at
`ci/gitlab/` and clones this repo at a pinned ref in its `before_script`. The
existing GitHub workflow is refactored to consume the new composite action as
the dogfood test.

**Tech Stack:** Bash 4+, Taskfile v3, GitHub Actions (composite YAML), GitLab CI
YAML, bats-core (new — for testing the runner script change), Podman or Docker.

**Reference spec:** `docs/dev/specs/2026-05-17-reusable-ci-design.md`

---

## File Structure

### Files to create

| Path | Purpose |
| ------ | --------- |
| `action.yml` | GitHub composite action (root location is GHA convention for "the repo IS the action"). |
| `ci/gitlab/megalint.yml` | GitLab job template (`.megalint` job). |
| `ci/gitlab/run.sh` | Job script the template calls. Kept separate so the YAML stays short and the shell is shellcheckable. |
| `ci/gitlab/README.md` | Consumer-facing docs + manual verification recipe (this repo isn't on GitLab, so the template can't be CI-tested here). |
| `.taskfiles/test.yml` | New tasks file with `test:runner` task that runs bats against `megalint-run.sh`. |
| `tests/megalint-run.bats` | bats test asserting the runner forwards `pull_policy` to the engine. |

### Files to modify

| Path | Change |
| ------ | -------- |
| `.taskfiles/scripts/megalint-run.sh` | Accept optional 6th positional arg `pull_policy` (default `never`). Replace hardcoded `--pull=never` on the engine `run` line with `--pull=$pull_policy`. |
| `.taskfiles/megalint.yml` | Add `PULL_POLICY` Taskfile var (default `never`), pass as the 6th arg to `megalint-run.sh`. |
| `Taskfile.yml` | Add `test: ./.taskfiles/test.yml` to `includes:` block. |
| `.github/workflows/megalinter.yml` | Refactor to consume `./` (the new composite action) instead of inlining the Task install + run. Dogfood test. |
| `README.md` | Add a "Using in CI" section pointing consumers at `action.yml` and `ci/gitlab/megalint.yml`. |
| `.gitignore` | Add `.test-output/` if missing, and add `bats-temp/` (bats tmp scratch). |

### Files NOT to touch in this plan

- `.taskfiles/install.yml` — leftover from a different project (`podman-image-lastused`); not in scope.
- `megalint-run.sh`'s tempdir-mode log-loss behavior — pre-existing bug, separate follow-up task.

---

## Task 0: Pre-flight — verify external dependency versions

Per the spec's Implementation-time Verification section, several action/image
versions in the existing workflow and the planned files need to be confirmed
before being written into code. Failing fast here avoids hallucinated `uses:`
lines that need a follow-up fix-up commit.

**Files:** none (research only — but findings get recorded as comments in the relevant files in later tasks).

- [ ] **Step 1: Verify GitHub Actions versions used by the existing workflow**

  Read `.github/workflows/megalinter.yml` and capture the current `uses:` versions:

  ```bash
  grep -E 'uses:' .github/workflows/megalinter.yml
  ```

  For each `uses:` line, confirm the major-version tag exists on the upstream repo. Example for `actions/checkout`:

  ```bash
  gh api repos/actions/checkout/git/refs/tags --jq '.[] | .ref' | grep -E 'refs/tags/v[0-9]+$' | sort -V | tail -5
  ```

  If `gh` is not available in this environment, use `git ls-remote`:

  ```bash
  git ls-remote --tags https://github.com/actions/checkout.git 'refs/tags/v*' | awk -F'/' '{print $NF}' | grep -vE '\^' | sort -V | tail -5
  git ls-remote --tags https://github.com/actions/upload-artifact.git 'refs/tags/v*' | awk -F'/' '{print $NF}' | grep -vE '\^' | sort -V | tail -5
  git ls-remote --tags https://github.com/github/codeql-action.git 'refs/tags/v*' | awk -F'/' '{print $NF}' | grep -vE '\^' | sort -V | tail -5
  git ls-remote --tags https://github.com/arduino/setup-task.git 'refs/tags/v*' | awk -F'/' '{print $NF}' | grep -vE '\^' | sort -V | tail -5
  ```

  Expected: each output ends with a sane-looking semver-tagged release.

  Record findings (one line per action) in a scratch file `.verified-versions.txt` (kept locally, never committed):

  ```text
  actions/checkout: v6 EXISTS (verified YYYY-MM-DD)
  actions/upload-artifact: v7 EXISTS / v4 LATEST → USE v4
  github/codeql-action/upload-sarif: v4 EXISTS
  arduino/setup-task: v2 EXISTS
  ```

- [ ] **Step 2: Verify the `docker:27` GitLab image tag**

  ```bash
  curl -s 'https://hub.docker.com/v2/repositories/library/docker/tags/?page_size=100' | jq -r '.results[].name' | grep -E '^[0-9]+$' | sort -V | tail -5
  ```

  Expected: confirms `27` (or a higher current major) exists. If 27 is stale, pick the latest stable major and record it.

- [ ] **Step 3: Verify the Task installer URL and pick a pinned version**

  ```bash
  curl -fsSL https://taskfile.dev/install.sh -o /tmp/task-install.sh
  head -50 /tmp/task-install.sh
  ```

  Confirm the script's flag syntax matches what the GitLab `run.sh` will use (`-d -b <bindir> <version>`).

  Find the latest Task release tag:

  ```bash
  git ls-remote --tags https://github.com/go-task/task.git 'refs/tags/v*' | awk -F'/' '{print $NF}' | grep -vE '\^' | sort -V | tail -5
  ```

  Record the version to pin (e.g., `v3.40.0`).

- [ ] **Step 4: Record findings**

  Append all verified versions to `.verified-versions.txt`. This file is the source of truth for the `uses:` and pinned versions used in Tasks 2 and 3.

  Append `.verified-versions.txt` to `.gitignore`:

  ```bash
  if ! grep -qxF '.verified-versions.txt' .gitignore; then
    printf '\n# Local-only: implementation-time version verification notes\n.verified-versions.txt\n' >> .gitignore
  fi
  ```

- [ ] **Step 5: Commit the .gitignore change (only)**

  ```bash
  git add .gitignore
  git diff --staged
  git commit -m "$(cat <<'EOF'
  chore(gitignore): ignore implementation-time version notes file

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 1: Add `PULL_POLICY` support to `megalint-run.sh` (TDD)

The runner currently hardcodes `--pull=never` (line 229 of `megalint-run.sh`).
CI callers need `--pull=missing` so the first run on a fresh runner pulls and
subsequent runs reuse the cached image.

**Files:**
- Create: `tests/megalint-run.bats`
- Create: `.taskfiles/test.yml`
- Modify: `Taskfile.yml`
- Modify: `.taskfiles/scripts/megalint-run.sh`
- Modify: `.taskfiles/megalint.yml`
- Modify: `.gitignore`

- [ ] **Step 1: Install bats-core in the environment**

  ```bash
  if ! command -v bats >/dev/null 2>&1; then
    dnf install -y bats || apt-get install -y bats || npm install -g bats
  fi
  bats --version
  ```

  Expected: `Bats 1.x.x` or similar.

- [ ] **Step 2: Create `tests/megalint-run.bats` — the failing test**

  This test stubs out the container engine (replaces `docker`/`podman` with a wrapper that captures its args), runs the script, and asserts the captured args include `--pull=missing` when `pull_policy=missing` is passed.

  ```bash
  mkdir -p tests
  ```

  Create `tests/megalint-run.bats`:

  ```bash
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

  @test "runner rejects 7+ args" {
    run bash "${RUNNER}" a b c d e f g
    [ "$status" -eq 2 ]
  }
  ```

- [ ] **Step 3: Create `.taskfiles/test.yml`**

  ```yaml
  # https://taskfile.dev
  version: '3'

  tasks:
    runner:
      desc: 'Run bats tests for .taskfiles/scripts/megalint-run.sh'
      cmds:
        - bats {{.ROOT_DIR}}/tests/megalint-run.bats

    default:
      cmds:
        - task: runner
  ```

- [ ] **Step 4: Wire `test:` namespace into the top-level Taskfile**

  Modify `Taskfile.yml` — add `test:` to the `includes:` block:

  ```yaml
  # https://taskfile.dev
  version: '3'

  vars:
    CONTAINER_ENGINE:
      sh: 'command -v podman >/dev/null 2>&1 && echo "podman" || echo "docker"'

  includes:
    megalint: ./.taskfiles/megalint.yml
    test: ./.taskfiles/test.yml

  tasks:
    default:
      cmds:
        - task --list
      silent: true
  ```

- [ ] **Step 5: Run the tests — confirm they FAIL**

  ```bash
  task test:runner
  ```

  Expected: the first test (`pull_policy=missing`) fails because the runner currently hardcodes `--pull=never` and doesn't accept a 6th arg. The "rejects 7+ args" test also fails because the current `[[ $# -eq 5 ]]` only rejects 0, 1-4, 6+. Confirm failures, don't proceed until you see them.

- [ ] **Step 6: Update `megalint-run.sh` to accept and use `pull_policy`**

  Edit `.taskfiles/scripts/megalint-run.sh`:

  - Update the usage comment block (lines 4-6):

    ```diff
     # Usage:
    -#   megalint-run.sh <shared-dir> <target-dir> <engine> <image> <apply-fixes>
    +#   megalint-run.sh <shared-dir> <target-dir> <engine> <image> <apply-fixes> [pull-policy]
     #
    ```

  - Update the `usage()` function:

    ```diff
     usage() {
    - echo "usage: $0 <shared-dir> <target-dir> <engine> <image> <apply-fixes>" >&2
    + echo "usage: $0 <shared-dir> <target-dir> <engine> <image> <apply-fixes> [pull-policy]" >&2
      exit 2
     }
    ```

  - Update arg-count check and add the new variable:

    ```diff
    -[[ $# -eq 5 ]] || usage
    +[[ $# -ge 5 && $# -le 6 ]] || usage

     shared_raw="$1"
     target_raw="$2"
     engine="$3"
     image="$4"
     apply_fixes="$5"
    +pull_policy="${6:-never}"
    ```

  - Update the engine invocation (around line 229):

    ```diff
     "${engine}" run --rm \
    -    --pull=never \
    +    --pull="${pull_policy}" \
         "${mounts[@]}" \
         "${env_args[@]}" \
         "${image}"
    ```

- [ ] **Step 7: Run the tests — confirm they PASS**

  ```bash
  task test:runner
  ```

  Expected: all 4 tests pass.

- [ ] **Step 8: Update `.taskfiles/megalint.yml` to plumb `PULL_POLICY`**

  Edit `.taskfiles/megalint.yml`:

  ```diff
     run:
       desc: 'Run MegaLinter against TARGET (default: this repo). APPLY_FIXES=all to auto-fix.'
       deps: [pull]
       vars:
         TARGET: '{{.TARGET | default .ROOT_DIR}}'
         APPLY_FIXES: '{{.APPLY_FIXES | default "none"}}'
    +    PULL_POLICY: '{{.PULL_POLICY | default "never"}}'
       cmds:
         - defer: { task: sarif-chunk, vars: { TARGET: '{{.TARGET}}' } }
         - >-
           bash "{{.TASKFILE_DIR}}/scripts/megalint-run.sh"
           "{{.ROOT_DIR}}"
           "{{.TARGET}}"
           "{{.CONTAINER_ENGINE}}"
           "{{.MEGALINTER_IMAGE}}"
           "{{.APPLY_FIXES}}"
    +      "{{.PULL_POLICY}}"
  ```

- [ ] **Step 9: Verify local task still works (smoke test, no image pull)**

  ```bash
  task --list
  task megalint:run --dry
  ```

  Expected: `task --list` shows `test:runner` and `megalint:run`; `--dry` for `megalint:run` shows the runner command with `PULL_POLICY=never` (the default) — no actual MegaLinter execution.

- [ ] **Step 10: Verify `.gitignore` already covers test artifacts**

  ```bash
  grep -qxF '.test-output/' .gitignore && echo OK
  ```

  Expected: `OK`. (The repo's `.gitignore` already has this entry under "Test artifacts" — no change needed.)

- [ ] **Step 11: Stage and review**

  ```bash
  git add tests/megalint-run.bats .taskfiles/test.yml Taskfile.yml \
          .taskfiles/scripts/megalint-run.sh .taskfiles/megalint.yml
  git diff --staged
  ```

  Confirm: only these five files in the staged diff, no other drift.

- [ ] **Step 12: Commit**

  ```bash
  git commit -m "$(cat <<'EOF'
  feat(runner): accept pull_policy as optional 6th arg

  Lets CI callers request --pull=missing (correct for ephemeral runners
  that need to pull once and reuse) while preserving the local default
  of --pull=never (which relies on the separate pull task).

  Adds bats-based tests for the runner script as the first test
  scaffolding in the repo.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 2: Create the GitHub composite action and refactor the existing workflow

This task creates `action.yml` at the repo root and refactors
`.github/workflows/megalinter.yml` to consume it (`uses: ./`). The repo
becomes its own first consumer — every push is the test.

**Files:**
- Create: `action.yml`
- Modify: `.github/workflows/megalinter.yml`

- [ ] **Step 1: Create `action.yml`**

  Use the verified versions from `.verified-versions.txt` (Task 0) for `arduino/setup-task@...`. If verification showed `v2` is current, use `v2`.

  ```yaml
  ---
  name: 'MegaLinter (shared config)'
  description: >-
    Run MegaLinter with the shared config from trevor-vaughan/megalint-config
    against a working directory. The caller is responsible for checkout,
    artifact upload, and SARIF upload to Code Scanning.
  author: 'Trevor Vaughan'
  branding:
    icon: 'check-circle'
    color: 'green'

  inputs:
    working-directory:
      description: 'Directory to lint. Defaults to GITHUB_WORKSPACE.'
      required: false
      default: ${{ github.workspace }}
    validate-all-codebase:
      description: 'Forwarded to MegaLinter as VALIDATE_ALL_CODEBASE.'
      required: false
      default: 'false'
    megalinter-image:
      description: 'MegaLinter container image to run.'
      required: false
      default: 'ghcr.io/oxsecurity/megalinter:v9'
    reports-dir:
      description: >-
        Where reports land on host after the run. Defaults to
        <working-directory>/megalinter-reports. Action moves reports there
        post-run if it differs from the default.
      required: false
      default: ''
    pull-policy:
      description: 'Engine --pull= policy: always | missing | never.'
      required: false
      default: 'missing'

  outputs:
    reports-dir:
      description: 'Resolved absolute path to the reports directory.'
      value: ${{ steps.publish.outputs.reports-dir }}
    sarif-file:
      description: 'Absolute path to megalinter-report.sarif inside reports-dir.'
      value: ${{ steps.publish.outputs.sarif-file }}

  runs:
    using: composite
    steps:
      - name: Install Task
        uses: arduino/setup-task@v2
        with:
          repo-token: ${{ github.token }}

      - name: Resolve reports-dir
        id: resolve
        shell: bash
        run: |
          set -euo pipefail
          working_dir='${{ inputs.working-directory }}'
          reports='${{ inputs.reports-dir }}'
          if [ -z "${reports}" ]; then
            reports="${working_dir}/megalinter-reports"
          fi
          # Normalize to absolute path (does not require the dir to exist)
          reports_abs="$(realpath -m "${reports}")"
          default_abs="$(realpath -m "${working_dir}/megalinter-reports")"
          echo "reports=${reports_abs}" >> "$GITHUB_OUTPUT"
          echo "default=${default_abs}" >> "$GITHUB_OUTPUT"

      - name: Run MegaLinter via shared Taskfile
        shell: bash
        working-directory: ${{ github.action_path }}
        env:
          VALIDATE_ALL_CODEBASE: ${{ inputs.validate-all-codebase }}
          GITHUB_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          task -y megalint:run \
            TARGET='${{ inputs.working-directory }}' \
            MEGALINTER_IMAGE='${{ inputs.megalinter-image }}' \
            PULL_POLICY='${{ inputs.pull-policy }}'

      - name: Relocate reports if requested
        if: ${{ always() }}
        shell: bash
        run: |
          set -euo pipefail
          default='${{ steps.resolve.outputs.default }}'
          target='${{ steps.resolve.outputs.reports }}'
          working_dir='${{ inputs.working-directory }}'
          # Guard with -d so a MegaLinter crash before reports were written
          # doesn't mask the original failure with a missing-source mv error.
          if [ "${default}" != "${target}" ] && [ -d "${default}" ]; then
            mkdir -p "$(dirname "${target}")"
            rm -rf "${target}"
            mv "${default}" "${target}"
            if [ -f "${working_dir}/mega-linter.log" ]; then
              mv "${working_dir}/mega-linter.log" "${target}/"
            fi
          fi

      - name: Publish outputs
        id: publish
        if: ${{ always() }}
        shell: bash
        run: |
          set -euo pipefail
          target='${{ steps.resolve.outputs.reports }}'
          echo "reports-dir=${target}" >> "$GITHUB_OUTPUT"
          echo "sarif-file=${target}/megalinter-report.sarif" >> "$GITHUB_OUTPUT"
  ```

- [ ] **Step 2: Refactor `.github/workflows/megalinter.yml` to dogfood the composite action**

  Use the verified versions from `.verified-versions.txt` for `actions/checkout`, `actions/upload-artifact`, and `github/codeql-action/upload-sarif`. If verification showed `v6`, `v7`, and `v4` are NOT current, use the current ones instead — do not preserve the existing wrong versions just because they were there.

  Replace the entire file:

  ```yaml
  ---
  name: MegaLinter

  # yamllint disable-line rule:truthy
  on:
    push:
    pull_request:
      branches: [main]

  permissions:
    contents: read

  concurrency:
    group: ${{ github.workflow }}-${{ github.ref }}
    cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}

  jobs:
    megalinter:
      name: MegaLinter
      runs-on: ubuntu-latest
      permissions:
        contents: read
        security-events: write
        pull-requests: write
      steps:
        - name: Checkout repository
          uses: actions/checkout@<VERIFIED_TAG>
          with:
            fetch-depth: 0

        - name: Run MegaLinter via local composite action
          id: megalint
          uses: ./
          with:
            validate-all-codebase: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}

        - name: Upload MegaLinter reports
          if: ${{ success() || failure() }}
          uses: actions/upload-artifact@<VERIFIED_TAG>
          with:
            name: megalinter-reports
            path: |
              ${{ steps.megalint.outputs.reports-dir }}
              mega-linter.log

        - name: Upload SARIF to GitHub Code Scanning
          if: ${{ success() || failure() }}
          uses: github/codeql-action/upload-sarif@<VERIFIED_TAG>
          with:
            sarif_file: ${{ steps.megalint.outputs.sarif-file }}
  ```

  Replace `<VERIFIED_TAG>` placeholders with the actual tags recorded in `.verified-versions.txt`.

- [ ] **Step 3: Static-lint the new action and refactored workflow locally**

  ```bash
  task megalint:run
  ```

  Expected: passes. `actionlint` (enabled by default in MegaLinter's `ACTIONS_*` group) will flag any malformed `action.yml` or workflow YAML. Yamllint will flag formatting issues.

  If MegaLinter has unrelated pre-existing findings, scope this check to the two files:

  ```bash
  task megalint:run TARGET="$(pwd)" 2>&1 | grep -E '(action\.yml|megalinter\.yml)'
  ```

- [ ] **Step 4: Stage and review**

  ```bash
  git add action.yml .github/workflows/megalinter.yml
  git diff --staged
  ```

  Confirm: only these two files, all `<VERIFIED_TAG>` placeholders replaced.

- [ ] **Step 5: Commit**

  ```bash
  git commit -m "$(cat <<'EOF'
  feat(ci): add reusable composite action; dogfood from workflow

  action.yml lets consumers run MegaLinter with the shared config via
    uses: trevor-vaughan/megalint-config@<ref>
  with caller-owned checkout, artifact upload, and SARIF publication.

  The repo's own workflow is refactored to consume the composite action
  via uses: ./ — every push is now also the action's integration test.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 6: Push the branch and confirm the dogfood workflow passes in CI**

  ```bash
  git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
  ```

  Then open the GitHub Actions tab on the branch and confirm the MegaLinter job runs to completion (pass or expected-fail based on existing findings — but not a `uses: ./` resolution failure or composite-action error).

  If the job fails with an action-resolution error (e.g., "couldn't find action.yml"), debug before proceeding.

---

## Task 3: Create the GitLab job template

The GitLab template is structurally simpler than the composite action. It
includes a `before_script` that clones this repo at a pinned ref and a
`script:` that calls a separate shell file. This repo is not on GitLab, so
the template can't be CI-tested here — Task 3 ends with a documented manual
verification recipe.

**Files:**
- Create: `ci/gitlab/megalint.yml`
- Create: `ci/gitlab/run.sh`
- Create: `ci/gitlab/README.md`

- [ ] **Step 1: Create `ci/gitlab/megalint.yml`**

  ```bash
  mkdir -p ci/gitlab
  ```

  ```yaml
  ---
  # Reusable MegaLinter job template using the shared config from
  # trevor-vaughan/megalint-config.
  #
  # Caller usage in their own .gitlab-ci.yml:
  #
  #   include:
  #     - remote: 'https://raw.githubusercontent.com/trevor-vaughan/megalint-config/v1/ci/gitlab/megalint.yml'
  #
  #   megalint:
  #     extends: .megalint
  #     variables:
  #       MEGALINT_REF: 'v1'   # MUST match the ref in include: above
  #       # Use the GitLab Dependency Proxy to cache the 10GB MegaLinter image
  #       # at group level; bumps subsequent runs from ~5min pull to seconds.
  #       MEGALINTER_IMAGE: '${CI_DEPENDENCY_PROXY_GROUP_IMAGE_PREFIX}/oxsecurity/megalinter:v9'
  #
  # Per-event policy (validate all vs. PR diff only) is set via rules:
  # see ci/gitlab/README.md for the full caller example.

  .megalint:
    image: 'docker:<VERIFIED_DOCKER_TAG>'
    services:
      - 'docker:<VERIFIED_DOCKER_TAG>-dind'
    variables:
      MEGALINT_WORKING_DIRECTORY: '$CI_PROJECT_DIR'
      MEGALINT_VALIDATE_ALL_CODEBASE: 'false'
      MEGALINTER_IMAGE: 'ghcr.io/oxsecurity/megalinter:v9'
      MEGALINT_REPORTS_DIR: '$CI_PROJECT_DIR/megalinter-reports'
      MEGALINT_PULL_POLICY: 'missing'
      # Pin to match the include: ref. Override in the caller if the
      # include ref differs.
      MEGALINT_REF: 'v1'
      DOCKER_HOST: 'tcp://docker:2375'
      DOCKER_TLS_CERTDIR: ''
    before_script:
      - apk add --no-cache bash git curl
      - git clone --depth 1 --branch "$MEGALINT_REF"
          https://github.com/trevor-vaughan/megalint-config.git
          /tmp/megalint-runner
    script:
      - bash /tmp/megalint-runner/ci/gitlab/run.sh
    artifacts:
      when: always
      paths:
        - '$MEGALINT_REPORTS_DIR'
        - 'mega-linter.log'
      reports:
        sast: '$MEGALINT_REPORTS_DIR/megalinter-report.sarif'
  ```

  Replace `<VERIFIED_DOCKER_TAG>` (both occurrences) with the value recorded in `.verified-versions.txt` (e.g., `27`).

- [ ] **Step 2: Create `ci/gitlab/run.sh`**

  Use the verified Task version from `.verified-versions.txt` (e.g., `v3.40.0`).

  ```bash
  #!/usr/bin/env bash
  # Script invoked by ci/gitlab/megalint.yml. Installs Task, runs the
  # shared MegaLinter Taskfile, and relocates reports if requested.
  set -euo pipefail

  : "${MEGALINT_WORKING_DIRECTORY:?must be set by the template}"
  : "${MEGALINT_REPORTS_DIR:?must be set by the template}"
  : "${MEGALINTER_IMAGE:?must be set by the template}"
  : "${MEGALINT_PULL_POLICY:?must be set by the template}"
  : "${MEGALINT_VALIDATE_ALL_CODEBASE:=false}"

  # Pin Task version. Update via Task 0 verification process when bumping.
  TASK_VERSION='<VERIFIED_TASK_VERSION>'

  # Install Task to /usr/local/bin. The installer flag for bindir is -b
  # (not -d -b — -d is the installer's debug flag, easy mistake to make).
  sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -b /usr/local/bin "${TASK_VERSION}"

  cd /tmp/megalint-runner

  VALIDATE_ALL_CODEBASE="${MEGALINT_VALIDATE_ALL_CODEBASE}" \
    task -y megalint:run \
      TARGET="${MEGALINT_WORKING_DIRECTORY}" \
      MEGALINTER_IMAGE="${MEGALINTER_IMAGE}" \
      PULL_POLICY="${MEGALINT_PULL_POLICY}"

  # Relocate reports if the caller asked for a non-default location.
  # Guard with -d so a MegaLinter crash before reports were written doesn't
  # mask the original failure with a missing-source mv error.
  default_reports="${MEGALINT_WORKING_DIRECTORY}/megalinter-reports"
  default_abs="$(realpath -m "${default_reports}")"
  target_abs="$(realpath -m "${MEGALINT_REPORTS_DIR}")"
  if [ "${default_abs}" != "${target_abs}" ] && [ -d "${default_reports}" ]; then
    mkdir -p "$(dirname "${MEGALINT_REPORTS_DIR}")"
    rm -rf "${MEGALINT_REPORTS_DIR}"
    mv "${default_reports}" "${MEGALINT_REPORTS_DIR}"
    if [ -f "${MEGALINT_WORKING_DIRECTORY}/mega-linter.log" ]; then
      mv "${MEGALINT_WORKING_DIRECTORY}/mega-linter.log" "${MEGALINT_REPORTS_DIR}/"
    fi
  fi
  ```

  ```bash
  chmod +x ci/gitlab/run.sh
  ```

  Replace `<VERIFIED_TASK_VERSION>` with the pinned version from Task 0.

- [ ] **Step 3: Create `ci/gitlab/README.md` — consumer docs and manual verification recipe**

  ```markdown
  # GitLab CI integration

  Reusable GitLab CI job template for running the shared MegaLinter config
  in any GitLab project.

  ## Quick start

  Add to your project's `.gitlab-ci.yml`:

  ```yaml
  include:
    - remote: 'https://raw.githubusercontent.com/trevor-vaughan/megalint-config/v1/ci/gitlab/megalint.yml'

  megalint:
    extends: .megalint
    variables:
      MEGALINT_REF: 'v1'
      # Cache the 10GB MegaLinter image via GitLab Dependency Proxy
      MEGALINTER_IMAGE: '${CI_DEPENDENCY_PROXY_GROUP_IMAGE_PREFIX}/oxsecurity/megalinter:v9'
    rules:
      # Full-tree lint on default branch
      - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
        variables:
          MEGALINT_VALIDATE_ALL_CODEBASE: 'true'
      # PR-diff lint everywhere else
      - when: on_success
  ```

  `MEGALINT_REF` must match the ref in the `include:` URL — GitLab does not
  expose to the running job which ref the included file came from.

  ## Available variables

  | Variable | Default | Description |
  | ---------- | --------- | ------------- |
  | `MEGALINT_WORKING_DIRECTORY` | `$CI_PROJECT_DIR` | Directory to lint. |
  | `MEGALINT_VALIDATE_ALL_CODEBASE` | `'false'` | Lint full tree (vs. PR diff). |
  | `MEGALINTER_IMAGE` | `ghcr.io/oxsecurity/megalinter:v9` | Container image to run. |
  | `MEGALINT_REPORTS_DIR` | `$CI_PROJECT_DIR/megalinter-reports` | Where reports land on host. |
  | `MEGALINT_PULL_POLICY` | `missing` | Engine `--pull=` policy. |
  | `MEGALINT_REF` | `v1` | Ref of trevor-vaughan/megalint-config to clone. |

  ## Manual verification

  This repo isn't hosted on GitLab, so the template can't be CI-tested in
  this repo. To verify changes:

  1. Push the branch to a GitHub fork, note the branch name (e.g., `feature/x`).
  2. In a sandbox GitLab project, set `.gitlab-ci.yml`:

     ```yaml
     include:
       - remote: 'https://raw.githubusercontent.com/<your-fork>/megalint-config/feature/x/ci/gitlab/megalint.yml'

     megalint:
       extends: .megalint
       variables:
         MEGALINT_REF: 'feature/x'
     ```

  3. Push and observe the job run in the sandbox project's pipeline view.
  4. Confirm:
     - `before_script` clones the runner without auth errors.
     - `script` produces `megalinter-reports/megalinter-report.sarif`.
     - `artifacts:` block uploads the reports and SARIF.
     - SARIF appears in the project's Security widget.

  ## Customization

  - **Override `image:` / `services:`** in the caller if your runner doesn't
    support Docker-in-Docker (e.g., shell executor with `/var/run/docker.sock`
    bind-mounted). You then own installing `bash`, `git`, `curl` in
    `before_script`.
  - **Add `variables: MEGALINT_REPORTS_DIR: 'reports'`** to land reports
    under a custom path (e.g., for matching another tool's expectations).
  ```

- [ ] **Step 4: Lint the new files locally**

  ```bash
  task megalint:run
  ```

  Expected: yamllint passes on `ci/gitlab/megalint.yml`; shellcheck passes on `ci/gitlab/run.sh`; markdownlint passes on `ci/gitlab/README.md`.

- [ ] **Step 5: Stage and review**

  ```bash
  git add ci/gitlab/
  git diff --staged
  ```

  Confirm: three files (`megalint.yml`, `run.sh`, `README.md`), `<VERIFIED_*>` placeholders replaced, `run.sh` is executable.

- [ ] **Step 6: Commit**

  ```bash
  git commit -m "$(cat <<'EOF'
  feat(ci): add reusable GitLab job template

  ci/gitlab/megalint.yml is a job template consumers include via:
    include:
      - remote: 'https://raw.githubusercontent.com/.../ci/gitlab/megalint.yml'
    megalint:
      extends: .megalint

  The template's before_script clones this repo at $MEGALINT_REF and
  the script runs the shared Taskfile, keeping megalint-run.sh as the
  single source of truth across local, GitHub CI, and GitLab CI.

  ci/gitlab/README.md documents the manual verification recipe (this
  repo isn't on GitLab, so the template can't be CI-tested in-tree).

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 4: README — document CI consumption

The root `README.md` already has a "Continuous integration" section that
describes the existing GitHub workflow. Extend it with a "Using in CI" section
pointing at the new reusable units.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README to find the CI section**

  ```bash
  grep -n '^## ' README.md
  ```

  Note the line ranges of the "Continuous integration" section (currently lines 173-184 per the spec exploration).

- [ ] **Step 2: Replace the CI section with the expanded version**

  Read the existing "Continuous integration" section and replace it with the version below. The opening paragraph about the in-repo workflow is preserved; new subsections are added.

  ```markdown
  ## Continuous integration

  `.github/workflows/megalinter.yml` runs the same linter in CI on every push
  and on PRs targeting `main`. The workflow consumes the local composite
  action at `action.yml` — making the repo its own first consumer.

  The workflow:

  - Lints only the PR diff on pull requests (`validate-all-codebase: false`)
    and the full tree on pushes to `main`.
  - Uploads `megalinter-reports/` and `mega-linter.log` as a workflow
    artifact for download.
  - Uploads the SARIF report to GitHub Code Scanning so findings appear in
    the Security tab and as inline PR annotations.

  ### Using in another GitHub repo

  Add to your `.github/workflows/megalinter.yml`:

  ```yaml
  jobs:
    megalinter:
      runs-on: ubuntu-latest
      permissions:
        contents: read
        security-events: write
        pull-requests: write
      steps:
        - uses: actions/checkout@v4
          with: { fetch-depth: 0 }

        - id: megalint
          uses: trevor-vaughan/megalint-config@v1
          with:
            validate-all-codebase: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}

        - uses: actions/upload-artifact@v4
          if: ${{ success() || failure() }}
          with:
            name: megalinter-reports
            path: ${{ steps.megalint.outputs.reports-dir }}

        - uses: github/codeql-action/upload-sarif@v3
          if: ${{ success() || failure() }}
          with:
            sarif_file: ${{ steps.megalint.outputs.sarif-file }}
  ```

  Inputs: `working-directory`, `validate-all-codebase`, `megalinter-image`,
  `reports-dir`, `pull-policy`. Outputs: `reports-dir`, `sarif-file`. See
  `action.yml` for defaults.

  ### Using in a GitLab repo

  See [`ci/gitlab/README.md`](ci/gitlab/README.md) for the full recipe.

  Short form:

  ```yaml
  include:
    - remote: 'https://raw.githubusercontent.com/trevor-vaughan/megalint-config/v1/ci/gitlab/megalint.yml'

  megalint:
    extends: .megalint
    variables:
      MEGALINT_REF: 'v1'
      MEGALINTER_IMAGE: '${CI_DEPENDENCY_PROXY_GROUP_IMAGE_PREFIX}/oxsecurity/megalinter:v9'
  ```
  ```

  Note: in Step 2 above, replace the example `uses:` tags (`@v4`, `@v3`) with the verified tags from Task 0 if they differ.

- [ ] **Step 3: Lint and verify**

  ```bash
  task megalint:run
  ```

  Expected: markdownlint passes on the changed README.

- [ ] **Step 4: Stage and review**

  ```bash
  git add README.md
  git diff --staged README.md
  ```

  Confirm: only the "Continuous integration" section changed, no drive-by edits elsewhere.

- [ ] **Step 5: Commit**

  ```bash
  git commit -m "$(cat <<'EOF'
  docs(readme): document CI consumption from GitHub and GitLab

  Extends the existing CI section with consumer recipes for the new
  composite action (action.yml) and the GitLab job template
  (ci/gitlab/megalint.yml).

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Self-Review

Run through the spec's requirements one more time against the plan above.

**Spec coverage:**

| Spec requirement | Task |
| ------------------ | ------ |
| GitHub composite action at `action.yml` | Task 2, Step 1 |
| GitLab template at `ci/gitlab/megalint.yml` | Task 3, Step 1 |
| GitLab job script at `ci/gitlab/run.sh` | Task 3, Step 2 |
| Refactor `.github/workflows/megalinter.yml` to dogfood | Task 2, Step 2 |
| Runner script: `pull_policy` as 6th arg | Task 1, Step 6 |
| Taskfile: `PULL_POLICY` variable | Task 1, Step 8 |
| Inputs: working-directory, validate-all-codebase, megalinter-image, reports-dir, pull-policy | Task 2, Step 1 |
| Outputs: reports-dir, sarif-file | Task 2, Step 1 |
| Reports relocation post-step | Task 2, Step 1 + Task 3, Step 2 |
| GitLab Dependency Proxy documented | Task 3, Step 3 |
| Implementation-time version verification | Task 0 |
| Dogfood test (push to branch, observe CI) | Task 2, Step 6 |
| GitLab manual verification recipe | Task 3, Step 3 |
| Consumer docs in root README | Task 4 |

No gaps.

**Placeholder scan:** All code blocks are concrete. The two `<VERIFIED_*>` placeholders in Tasks 2 and 3 are intentional and are resolved by Task 0's recorded findings — they are not "fill in later" prompts.

**Type consistency:** Input/variable names are consistent across tasks:
- `working-directory` / `MEGALINT_WORKING_DIRECTORY`
- `validate-all-codebase` / `MEGALINT_VALIDATE_ALL_CODEBASE`
- `megalinter-image` / `MEGALINTER_IMAGE`
- `reports-dir` / `MEGALINT_REPORTS_DIR`
- `pull-policy` / `MEGALINT_PULL_POLICY`

Outputs (`reports-dir`, `sarif-file`) referenced in the dogfood workflow (Task 2 Step 2) and README example (Task 4 Step 2) match the names defined in `action.yml` (Task 2 Step 1).

The runner script's positional arg name `pull_policy` (Task 1 Step 6) matches the Taskfile var `PULL_POLICY` (Task 1 Step 8) and is plumbed correctly to the composite action's `pull-policy` input (Task 2 Step 1).
