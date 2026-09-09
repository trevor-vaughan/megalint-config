# Changelog

All notable changes to this project are documented in this file. The format is
generated from [Conventional Commits](https://www.conventionalcommits.org) by
[git-cliff](https://git-cliff.org); do not edit it by hand — run
`task release:bump` instead.

## [0.6.0] - 2026-09-09

### 🚀 Features

- *(flavor)* Install v10 apk_build packages as a virtual group
- *(config)* Adopt MegaLinter v10 linter set and options
- *(config)* Set ENABLE_DISABLE_LINTERS_PRIORITY to DISABLE
  - Repositories inheriting this config through EXTENDS can now subtract a linter instead of restating the whole list. No behaviour change here, since the two lists are disjoint, and a test keeps them that way — an overlap would switch a linter off with nothing in the log to say so.
- *(config)* Swap MARKDOWN_MARKDOWN_LINK_CHECK for SPELL_LYCHEE
  - Link checking now goes over the network, so it can trip on rate limits and dead third-party links; disable it via DISABLE_LINTERS if that is not wanted.
- *(config)* Raise timeouts for the whole-repository scanners
  - V10 defaults LINTER_TIMEOUT_SECONDS to 300 and kills anything slower with exit code 124. Trivy, Grype, Checkov, TruffleHog, golangci-lint and lychee get 600-900s; the global default stays as a guard against a genuinely hung linter.

### 🐛 Bug Fixes

- *(flavor)* Anchor uv injections on v10 section markers
- *(flavor)* Splice the constraints flag after `--system` instead of rewriting the install target
  - Preserves whatever spec upstream installs (v10 ships `-e ".[llm]"`), which a hardcoded `-e .` was silently dropping
- *(flavor)* Raise when a section marker is present but its command line is gone, rather than emitting an unconstrained Dockerfile
- *(config)* Drop linters v10 removed outright
  - MAKEFILE_CHECKMAKE and API_SPECTRAL are gone with their descriptors, so Makefile and OpenAPI linting are no longer available from MegaLinter at all — the config records the gap so it does not read as an oversight. The REPOSITORY_GITLEAKS and REPOSITORY_KICS disables go too, since naming a linter that cannot run only costs a startup notice.
- *(flavor)* Relax upstream's exact Alpine package pins to a floor

### 📚 Documentation

- Document MegaLinter 10 linter set and override rules
- *(readme)* Describe subtracting linters with DISABLE_LINTERS
  - V10 adds ENABLE_DISABLE_LINTERS_PRIORITY, so extending configs no longer have to restate ENABLE_LINTERS wholesale to drop one linter. A linter named in both lists is now silently switched off.
- *(readme)* Record the three withdrawn linters that touched this profile
  - Makefile and OpenAPI/AsyncAPI linting are gone from MegaLinter itself, not just from this profile, and have no replacement. The old link checker is now SPELL_LYCHEE, which makes outbound requests and can fail on rate limits or third-party outages.
- *(readme)* Explain why REPOSITORY_KICS left DISABLE_LINTERS
  - V10 removed the linter, so there is nothing left to disable.
- *(config)* Note that v10 removed REPOSITORY_GITLEAKS outright
- Bump version references from 9.6.0 to 10.0.0
  - Covers the flavor generation guide, the published image tags, and the v9 image example in the release workflow comment.

### 🧪 Testing

- *(flavor)* Move the fixtures to the v10 template shape and cover line splitting, target-spec preservation, and both new guard paths
- *(flavor)* Cover apk_build collection, dedup, and bracketing
  - Asserts build-only packages stay out of the shipped image, that the open block carries no dangling line continuation, and that a flavor without apk_build generates unchanged output.
- *(config)* Add a removed-linter guard and cover the new options
  - V10 keeps removed keys valid in the JSON schema, so a stale entry whose descriptor survives passes every other check. An explicit list from upstream's removed_linters.py catches those. The KICS test narrows to absence from ENABLE_LINTERS, which is the assertion that was ever load-bearing — the flavor is generated from that list alone — and the security rationale moves into a config comment.

### ⚙️ Miscellaneous Tasks

- *(deps)* Bump GitHub Actions and pytest versions
- *(deps)* Bump actions/checkout from v6.0.2 to v7.0.1
- *(deps)* Bump actions/cache from v5.0.5 to v6.1.0
  - ESM migration, no config changes needed on our side
- *(deps)* Bump docker/setup-buildx-action from v3.10.0 to v4.3.0
- *(deps)* Bump docker/login-action from v3.4.0 to v4.6.0
  - Moves to the Node 24 runtime, which GitHub-hosted runners already provide
- *(deps)* Bump astral-sh/setup-uv from v8.1.0 to v10.0.1
  - V10's cache-poisoning guard only kicks in when enable-cache is "auto"; this repo sets it to true explicitly, so behavior is unchanged
- *(deps)* Bump go-task/setup-task from v2.1.0 to v2.2.0
- *(deps)* Raise pytest floor from >=7.0.0 to >=8.0.0

## [0.5.1] - 2026-08-26

### 🚀 Features

- *(release)* Add release:bump task for cutting releases
- *(release)* Add changelog-section.sh to extract one release's notes
  - Lives in a script rather than inline in the workflow so the bats suite exercises the same extraction CI runs.
- *(changelog)* Harvest conventional bullets from commit bodies

### 🐛 Bug Fixes

- Retry transient attestation-verify failures and surface the error
- Disable updated-sources reporter on read-only runs
- *(flavor)* Pin runtime python deps to upstream uv.lock
  - MEGALINTER_VERSION pins the upstream source, not the shipped image. Upstream leaves several deps unpinned in pyproject.toml and installs with a bare `uv pip install --system -e .` that re-resolves them against PyPI on every build, so the uv.lock its builder stage consumes never reaches the image. On 2026-08-19 multiprocessing-logging 0.4.0 added a fork-only assertion; the pinned python:3.14 base defaults to forkserver (CPython gh-84559), crashing MegaLinter on startup from an otherwise unchanged MEGALINTER_VERSION. The generator now exports the lock to a constraints file and applies it to the runtime install (--no-hashes, since `-e .` cannot be hashed), and raises if the upstream anchor text is missing.
- *(release)* Reset the project version from 0.5.1 to 0.5.0
  - 0.5.1 was never released and the newest tag is v0.5.0, so the tag/version check would have failed on the first run.

### 📚 Documentation

- Document the reporter toggle and uv.lock pinning; correct the tempdir .git note (changed-files runs mount it read-write)
- *(release)* Rewrite the README release section and add docs/dev/releasing.md covering the invariants the script enforces
- *(release)* Document the commit-body convention and its two consequences for version selection and `chore(release)` bullets

### 🧪 Testing

- Cover the reporter toggle (bats) and constraint injection (pytest)
- *(release)* Add bats coverage for release-bump.sh, its semver §11 comparator, and changelog-section.sh
- *(changelog)* Add bats coverage for body-bullet harvesting
  - Runs the real git-cliff rather than a stub, since the behaviour under test is cliff.toml itself.

### ⚙️ Miscellaneous Tasks

- *(release)* Fail the release when the tag and committed version differ
  - Both sides are normalised through `uv version --dry-run`, since PEP 440 and semver disagree on pre-releases (v0.6.0-rc1 vs 0.6.0rc1).
- *(release)* Publish the CHANGELOG.md section as the GitHub release notes
  - A hand-cut tag has no section; that warns and publishes image details only rather than failing a build that is already signed and attested.
- *(megalinter)* Exclude the generated CHANGELOG.md from markdownlint
  - Commit subjects containing `_NAME` trip MD037, and the only fix would be rewriting history.
- *(changelog)* Group `build` with the other maintenance types
  - Hoisting surfaces the `build(...)` entries this project writes, which would otherwise fall through to the catch-all "Other" group.

## [0.5.0] - 2026-07-09

### 🚀 Features

- Derive changed-run linters and exclude regex at run time

## [0.4.0] - 2026-07-07

### 🚀 Features

- Default GOTOOLCHAIN=auto and forward caller-listed env vars

## [0.3.0] - 2026-07-05

### 🚀 Features

- Add language linters, drop KICS, add config tests and run timeout

### 🐛 Bug Fixes

- Resolve silent-failure and correctness bugs found in deep review
- Skip Checkov github_configuration to stop read-only-mount EROFS

## [0.2.0] - 2026-07-01

### 🚀 Features

- Upgrade MegaLinter base to 9.6.0 and adopt betterleaks

## [0.1.3] - 2026-06-22

### 🚀 Features

- Add CI output grouping, job summary, and PR comment reporter

### 🐛 Bug Fixes

- Unify attestation pipeline on cosign and add gh-based SLSA verification
- Align cosign attestation verification with no-Rekor signing and gate publishing on it
- Stabilize flavor-validation artifact and harden Docker Hub pulls

## [0.1.2] - 2026-06-17

### 🚀 Features

- Default to custom flavor image with cosign attestation verification

### 🐛 Bug Fixes

- Exclude megalinter-reports from trivy scan to prevent loop

## [0.1.0] - 2026-06-04

### 🚀 Features

- Shared MegaLinter runner with portable target staging
- Enable markdown link-check and table-formatter linters
- Add config inheritance for changed-files mode and YAML Prettier linter
- Dogfood composite action and enable zizmor security scanner
- Add shared Checkov config and enable zizmor in changed-files mode
- Add custom MegaLinter flavor generation system
- Make custom flavor releases tag-driven
- Harden Dockerfiles, attest vuln scans, cache vuln DBs

### 🐛 Bug Fixes

- Skip Checkov github framework that crashes on read-only mount
- Use correct Checkov framework name `github_configuration`
- Remove global actionlint shellcheck/pyflakes overrides
- Add tmpfs mount for tool caches when workspace is read-only
- Redirect Checkov github_configuration conf dir via _NAME slot
- Mount .git read-write when VALIDATE_ALL_CODEBASE=false
- Mount .git read-write in in-target mode for changed-files
- Skip unfixed CVEs in release Trivy scan
- Make Trivy scans informational and add to PR workflow
- Use default custom-flavor path in CI workflows
- Make SBOM attestation non-blocking in release workflow

### 🚜 Refactor

- Move CONTAINER_ENGINE override to job-level env
- Improve code quality and eliminate duplication

### 📚 Documentation

- Harden and generalize MegaLinter remediation briefing

### 🎨 Styling

- Clear MegaLinter shfmt and markdown warnings
