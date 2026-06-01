# Shared MegaLinter configuration

______________________________________________________________________

> 🤖 LLM WARNING 🤖
>
> This project was written with LLM (AI) assistance.
>
> 🤖 LLM WARNING 🤖

______________________________________________________________________

A curated [MegaLinter](https://megalinter.io/) profile, plus the Taskfile
glue for running it locally in a container and the SARIF-chunking scripts
that make findings tractable for both humans and LLM-driven remediation.

The canonical artifact is `.mega-linter.yml` — designed to be consumed by
other repositories via MegaLinter's `EXTENDS:` directive, so multiple
projects can share one linting policy.

## What's in here

| Path | Purpose |
|------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `.mega-linter.yml` | The shared MegaLinter profile. Linters enabled, disabled, and configured. |
| `.mega-linter.d/` | Drop-in directory for shared sub-configs (`.devskim.json`, `.jscpd.json`, `kics.config`, …). Anything here is auto-mounted into target repos at the workspace root. |
| `Taskfile.yml` | Top-level task entrypoint. |
| `.taskfiles/megalint.yml` | Tasks for running MegaLinter locally. |
| `.taskfiles/scripts/megalint-run.sh` | The linter runner. Bind-mounts target + shared configs into the container. |
| `.taskfiles/scripts/megalinter-sarif-chunk.sh` | Splits SARIF into per-linter markdown for LLM-driven remediation. |
| `.github/workflows/megalinter.yml` | CI workflow that runs MegaLinter on every push and PR. |

## Custom flavor image

This repo also publishes a **custom MegaLinter flavor image** to
`ghcr.io/trevor-vaughan/megalinter-custom-flavor`, built from `.mega-linter.yml`.

### Image tags — read this before you pin

| Tag | Meaning | Use it when |
|----------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------|
| `:latest` | **Always the freshest build.** Moved by every release *and* by the weekly refresh that rebuilds on the newest upstream MegaLinter. **Not stable** — it changes under you. | You want the newest linters and CVE data and do not need reproducibility. |
| `:X.Y.Z-mlA.B.C` | **Immutable release.** `X.Y.Z` is this repo's release; `mlA.B.C` is the exact upstream MegaLinter it wraps. Never moves. | You need a reproducible, auditable scan. **Pin this** (or a digest). |
| `:X.Y.Z-rcN-mlA.B.C` | Pre-release. Immutable and pullable for testing. **Never** becomes `:latest`. | You are validating a release candidate. |
| `:sha-<commit>` | The exact build for a commit. Immutable. | You need to trace an image to its source commit. |

> **Reproducibility:** `:latest` is intentionally a moving target so security
> scans get the newest rules by default. For repeatable results, pin a digest
> (`...@sha256:…`) or an immutable composite tag — never `:latest`.

### Cutting a release

```bash
git tag v0.1.0
git push origin v0.1.0
```

The tag push builds the multi-platform image, publishes `:0.1.0-ml<upstream>`
and `:sha-<commit>`, moves `:latest` (non-pre-releases only), attaches SLSA
provenance + SBOM attestations, and creates a GitHub release. Pre-release tags
(`v0.1.0-rc1`) publish a composite image but do not move `:latest`. The weekly
cron rebuilds `:latest` only, to absorb upstream patches between releases.

## Running MegaLinter

This repo is a *linter runner*: clone it once, then point it at any
directory. Configs stay here — nothing needs to be vendored into the
target repository.

Requires [Task](https://taskfile.dev) and either Podman or Docker (Podman
is preferred and auto-detected).

```bash
# List available tasks
task

# Lint this repo's working tree
task megalint:run

# Lint only files changed vs. the default branch (HEAD diff)
# Automatically uses .mega-linter-changed.yml override config that disables
# repository-scoped linters for faster feedback during development
task megalint:changed

# Lint a different repo using these shared configs
task megalint:run TARGET=/path/to/other/repo

# Use specific override config
task megalint:run TARGET=/path/to/other/repo CONFIG_FILE=".mega-linter-changed.yml"

# From outside this repo
task -d /path/to/this/repo megalint:run TARGET=$PWD

# Apply auto-fixes (writes changes to the target)
task megalint:run APPLY_FIXES=all

# Pre-pull the image (~10 GB). Asks for confirmation.
task megalint:pull
```

The runner supports two staging modes. The default is the fast,
zero-prep path; an opt-in mode trades a small bit of prep for
isolation.

### Default mode: in-target staging

The shared configs are copied directly into the target's workspace
root, the target is bind-mounted into the container, and an EXIT trap
removes the staged copies after the run finishes. No prep cost beyond
a handful of `cp` operations.

- **`APPLY_FIXES=none`:** target mounted **read-only** with a nested
  read-write mount of `<target>/megalinter-reports/` (pre-created) so
  the linter can write findings without being able to modify anything
  else.
- **`APPLY_FIXES=all`:** target mounted read-write so MegaLinter can
  rewrite source files in place.

Trade-offs: the staged config files briefly appear in your target
during the run (they show in `git status`, IDE file trees, etc., until
the EXIT trap removes them). Two concurrent `task megalint:run`
invocations against the same target will collide on the staged files.

### Opt-in mode: tempdir staging (`MEGALINT_TMPDIR=1`)

Set `MEGALINT_TMPDIR` to any non-empty value and the runner:

1. Creates a private staging directory adjacent to your target —
   `<parent>/.megalint_<rand>_<target-basename>/`, mode `0700`,
   dot-prefixed so it stays out of `ls` and `git status`.
1. Hardlink-clones the source tree into staging via `rsync --link-dest`,
   skipping `.git/` (the largest single contributor to prep time on any
   real repo).
1. Drops the shared configs into staging as real copies.
1. Bind-mounts `<target>/.git` into the staging mount read-only, so
   linters have full git access without per-file prep work.
1. Mounts staging into the container, runs the lint, copies reports
   back to `<target>/megalinter-reports/`, and removes the staging dir.

The target tree itself is never modified — staged configs never appear
inside it. Each run gets a unique random suffix, so concurrent runs
against the same target are safe.

```bash
# One-off
MEGALINT_TMPDIR=1 task megalint:run

# Persistently for your shell
export MEGALINT_TMPDIR=1
```

Trade-off: rsync walk of the source tree (sub-second on typical repos
since `.git/` is excluded; longer on very large source trees). The
`.git/` bind mount is always read-only regardless of `APPLY_FIXES` —
fixes should affect tracked files, not the git database.

### Common to both modes

All mounts use the `z` SELinux relabel flag. The EXIT trap also handles
SIGINT, SIGTERM, and SIGHUP, so the staging is cleaned up even when
you Ctrl-C mid-run or your terminal disconnects.

**Requires:** Task, Podman or Docker. Tempdir mode additionally
requires `rsync` (preinstalled on every major Linux distro and macOS;
on minimal containers you may need `apt install rsync` or
`dnf install rsync`).

The container image is pinned to `ghcr.io/oxsecurity/megalinter:v9` —
override with `MEGALINTER_IMAGE=...` if you need a different tag.

### Vulnerability-DB caching

Trivy and grype download vulnerability databases on each run. By default
the runner persists these databases in a host-side cache directory so
they survive between runs. The cache directory is bind-mounted into the
container at the `XDG_CACHE_HOME` target.

**Default path:** `${XDG_CACHE_HOME:-$HOME/.cache}/megalint/vuln-db`

Override with the `MEGALINT_VULN_CACHE` environment variable:

```bash
# Use a custom cache location
MEGALINT_VULN_CACHE=/var/cache/megalint task megalint:run

# Disable caching (old ephemeral behavior — fresh download every run)
MEGALINT_VULN_CACHE="" task megalint:run
```

In CI, the GitHub Actions composite action exposes a `vuln-cache-dir`
input (defaults to `~/.cache/megalint/vuln-db`). Pair it with
`actions/cache` for persistence across workflow runs — see the dogfooding
workflow in `.github/workflows/megalinter.yml` for an example.

## Config Inheritance

This runner supports **MegaLinter config inheritance** using the `EXTENDS` directive to reduce maintenance overhead.

### Override Configs

The `.mega-linter.d/` directory contains drop-in override configurations:

- `.mega-linter-changed.yml` - Optimized config for changed-files mode that disables resource-intensive repository-scoped linters

### Usage

Override configs are automatically copied to the target workspace root and can be referenced by filename:

```bash
# Use specific override config
task megalint:run CONFIG_FILE=".mega-linter-changed.yml"

# The megalint:changed task automatically uses the changed-files override
task megalint:changed
```

### Creating Custom Overrides

Create new override configs in `.mega-linter.d/` using the EXTENDS pattern:

```yaml
EXTENDS: .mega-linter.yml
# Replace ENABLE_LINTERS to remove unwanted linters.
# DISABLE_LINTERS does NOT work for linters in the parent's ENABLE_LINTERS
# (MegaLinter checks ENABLE_LINTERS first and never evaluates DISABLE_LINTERS
# for linters already in that list).
ENABLE_LINTERS:
  - LINTER_ONE
  - LINTER_TWO
```

## Per-target overrides

A target repo can supply its own files at the workspace root to override
the shared defaults:

- **`.mega-linter.local.yml`** — recommended. The runner mounts this as
  the MegaLinter entry point and exposes the shared config alongside it
  as `.mega-linter.shared.yml`. Your local file must extend the shared
  one:

  ```yaml
  # .mega-linter.local.yml in the target repo
  EXTENDS: .mega-linter.shared.yml

  # To remove linters, provide a replacement ENABLE_LINTERS list.
  # DISABLE_LINTERS does NOT work for linters already in the parent's
  # ENABLE_LINTERS (MegaLinter's activation precedence).
  ENABLE_LINTERS:
    - BASH_SHELLCHECK
    - BASH_SHFMT
    # ... (list the linters you want, omitting those you don't)
  ```

- **`.mega-linter.yml`** — if the target already has its own top-level
  config, the runner respects it and skips mounting the shared one.

- **Sub-configs** (anything in `.mega-linter.d/`) — same rule: if the
  target supplies its own copy at its repo root, the runner uses the
  target's; otherwise the shared copy from `.mega-linter.d/` is overlaid.

Adding a new shared sub-config: drop the file into `.mega-linter.d/`.
The runner auto-discovers everything in that directory — no code or
Taskfile changes required.

## Working with SARIF output

`SARIF_REPORTER: true` is enabled by default, so every run emits
`megalinter-reports/megalinter-report.sarif`. Two helpers are available:

```bash
# Strip empty runs — keep only linters that actually reported findings
task megalint:sarif-open

# Split the SARIF into one markdown file per linter, plus an AGENTS.md
# briefing for LLM-driven remediation
task megalint:sarif-chunk

# Both honour TARGET when you've linted a different repo:
task megalint:sarif-chunk TARGET=/path/to/other/repo
```

The chunked output lands in `megalinter-reports/llm-sarif/`.
Each file is self-contained and can be handed to a worker (sub-agent,
parallel job, or sequential pass — whatever your agent harness supports) for
fix-up — see `.taskfiles/scripts/templates/megalinter-agents.md` for the
recommended workflow.

## Continuous integration

`.github/workflows/megalinter.yml` runs the same linter in CI on every push
and on PRs targeting `main`. The workflow consumes the local composite
action at `action.yml` — making the repo its own first consumer.

The workflow:

- Lints only the PR diff on pull requests (`validate-all-codebase: false`)
  and the full tree on pushes to `main`.
- Uploads `megalinter-reports/` (which contains `mega-linter.log`) as a
  workflow artifact for download.
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
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }

      - id: megalint
        uses: trevor-vaughan/megalint-config@v1
        with:
          validate-all-codebase: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}

      - uses: actions/upload-artifact@v7
        if: ${{ success() || failure() }}
        with:
          name: megalinter-reports
          path: |
            ${{ steps.megalint.outputs.reports-dir }}
            mega-linter.log

      - uses: github/codeql-action/upload-sarif@v4
        if: ${{ success() || failure() }}
        with:
          sarif_file: ${{ steps.megalint.outputs.sarif-file }}
