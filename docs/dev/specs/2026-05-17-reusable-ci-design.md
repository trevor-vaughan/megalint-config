# Reusable CI integrations for shared MegaLinter configs

**Status:** Approved
**Date:** 2026-05-17
**Scope:** Make the MegaLinter run that this repo encapsulates consumable from
both GitHub Actions (as a composite action) and GitLab CI (as a job template),
without duplicating the runner logic across platforms.

## Motivation

This repo hosts a curated MegaLinter profile and the Taskfile/runner glue that
applies it to any target directory. Today the only CI integration is a single
GitHub workflow at `.github/workflows/megalinter.yml` that is bound to this
repo. Downstream projects that want to consume the shared profile in their own
CI have to copy that workflow, or reinvent the docker invocation. Both options
drift.

Goals:

1. Other repos can wire MegaLinter into their CI with a few lines of YAML,
   pinned to a versioned ref of this repo.
2. The runner script (`megalint-run.sh`) stays the single source of truth for
   how MegaLinter is invoked — local dev, GitHub CI, and GitLab CI all flow
   through it.
3. The reusable units expose enough knobs to be useful (per-event policy,
   image override, output location, pull policy) without becoming opinionated
   about platform-specific concerns (artifact upload, SARIF destination).

Non-goals:

- Replacing the official `oxsecurity/megalinter` GitHub Action. It is too
  thin and offers fewer knobs than our runner; see "Alternatives considered".
- Caching the 10 GB MegaLinter image via the platform's file-cache mechanism.
  The `actions/cache` / `cache:` tar+load pattern is empirically net-negative
  for a 10 GB image. The real cache levers are documented but not implemented
  by the reusable units themselves.

## Approach

**Approach A — Task-based runner, thin platform wrappers.** Both reusable
units (GitHub composite, GitLab template) install Task and call
`task megalint:run`. The Taskfile and `megalint-run.sh` are the source of
truth; the wrappers are thin adapters that translate platform inputs into
Taskfile variables and handle post-run housekeeping (reports relocation,
output publication).

Alternatives considered are summarised at the end.

## Architecture

```
                         ┌────────────────────────────────────┐
                         │ trevor-vaughan/megalint-config@v1  │
                         │                                    │
                         │  Taskfile.yml                      │
                         │  .taskfiles/megalint.yml           │
                         │  .taskfiles/scripts/               │
                         │    megalint-run.sh ◄──── ALL       │
                         │    megalinter-sarif-chunk.sh       │
                         │  .mega-linter.yml                  │
                         │  .mega-linter.d/                   │
                         └──┬──────────┬──────────┬───────────┘
                            │          │          │
                       ┌────┴───┐ ┌────┴───┐ ┌────┴────┐
                       │ Local  │ │ GitHub │ │ GitLab  │
                       │  dev   │ │ action │ │template │
                       │        │ │        │ │         │
                       │ task   │ │ action │ │ ci/     │
                       │megalint│ │  .yml  │ │ gitlab/ │
                       │ :run   │ │        │ │megalint │
                       │        │ │        │ │  .yml   │
                       └────────┘ └────────┘ └─────────┘
```

Each consumer path calls `task megalint:run` with platform-appropriate values.
The platform wrappers know nothing about MegaLinter internals; the runner
script knows nothing about CI platforms.

## File layout (changes to this repo)

```
/
├── action.yml                          (new) GitHub composite action
├── ci/
│   └── gitlab/
│       ├── megalint.yml                (new) GitLab job template
│       └── run.sh                      (new) Job script (kept separate so
│                                              YAML stays readable and the
│                                              script is shellcheck-able)
├── .github/workflows/megalinter.yml    (refactor) Becomes a caller of
│                                              action.yml — dogfood test
├── .taskfiles/megalint.yml             (edit) Adds PULL_POLICY variable
├── .taskfiles/scripts/megalint-run.sh  (edit) Adds optional 6th arg
│                                              `pull_policy` (default `never`)
└── docs/dev/specs/
    └── 2026-05-17-reusable-ci-design.md (this file)
```

## Public API

### GitHub composite action — `action.yml`

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `working-directory` | string | `${{ github.workspace }}` | Directory to lint. Maps to Taskfile `TARGET`. |
| `validate-all-codebase` | string | `'false'` | Forwarded as the `VALIDATE_ALL_CODEBASE` env var to MegaLinter. |
| `megalinter-image` | string | `ghcr.io/oxsecurity/megalinter:v9` | Container image to run. Maps to Taskfile `MEGALINTER_IMAGE`. |
| `reports-dir` | string | `<working-directory>/megalinter-reports` | Where reports land on host after the run. |
| `pull-policy` | string | `missing` | `always` / `missing` / `never`. Maps to engine `--pull=`. |

