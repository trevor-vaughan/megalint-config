#!/usr/bin/env bash
# Compute the release identity for the custom MegaLinter flavor.
#
# Pure function of its inputs (no network): given a git tag ref (or empty,
# for the cron/dispatch refresh lane) and the resolved upstream MegaLinter
# version, emit the image identity as `key=value` lines on stdout, suitable
# for appending to "$GITHUB_OUTPUT".
#
# Inputs (environment):
#   REF_NAME          git tag name ("v0.1.0", "v0.1.0-rc1") or "" for refresh
#   UPSTREAM_VERSION  resolved upstream base version, strict semver ("9.5.0")
#
# Outputs (stdout, one per line):
#   release_version=  version without leading "v" ("" on refresh)
#   is_prerelease=    "true"/"false"
#   composite=        "<release_version>-ml<upstream>" ("" on refresh)
#   move_latest=      "true"/"false"
#   create_release=   "true"/"false"
set -euo pipefail

REF_NAME="${REF_NAME:-}"
UPSTREAM_VERSION="${UPSTREAM_VERSION:-}"

# Upstream version must be strict MAJOR.MINOR.PATCH.
if [[ ! "${UPSTREAM_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Error: UPSTREAM_VERSION must be strict semver X.Y.Z (got '${UPSTREAM_VERSION}')" >&2
	exit 1
fi

# Refresh lane: no tag. Move :latest, cut no release, no composite.
if [[ -z "${REF_NAME}" ]]; then
	printf 'release_version=\n'
	printf 'is_prerelease=false\n'
	printf 'composite=\n'
	printf 'move_latest=true\n'
	printf 'create_release=false\n'
	exit 0
fi

# Release lane: tag must be v<semver> with optional -<prerelease>.
if [[ ! "${REF_NAME}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-([0-9A-Za-z.-]+))?$ ]]; then
	echo "Error: tag '${REF_NAME}' is not a valid release tag (expected vX.Y.Z or vX.Y.Z-PRERELEASE)" >&2
	exit 1
fi

core="${BASH_REMATCH[1]}"
prerelease="${BASH_REMATCH[3]:-}"

if [[ -n "${prerelease}" ]]; then
	release_version="${core}-${prerelease}"
	is_prerelease="true"
	move_latest="false"
else
	release_version="${core}"
	is_prerelease="false"
	move_latest="true"
fi

printf 'release_version=%s\n' "${release_version}"
printf 'is_prerelease=%s\n' "${is_prerelease}"
printf 'composite=%s-ml%s\n' "${release_version}" "${UPSTREAM_VERSION}"
printf 'move_latest=%s\n' "${move_latest}"
printf 'create_release=true\n'
