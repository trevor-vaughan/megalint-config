#!/usr/bin/env bash
# release-bump.sh — bump the release version, regenerate CHANGELOG.md, commit
# and tag. Driven by `task release:bump`.
#
# Nothing is pushed. The tag stays local until the operator pushes it, which is
# what triggers .github/workflows/custom-flavor-release.yml.
#
# Env:
#   ROOT_DIR              repository to operate on (default: this checkout)
#   GIT_CLIFF             git-cliff command (default: uvx git-cliff@2.13.1)
#   RELEASE_BUMP_LIB_ONLY when set, define functions and return without acting
set -euo pipefail

# Pre-release identifiers are compared "lexically in ASCII sort order"
# (semver §11). Locale-aware collation would reorder them.
export LC_ALL=C

# Echo the natural next version after <version>, used whenever git-cliff cannot
# infer a bump. Finalising a pre-release means dropping the pre-release, not
# moving the patch: the next version after 0.6.0-rc.1 is 0.6.0, not 0.6.1.
patch_bump() {
	local core="${1%%-*}"
	if [[ "${1}" != "${core}" ]]; then
		printf '%s\n' "${core}"
		return 0
	fi
	local major minor patch
	IFS=. read -r major minor patch <<<"${core}"
	printf '%s.%s.%s\n' "${major}" "${minor}" "$((patch + 1))"
}