| Output | Description |
|--------|-------------|
| `reports-dir` | Resolved absolute path to the reports directory. |
| `sarif-file` | Absolute path to `megalinter-report.sarif` inside `reports-dir`. |

**Composite steps:**

1. `arduino/setup-task@v2` — install Task.
2. `task -y megalint:run TARGET=… MEGALINTER_IMAGE=… PULL_POLICY=…` with
   `VALIDATE_ALL_CODEBASE` and `GITHUB_TOKEN` in env. `working-directory:` is
   set to `${{ github.action_path }}` so Task finds this repo's Taskfile.
3. Relocate `<working-directory>/megalinter-reports` and `mega-linter.log` to
   `reports-dir` if it differs from the default.
4. Publish outputs `reports-dir` and `sarif-file` via `$GITHUB_OUTPUT`.

**Caller responsibilities** (intentionally not in the action):

- Checking out the caller's repo (`actions/checkout`).
- Uploading reports as a workflow artifact (`actions/upload-artifact`).
- Uploading SARIF to Code Scanning (`github/codeql-action/upload-sarif`).
- Setting `permissions: { security-events: write }` on the calling job.

### GitLab job template — `ci/gitlab/megalint.yml`

Caller includes the template via:

```yaml
include:
  - remote: 'https://raw.githubusercontent.com/trevor-vaughan/megalint-config/v1/ci/gitlab/megalint.yml'

megalint:
  extends: .megalint
```

| Variable | Default | Description |
|----------|---------|-------------|
| `MEGALINT_WORKING_DIRECTORY` | `$CI_PROJECT_DIR` | Directory to lint. |
| `MEGALINT_VALIDATE_ALL_CODEBASE` | `'false'` | Forwarded to MegaLinter. |
| `MEGALINTER_IMAGE` | `ghcr.io/oxsecurity/megalinter:v9` | Override to use Dependency Proxy. |
| `MEGALINT_REPORTS_DIR` | `$CI_PROJECT_DIR/megalinter-reports` | Output location. |
| `MEGALINT_PULL_POLICY` | `missing` | Maps to engine `--pull=`. |
| `MEGALINT_REF` | `v1` | Ref of this repo to clone in `before_script`. Must match the `include:` ref. |

**Template structure:**

- `image: docker:27` with `services: [docker:27-dind]` for the docker socket.
- `before_script:` installs `bash`, `git`, `curl`; clones this repo at
  `$MEGALINT_REF` to `/tmp/megalint-runner`.
- `script:` runs `bash /tmp/megalint-runner/ci/gitlab/run.sh` which installs
  Task and calls `task megalint:run` with the variables above, then relocates
  reports if requested.
- `artifacts:` publishes `$MEGALINT_REPORTS_DIR` and `mega-linter.log` on
  success or failure, and exposes the SARIF via `reports.sast` for GitLab
  Security Dashboard integration.

The `MEGALINT_REF` duplication (in `include:` URL and as a job variable) is
unavoidable: GitLab does not expose to the running job which ref the included
file came from. Documented in template comments.

### Runner script signature change

`megalint-run.sh` grows an optional 6th positional argument:

```text
usage: megalint-run.sh <shared-dir> <target-dir> <engine> <image> <apply-fixes> [pull-policy]
```

`pull-policy` defaults to `never` (current behaviour, preserves local dev
flow), maps to the engine's `--pull=` flag. Taskfile gains a `PULL_POLICY`
variable, defaulted to `never`. Local `task megalint:run` is unchanged.

## Image caching strategy

The MegaLinter image is ~10 GB. Naïve caching via `actions/cache` /
`cache:` (tar + gzip + load) is empirically net-negative at this size and is
explicitly out of scope.

**What we provide:**

- `pull-policy` input on both reusable units. Default `missing` is correct
  for ephemeral CI runners (first run pulls, no re-pull) and self-hosted
  persistent runners (reuse cached image).
- Documented GitLab Dependency Proxy recipe: set
  `MEGALINTER_IMAGE: '${CI_DEPENDENCY_PROXY_GROUP_IMAGE_PREFIX}/oxsecurity/megalinter:v9'`
  in the caller. This caches the image at the GitLab group level — the only
  realistic image-caching win on shared GitLab runners.
- Documented expectation for ephemeral GitHub-hosted runners: accept the pull;
  `ghcr.io` → GitHub runner is already the fastest available path.

**What we don't provide:**

- A `cache-image-tar` input that wires `actions/cache` around `docker save` /
  `docker load`. Rejected as adding complexity for a workflow that is
  net-negative at 10 GB. Can be revisited if measurements show a win.
- A mirror to a private registry. Premature without a stated need.

## Dogfooding and verification

- **GitHub composite:** `.github/workflows/megalinter.yml` is refactored to
  use `./` (local-path reference to the composite action) on push/PR, and to
  use `trevor-vaughan/megalint-config@<tag>` on release tags. Every push
  exercises the action; if it breaks, CI goes red.
