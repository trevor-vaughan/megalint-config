# Changelog

All notable changes to this project are documented in this file. The format is
generated from [Conventional Commits](https://www.conventionalcommits.org) by
[git-cliff](https://git-cliff.org); do not edit it by hand — run
`task release:bump` instead.

## [unreleased]

### 🚀 Features

- *(release)* Add release:bump task for cutting releases
- *(release)* Add changelog-section.sh to extract one release's notes
  - Lives in a script rather than inline in the workflow so the bats suite exercises the same extraction CI runs.

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

### 🧪 Testing

- Cover the reporter toggle (bats) and constraint injection (pytest)
- *(release)* Add bats coverage for release-bump.sh, its semver §11 comparator, and changelog-section.sh

### ⚙️ Miscellaneous Tasks

- *(release)* Fail the release when the tag and committed version differ
  - Both sides are normalised through `uv version --dry-run`, since PEP 440 and semver disagree on pre-releases (v0.6.0-rc1 vs 0.6.0rc1).
- *(release)* Publish the CHANGELOG.md section as the GitHub release notes
  - A hand-cut tag has no section; that warns and publishes image details only rather than failing a build that is already signed and attested.
- *(megalinter)* Exclude the generated CHANGELOG.md from markdownlint
  - Commit subjects containing `_NAME` trip MD037, and the only fix would be rewriting history.

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