# Compare two semantic versions. Returns 0 when equal, 1 when $1 is greater,
# 2 when $2 is greater. Implements semver §11 precedence directly: sort -V
# cannot be used because it orders 1.0.0 before 1.0.0-alpha, which is backwards.
semver_cmp() {
	local a="${1}" b="${2}"
	local a_core="${a%%-*}" b_core="${b%%-*}"
	local a_pre="" b_pre=""
	[[ "${a}" == *-* ]] && a_pre="${a#*-}"
	[[ "${b}" == *-* ]] && b_pre="${b#*-}"

	local -a a_num b_num
	IFS=. read -r -a a_num <<<"${a_core}"
	IFS=. read -r -a b_num <<<"${b_core}"

	local i
	for i in 0 1 2; do
		if ((10#${a_num[i]:-0} > 10#${b_num[i]:-0})); then
			return 1
		fi
		if ((10#${a_num[i]:-0} < 10#${b_num[i]:-0})); then
			return 2
		fi
	done

	# A version with a pre-release is lower than the same version without one.
	if [[ -z "${a_pre}" && -z "${b_pre}" ]]; then
		return 0
	fi
	if [[ -z "${a_pre}" ]]; then
		return 1
	fi
	if [[ -z "${b_pre}" ]]; then
		return 2
	fi

	local -a a_ids b_ids
	IFS=. read -r -a a_ids <<<"${a_pre}"
	IFS=. read -r -a b_ids <<<"${b_pre}"

	local shared=${#a_ids[@]}
	if ((${#b_ids[@]} < shared)); then
		shared=${#b_ids[@]}
	fi

	local x y
	for ((i = 0; i < shared; i++)); do
		x="${a_ids[i]}"
		y="${b_ids[i]}"
		if [[ "${x}" == "${y}" ]]; then
			continue
		fi
		if [[ "${x}" =~ ^[0-9]+$ && "${y}" =~ ^[0-9]+$ ]]; then
			if ((10#${x} > 10#${y})); then
				return 1
			fi
			return 2
		fi
		# Numeric identifiers always rank lower than alphanumeric ones.
		if [[ "${x}" =~ ^[0-9]+$ ]]; then
			return 2
		fi
		if [[ "${y}" =~ ^[0-9]+$ ]]; then
			return 1
		fi
		if [[ "${x}" > "${y}" ]]; then
			return 1
		fi
		return 2
	done

	# All shared identifiers equal: the longer list has higher precedence.
	if ((${#a_ids[@]} > ${#b_ids[@]})); then
		return 1
	fi
	if ((${#a_ids[@]} < ${#b_ids[@]})); then
		return 2
	fi
	return 0
}

# True when <candidate> has strictly higher precedence than <current>.
# semver_cmp returns 2 for "less than", which `set -e` would treat as fatal at
# the call site, so its status is captured rather than tested directly.
is_greater() {
	local status=0
	# shellcheck disable=SC2310 # capturing semver_cmp's status is the point;
	# it returns 2 for "less than", which set -e would otherwise treat as fatal
	semver_cmp "${2}" "${1}" || status=$?
	[[ "${status}" -eq 1 ]]
}

if [[ -n "${RELEASE_BUMP_LIB_ONLY:-}" ]]; then
	return 0
fi

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GIT_CLIFF="${GIT_CLIFF:-uvx git-cliff@2.13.1}"
GIT_CLIFF_VERSION="2.13.1"

# Accepted input: semver with an optional pre-release. The real gate is the
# PEP 440 normalisation below — this only rejects obvious nonsense early.
INPUT_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
# Accepted PEP 440 output: a release, or an alpha/beta/rc pre-release. `uv`
# also produces `.post1` and `.dev1` forms, which have no semver equivalent and
# no meaning for this project's tags; they are refused rather than
# mistranslated.
PEP440_RE='^[0-9]+\.[0-9]+\.[0-9]+((a|b|rc)[0-9]+)?$'

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# Translate a PEP 440 version into its semver equivalent for comparison:
# 0.6.0rc1 -> 0.6.0-rc.1. The dotted identifier matters — it makes rc.9 sort
# before rc.10, which "rc9" against "rc10" would not.
pep440_to_semver() {
	sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)(a|b|rc)([0-9]+)$/\1-\2.\3/' <<<"${1}"
}

# Translate a PEP 440 version into the git tag form this project uses:
# 0.6.0rc1 -> 0.6.0-rc1, which scripts/compute-release-version.sh accepts.
pep440_to_tag() {
	sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)(a|b|rc)([0-9]+)$/\1-\2\3/' <<<"${1}"
}

# Normalise a version through uv, which owns PEP 440. Fails when uv rejects it.
normalise() {
	(cd "${ROOT_DIR}" && uv version --dry-run --short --frozen "${1}" 2>/dev/null)
}

command -v uv >/dev/null 2>&1 ||
	die "uv not found; install it from https://docs.astral.sh/uv/"

if ! command -v "${GIT_CLIFF%% *}" >/dev/null 2>&1; then
	printf 'error: git-cliff not found (tried "%s").\n' "${GIT_CLIFF}" >&2
	printf 'Install uv (which provides uvx) or set GIT_CLIFF to a git-cliff v%s binary:\n' \
		"${GIT_CLIFF_VERSION}" >&2
	printf '  https://git-cliff.org/docs/installation/\n' >&2
	exit 1
fi

[[ -f "${ROOT_DIR}/pyproject.toml" ]] || die "no pyproject.toml in ${ROOT_DIR}"
[[ -f "${ROOT_DIR}/cliff.toml" ]] || die "no cliff.toml in ${ROOT_DIR}"

if ! git -C "${ROOT_DIR}" diff --quiet || ! git -C "${ROOT_DIR}" diff --cached --quiet; then
	die "working tree has uncommitted changes; commit or stash them first"
fi

current="$(cd "${ROOT_DIR}" && uv version --short)"
[[ "${current}" =~ ${PEP440_RE} ]] ||
	die "project version (${current}) is not a supported release version"
current_semver="$(pep440_to_semver "${current}")"
# The tag form of the committed version, for comparison against the newest tag.
current_tag="$(pep440_to_tag "${current}")"

# --abbrev=0 yields the nearest reachable tag rather than a describe string.
# The match pattern keeps this repository's riotbox-checkpoint/* tags out of
# the answer; cliff.toml's tag_pattern does the same for git-cliff.
last_tag="$(git -C "${ROOT_DIR}" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"

if [[ -z "${last_tag}" ]]; then
	printf 'note: no v* release tag found; suggesting a patch bump instead of reading the commit history\n' >&2
	suggested="$(patch_bump "${current_semver}")"
elif [[ "${last_tag#v}" != "${current_tag}" ]]; then
	printf 'warning: last release tag %s does not match the project version (%s); suggesting a patch bump instead of reading the commit history\n' \
		"${last_tag}" "${current}" >&2
	suggested="$(patch_bump "${current_semver}")"
else
	# Unquoted on purpose: the default is the two-word command
	# `uvx git-cliff@2.13.1` and has to split into argv.
	# shellcheck disable=SC2086
	suggested="$(${GIT_CLIFF} --config "${ROOT_DIR}/cliff.toml" --repository "${ROOT_DIR}" --bumped-version 2>/dev/null || true)"
	suggested="${suggested#v}"
	[[ "${suggested}" =~ ${INPUT_RE} ]] ||
		die "git-cliff returned an unusable version ('${suggested}')"
	# With nothing releasable since the tag, git-cliff echoes the tag back.
	# shellcheck disable=SC2310 # is_greater is a pure comparison; a false
	# answer is the branch condition, not an error to propagate
	if ! is_greater "${current_semver}" "${suggested}"; then
		printf 'note: no releasable commits since %s; suggesting a patch bump\n' "${last_tag}" >&2
		suggested="$(patch_bump "${current_semver}")"
	fi
fi

new="${1:-}"
if [[ -z "${new}" ]]; then
	printf 'Current version: %s\n' "${current}" >&2
	printf 'New version [%s]: ' "${suggested}" >&2
	# read fails on EOF, which is how a closed stdin reaches us. Failing here
	# beats defaulting silently: a scripted caller that meant to pass a version
	# would otherwise cut a release nobody chose.
	IFS= read -r reply ||
		die "no version given and stdin is closed; pass one as an argument (task release:bump -- ${suggested})"
	new="${reply:-${suggested}}"
fi

[[ "${new}" =~ ${INPUT_RE} ]] ||
	die "'${new}' is not a semantic version (expected MAJOR.MINOR.PATCH[-PRERELEASE])"

# shellcheck disable=SC2310 # the failure is handled here by `|| die`, which is
# stricter than letting set -e abort with no message
new_pep="$(normalise "${new}")" ||
	die "'${new}' is not a version uv can represent"
[[ "${new_pep}" =~ ${PEP440_RE} ]] ||
	die "'${new}' normalises to '${new_pep}', which is not a supported release version (use a plain release or an alpha/beta/rc pre-release)"

new_semver="$(pep440_to_semver "${new_pep}")"
new_tag="v$(pep440_to_tag "${new_pep}")"

# shellcheck disable=SC2310 # a false comparison is the error case and is
# reported by `|| die`; there is no status worth propagating to set -e
is_greater "${current_semver}" "${new_semver}" ||
	die "${new_pep} is not greater than the current version ${current}"
if git -C "${ROOT_DIR}" rev-parse -q --verify "refs/tags/${new_tag}" >/dev/null 2>&1; then
	die "tag ${new_tag} already exists"
fi

# uv writes pyproject.toml and uv.lock together, so the two cannot drift.
# --no-sync leaves .venv alone; a release does not need the environment rebuilt.
(cd "${ROOT_DIR}" && uv version --no-sync "${new_pep}" >/dev/null)

# Regenerate the whole file rather than prepending. The release commit written
# below is skipped by cliff.toml's commit_parsers, so a later full regeneration
# reproduces this same content — a prepend would drift the moment history is
# rewritten or the config changes.
# shellcheck disable=SC2086
${GIT_CLIFF} \
	--config "${ROOT_DIR}/cliff.toml" \
	--repository "${ROOT_DIR}" \
	--tag "${new_tag}" \
	--output "${ROOT_DIR}/CHANGELOG.md"

git -C "${ROOT_DIR}" add pyproject.toml uv.lock CHANGELOG.md
git -C "${ROOT_DIR}" commit -qm "chore(release): ${new_tag}"
git -C "${ROOT_DIR}" tag -a "${new_tag}" -m "${new_tag}"

printf "✅ Released %s — run 'git push --follow-tags' when ready\\n" "${new_tag}"