- **GitLab template:** this repo is not hosted on GitLab. Manual verification
  gate: a `ci/gitlab/README.md` documents how to point a sample GitLab project
  at the template at a feature branch and run it. No automated CI for the
  template within this repo.
- **Static lint:**
  - `actionlint` (already part of MegaLinter's `ACTIONS_*` linter group)
    covers `action.yml` and `.github/workflows/`.
  - `yamllint` and `shellcheck` (already enabled) cover
    `ci/gitlab/megalint.yml` and `ci/gitlab/run.sh`.

## Versioning

Standard composite-action convention:

- Tag releases `v1.0.0`, `v1.1.0`, ... (semver).
- Maintain floating `v1` tag pointing at the latest 1.x release.
- Breaking changes (renamed input, removed input, changed default with
  consumer impact) → bump major → `v2`, new floating tag.

Consumers pin:

- `@v1` — floating-latest-1.x (most consumers; matches `actions/checkout`
  convention).
- `@v1.2.3` — exact tag pin.
- `@<sha>` — paranoid pin, Dependabot-friendly.

GitLab callers pin the same way via the `include:` URL ref and the matching
`MEGALINT_REF` variable.

## Alternatives considered

### Approach B — Native idioms per platform, no shared runner

Each reusable unit reimplements the docker invocation natively. Rejected:
three sources of truth (local Taskfile, GitHub action, GitLab template) is a
drift trap. A recent fix (`8dd2bad`: "never overwrite target files at stage
names") would have had to be reapplied three times.

### Approach C — Prebuilt runner container image

Publish `ghcr.io/trevor-vaughan/megalint-runner:v1` with Task, scripts, and
configs baked in. Both wrappers `docker run` that image. Rejected for now:
adds a Dockerfile + image build/publish pipeline, and the MegaLinter image
itself already does most of the work — wrapping it in another container is a
layer of indirection that doesn't pay for itself at current scale.

### Piggyback on `oxsecurity/megalinter` GitHub Action

The official action is a Docker action with **zero inputs**, one output
(`has_updated_sources`), a hardcoded image tag, and a single special trick: it
bind-mounts `/var/run/docker.sock` so MegaLinter linters that need a docker
daemon can spawn nested containers.

Rejected as the wrapping unit: it offers fewer knobs than a plain `docker run`,
and being a Docker action means we cannot run config-staging steps inside its
lifecycle — staging would still have to live in our composite as a pre-step.

Borrowed idea (tracked separately): investigate whether any enabled linter in
`.mega-linter.yml` needs the docker socket, and if so, add a conditional
`-v /var/run/docker.sock:/var/run/docker.sock:rw` mount in `megalint-run.sh`.

### `cache-image-tar` opt-in input on GitHub

Wire `actions/cache` around `docker save | gzip`. Rejected: measurements at
the 10 GB scale make this consistently slower than a fresh pull from
`ghcr.io`, and it burns ~half the repo's 10 GB cache budget. Out of scope
unless evidence changes.

## Known limitations

- **`mega-linter.log` is lost in tempdir mode.** Pre-existing behavior of
  `megalint-run.sh`: when `MEGALINT_TMPDIR=1` is set, the cleanup trap copies
  `megalinter-reports/` back from the staging dir but does not copy
  `mega-linter.log`. The reusable units inherit this — a CI caller that sets
  `MEGALINT_TMPDIR=1` will find no log to upload as an artifact. Either fix
  the runner to also persist the log, or document the limitation in the
  reusable units' input docs. Tracked as a separate task.

## Implementation-time verification required

The following items in this design rely on external action/library versions
that have not been re-verified at design time. Verify before writing the
implementation:

- `actions/checkout@v6`, `actions/upload-artifact@v7`,
  `github/codeql-action/upload-sarif@v4` — these are the versions used by the
  existing `.github/workflows/megalinter.yml`. Confirm they are current and
  not typos before copying them into action examples or the refactored
  dogfood workflow. If they are wrong in the existing workflow, fix there as
  part of the same change.
- `arduino/setup-task@v2` — confirm current.
- `docker:27` / `docker:27-dind` GitLab image tags — confirm current major.
- Task installer URL/version (`https://taskfile.dev/install.sh`, pinned
  version) — confirm pinned version is current and the install script's
  flag syntax has not changed.

## Open questions / follow-ups

These are intentionally out of scope for this design and tracked elsewhere:

- Whether to mount `/var/run/docker.sock` in `megalint-run.sh` (depends on
  which linters need it).
- Renaming `megalinter-reports/megalinter-report-chunked/` →
  `megalinter-reports/llm-sarif/` (separate user request, queued after this).
- Whether to fix `megalint-run.sh` to also persist `mega-linter.log` from
  the staging dir in tempdir mode (see Known limitations).