```

Inputs: `working-directory`, `validate-all-codebase`, `megalinter-image`,
`reports-dir`, `pull-policy`, `vuln-cache-dir`. Outputs: `reports-dir`, `sarif-file`. See
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

## Custom Flavor Image

This repo builds a custom MegaLinter flavor image and publishes it to the
GitHub Container Registry. The image is a thin layer on top of the upstream
`ghcr.io/oxsecurity/megalinter:v9` base, with the linter selection from
`.mega-linter.yml` baked in.

### Image location

```
ghcr.io/trevor-vaughan/megalinter-custom-flavor
```

### Tagging scheme

Each release publishes three tags:

| Tag | Example | Meaning |
| --- | ------- | ------- |
| `latest` | `latest` | Most recent build from `main` |
| `<semver>` | `9.5.0` | Matches the upstream MegaLinter version used as the base |
| `sha-<commit>` | `sha-abc1234...` | Pinned to the exact commit that triggered the build |

Pin to a semver tag for reproducibility; use `latest` only in
development or when you want automatic upstream tracking.

### When the image is built

| Trigger | Branch | Condition |
| ------- | ------ | --------- |
| Push | `main` | Changes to `.mega-linter.yml` |
| Schedule | `main` | Weekly (Sunday 6 AM UTC) |
| Manual | any | `workflow_dispatch` with optional `base_image` input |

### Supply-chain attestation

Every published image includes:

- **SLSA provenance** (`actions/attest-build-provenance`) — records the
  build inputs, runner environment, and source commit.
- **SBOM** (`anchore/sbom-action`) — SPDX-JSON inventory of all packages
  in the image.
- **SBOM attestation** (`actions/attest-sbom`) — binds the SBOM to the
  image digest and pushes it to the registry.
- **Image vulnerability scan** (`aquasecurity/trivy-action` +
  `actions/attest`) — scans the published image for OS and language-level
  CVEs. Critical and high severity findings fail the build. The SARIF
  result is attested to the image digest.
- **Repository scan** (MegaLinter via `actions/attest`) — runs the full
  MegaLinter suite against the repository source and attests the SARIF
  output to the image digest.

Verify provenance with the GitHub CLI:

```bash
gh attestation verify \
  oci://ghcr.io/trevor-vaughan/megalinter-custom-flavor:9.5.0 \
  --owner trevor-vaughan
```

### Pulling the image

Pull the image directly:

```bash
docker pull ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest
```

Or reference it in a CI workflow:

```yaml
container: ghcr.io/trevor-vaughan/megalinter-custom-flavor:9.5.0
```

### Validation workflow

PRs that touch `.mega-linter.yml`, `scripts/**`, `tests/**`,
`pyproject.toml`, or `uv.lock` trigger the validation workflow, which
generates the flavor, builds a test Docker image, and runs a smoke test
— all without pushing to the registry.

## Contributing

Before opening a PR, run the linter locally:

```bash
task megalint:run
```

Fix what you can with `APPLY_FIXES=all`, address the rest by hand, and
commit. The CI workflow runs the same configuration, so a clean local run
is a strong signal that CI will pass.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
