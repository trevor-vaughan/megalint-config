#!/usr/bin/env bash
# Run MegaLinter against a target directory using the shared linter configs
# from this repository.
#
# Usage:
#   megalint-run.sh <shared-dir> <target-dir> <engine> <image> <apply-fixes> [pull-policy] [config_file]
#
# Two staging modes are supported:
#
# (1) In-target staging (DEFAULT, fastest)
#     Configs are copied directly into the target's workspace root, the
#     target is bind-mounted into the container, and the EXIT trap removes
#     the staged copies afterward. No prep cost beyond a handful of cp
#     operations. Trade-off: the staged files (.mega-linter.yml,
#     .secretlintignore, etc.) briefly appear in the target during the
#     run, and two concurrent runs against the same target would conflict.
#
# (2) Tempdir staging (opt-in via MEGALINT_TMPDIR=<non-empty>)
#     A private staging directory is created adjacent to the target:
#     `<parent>/.megalint_<rand>_<target-basename>/` (mode 0700,
#     dot-prefixed). The target's source tree is hardlink-cloned in via
#     `rsync --link-dest` (excluding `.git/`), the configs are staged
#     into the clone, `.git/` is bind-mounted into the container
#     read-only, and the staging dir is removed on exit after the
#     reports dir is persisted back to the target. The target tree on
#     the host is never modified, and concurrent runs are safe (each
#     gets its own random suffix). Trade-off: one rsync walk of the
#     source tree per run (sub-second on typical repos; `.git/` is
#     skipped entirely).
#
# Override rules (target wins, identical in both modes):
#   - target has `.mega-linter.local.yml`:
#       MEGALINTER_CONFIG=.mega-linter.local.yml is passed to the
#       container, and the shared `.mega-linter.yml` is staged as
#       `.mega-linter.shared.yml` so the local can EXTENDS it.
#   - target has its own `.mega-linter.yml` (no `.local`): respected,
#       shared is not staged.
#   - else: shared `.mega-linter.yml` is staged as the entry point.
#   - For each file in <shared>/.mega-linter.d/: target's non-empty
#       copy wins; otherwise shared is staged.
#
# Mount strategy:
#   - APPLY_FIXES=none (default): workspace mounted read-only with a
#     nested read-write mount of `megalinter-reports/` so MegaLinter can
#     still write findings without being able to modify anything else.
#     A tmpfs is mounted at /tmp inside the container for tool caches
#     (ruff, checkov, etc.) that need writable temp space.
#   - APPLY_FIXES != "none": workspace mounted read-write so MegaLinter
#     can rewrite source files in place.
#
# Adding a new shared sub-config: drop the file into .mega-linter.d/ in
# this repo. No code changes required.
#
# Environment variables:
#   MEGALINT_TMPDIR    Any non-empty value selects tempdir staging.
#   MEGALINT_UV        uv binary used on the changed-files path to run the
#                      FILTER_REGEX_EXCLUDE resolver. Defaults to `uv`.
#   MEGALINT_VULN_CACHE
#                      Host path for persistent vulnerability-DB cache.
#                      Bind-mounted at /tmp/xdg-cache inside the container.
#                      Defaults to ${XDG_CACHE_HOME:-$HOME/.cache}/megalint/vuln-db.
#                      Set to empty string to disable (old ephemeral behavior).
#   GITHUB_TOKEN, VALIDATE_ALL_CODEBASE, ENABLE_LINTERS, DISABLE, DISABLE_LINTERS,
#   GITHUB_REPOSITORY, GITHUB_RUN_ID, CI
#                      Forwarded to the container when set on the host.
#   MEGALINT_EXTRA_ENV_VARS
#                      Whitespace/comma/newline-separated list of additional
#                      host env var NAMES to forward into the container, on
#                      top of the built-in allowlist below. Each name is
#                      forwarded only when it is set in the host env (values
#                      stay in the caller's control). Names only — no
#                      NAME=VALUE pairs.
#
# The optional config_file argument (positional $7) sets MEGALINTER_CONFIG
# inside the container, selecting an alternate MegaLinter configuration.

set -euo pipefail

# GitHub Actions collapsible group helpers (no-op outside CI).
gh_group() { [[ "${GITHUB_ACTIONS:-}" == "true" ]] && echo "::group::$1" || true; }
gh_endgroup() { [[ "${GITHUB_ACTIONS:-}" == "true" ]] && echo "::endgroup::" || true; }

usage() {
	echo "usage: $0 <shared-dir> <target-dir> <engine> <image> <apply-fixes> [pull-policy] [config_file]" >&2
	exit 2
}

[[ $# -ge 5 && $# -le 7 ]] || usage

shared_raw="$1"
target_raw="$2"
engine="$3"
image="$4"
apply_fixes="$5"
pull_policy="${6:-never}"
config_file="${7:-}"

[[ -d "${shared_raw}" ]] || {
	echo "shared dir not found: ${shared_raw}" >&2
	exit 1
}
if [[ ! -e "${target_raw}" ]]; then
	echo "target does not exist: ${target_raw}" >&2
	exit 1
fi
if [[ ! -d "${target_raw}" ]]; then
	echo "target must be a directory: ${target_raw}" >&2
	exit 1
fi

shared=$(realpath "${shared_raw}")
target=$(realpath "${target_raw}")

SUB_CONFIG_DIR="${shared}/.mega-linter.d"

# Mode selection.
use_tempdir=false
if [[ -n "${MEGALINT_TMPDIR:-}" ]]; then
	use_tempdir=true
fi

# Tempdir staging clones the target into an ephemeral workspace and only
# persists megalinter-reports/ back on exit (see cleanup() below); any
# in-place fixes a linter makes there would be silently discarded, which
# contradicts APPLY_FIXES' whole purpose. Refuse the combination outright
# rather than let fixes vanish.
if "${use_tempdir}" && [[ "${apply_fixes}" != "none" ]]; then
	echo "MEGALINT_TMPDIR staging is incompatible with APPLY_FIXES=${apply_fixes}:" \
		"fixes made in the ephemeral clone would be discarded. Unset MEGALINT_TMPDIR" \
		"to auto-fix in place, or unset APPLY_FIXES to lint read-only." >&2
	exit 1
fi

# Vulnerability-DB cache. When set (even to the default), the host
# directory is bind-mounted at /tmp/xdg-cache so trivy/grype DBs
# survive between runs. Empty string disables caching (old behavior).
if [[ "${MEGALINT_VULN_CACHE+set}" == "set" && -z "${MEGALINT_VULN_CACHE}" ]]; then
	vuln_cache=""
else
	vuln_cache="${MEGALINT_VULN_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/megalint/vuln-db}"
fi

if [[ -n "${vuln_cache}" ]]; then
	mkdir -p "${vuln_cache}"
fi

# Env vars forwarded to the container.
FORWARDED_ENV_VARS=(
	GITHUB_TOKEN
	VALIDATE_ALL_CODEBASE
	# Changed-files runs inject a reduced ENABLE_LINTERS (full minus
	# REPOSITORY_*) as an env var; MegaLinter merges it last so it wins over
	# the file/EXTENDS chain (see changed-enable-linters.sh).
	ENABLE_LINTERS
	DISABLE
	DISABLE_LINTERS
	GITHUB_REPOSITORY
	GITHUB_RUN_ID
	CI
	# MegaLinter's console reporter emits ::group::/::endgroup:: markers
	# for collapsible sections when it detects GitHub Actions. Without
	# this var the output is one flat stream that GitHub truncates.
	GITHUB_ACTIONS
	# PR comment reporter needs GITHUB_REF (refs/pull/NNN/merge) to
	# identify the pull request, with GITHUB_SHA as a fallback.
	GITHUB_REF
	GITHUB_SHA
	# GitHub Enterprise overrides for API and web UI base URLs.
	GITHUB_SERVER_URL
	GITHUB_API_URL
	# Opt-in PR comment with lint summary (needs pull-requests: write).
	GITHUB_COMMENT_REPORTER
)
env_args=(
	-e "SHOW_ELAPSED_TIME=true"
	-e "APPLY_FIXES=${apply_fixes}"
)
for var in "${FORWARDED_ENV_VARS[@]}"; do
	if [[ -n "${!var:-}" ]]; then
		env_args+=(-e "${var}=${!var}")
	fi
done

# Surface the effective linter override so a "why didn't Checkov run on my PR"
# question is answerable from the log without a changed-config file to read.
if [[ -n "${ENABLE_LINTERS:-}" ]]; then
	echo "ENABLE_LINTERS override active: ${ENABLE_LINTERS}" >&2
fi

# Caller-extensible allowlist. MEGALINT_EXTRA_ENV_VARS is a list of
# additional variable NAMES (separated by whitespace, commas, or newlines)
# to forward from the host environment. Same allowlist semantics as
# FORWARDED_ENV_VARS above: a listed name is forwarded only when it is set
# (non-empty) in the host env, so values stay in the caller's control and an
# unset name is a safe no-op. This lets consumers pass e.g. GOPROXY /
# GONOSUMCHECK, or override GOTOOLCHAIN, without editing this script or
# inverting the allowlist to a denylist.
if [[ -n "${MEGALINT_EXTRA_ENV_VARS:-}" ]]; then
	# -d '' reads the whole (possibly multi-line) value; IFS splits it into
	# names on commas and whitespace. read returns non-zero at EOF (no NUL
	# delimiter present), which is expected here — hence `|| true`.
	IFS=$', \t\n' read -r -d '' -a extra_env_names \
		<<<"${MEGALINT_EXTRA_ENV_VARS}" || true
	for var in "${extra_env_names[@]}"; do
		[[ -n "${var}" ]] || continue
		if [[ ! "${var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
			echo "megalint-run.sh: ignoring invalid MEGALINT_EXTRA_ENV_VARS entry" \
				"'${var}' (names only; NAME=VALUE pairs and shell-special" \
				"characters are not allowed)" >&2
			continue
		fi
		if [[ -n "${!var:-}" ]]; then
			env_args+=(-e "${var}=${!var}")
		fi
	done
fi

# Set config file if provided
if [[ -n "$config_file" ]]; then
	env_args+=(-e "MEGALINTER_CONFIG=$config_file")
	echo "Using config file: $config_file"
fi

# Prep step: set `workspace` (the dir to mount as /tmp/lint), `git_is_dir`
# (whether to add a separate .git bind mount), and `staged[]` (paths
# to clean up in in-target mode). Each mode registers its own trap.
staged=()
git_is_dir=false

if "${use_tempdir}"; then
	if ! command -v rsync >/dev/null 2>&1; then
		echo "rsync is required when MEGALINT_TMPDIR is set; install rsync or unset MEGALINT_TMPDIR" >&2
		exit 1
	fi

	parent_dir=$(dirname "${target}")
	target_basename=$(basename "${target}")
	random_suffix=$(printf '%04x%04x' "${RANDOM}" "${RANDOM}")
	workspace="${parent_dir}/.megalint_${random_suffix}_${target_basename}"
	mkdir -m 0700 "${workspace}"

	cleanup() {
		# Persist reports back to target before destroying the stage.
		if [[ -d "${workspace}/megalinter-reports" ]]; then
			if ! { rm -rf "${target}/megalinter-reports" &&
				cp -a "${workspace}/megalinter-reports" \
					"${target}/megalinter-reports"; }; then
				echo "WARNING: failed to persist reports to ${target}/megalinter-reports" >&2
			fi
		fi
		rm -rf "${workspace}"
	}
	trap cleanup EXIT INT TERM HUP

	# Hardlink-clone the source tree (skip .git/, bind-mount it instead).
	git_excludes=()
	if [[ -d "${target}/.git" ]]; then
		git_is_dir=true
		git_excludes=(--exclude=".git/")
	fi
	rsync -a --link-dest="${target}" "${git_excludes[@]+"${git_excludes[@]}"}" \
		"${target}/" "${workspace}/"

	if "${git_is_dir}"; then
		mkdir -p "${workspace}/.git" # placeholder for the bind mount
	fi

	mkdir -p "${workspace}/megalinter-reports"
else
	# In-target mode: the workspace IS the target. Configs go directly
	# into the target's root and are tracked for cleanup on exit.
	workspace="${target}"

	cleanup() {
		local p
		for p in "${staged[@]:-}"; do
			rm -f "${p}"
		done
	}
	trap cleanup EXIT INT TERM HUP

	rm -rf "${target}/megalinter-reports"
	mkdir -p "${target}/megalinter-reports"
fi

# stage_in() copies a file into the workspace. In tempdir mode the
# whole workspace is ephemeral so we just write; in in-target mode we
# track the path so the trap can remove it later.
stage_in() {
	local src="$1" dst="$2"
	cp "${src}" "${dst}"
	if ! "${use_tempdir}"; then
		staged+=("${dst}")
	fi
}

gh_group "Stage shared configs into workspace"

# Main MegaLinter config. Target wins at every name we might stage:
# if the target already supplies a file, the shared copy is NOT staged
# over it. This is unconditional — a 0-byte file is treated as the
# user's choice, not a phantom to overwrite.
#
# Effective entry/base configs for the changed-run FILTER_REGEX_EXCLUDE
# derivation below. Read from the STAGED workspace — the ground truth of what
# MegaLinter loads — so the runner's "target wins" staging (a target that
# supplies its own .mega-linter.shared.yml / .mega-linter.yml) is respected and
# tempdir vs in-target staging is irrelevant. Kept in lockstep with the staging
# decisions in this same chain. The resolver runs after this block, so every
# ${workspace} path referenced here exists.
entry_config="${workspace}/.mega-linter.yml"
base_config=""

if [[ -n "$config_file" ]]; then
	# Explicit config file takes precedence; stage base config for EXTENDS.
	if [[ -f "${workspace}/.mega-linter.local.yml" ]]; then
		echo "Note: ignoring .mega-linter.local.yml in favour of config_file=${config_file}" >&2
	fi
	if [[ ! -e "${workspace}/.mega-linter.yml" ]]; then
		stage_in "${shared}/.mega-linter.yml" "${workspace}/.mega-linter.yml"
	fi
	# config_file is a full-custom escape hatch whose EXTENDS chain we do not
	# resolve. A partial injected FILTER_REGEX_EXCLUDE could DROP a value the
	# config inherits via EXTENDS (env replaces the file value), so the
	# changed-run workaround is SKIPPED entirely for config_file (see the
	# `-z "${config_file}"` gate on the injection block below). Its owner
	# controls FILTER_REGEX_EXCLUDE. entry_config/base_config are left at their
	# defaults here and go unused on this path.
elif [[ -f "${workspace}/.mega-linter.local.yml" ]]; then
	if [[ ! -e "${workspace}/.mega-linter.shared.yml" ]]; then
		stage_in "${shared}/.mega-linter.yml" "${workspace}/.mega-linter.shared.yml"
	fi
	env_args+=(-e "MEGALINTER_CONFIG=.mega-linter.local.yml")
	# base is the file actually staged (runner's copy, or the target's own if it
	# supplied one) — exactly what local EXTENDS.
	entry_config="${workspace}/.mega-linter.local.yml"
	base_config="${workspace}/.mega-linter.shared.yml"
elif [[ ! -e "${workspace}/.mega-linter.yml" ]]; then
	stage_in "${shared}/.mega-linter.yml" "${workspace}/.mega-linter.yml"
	entry_config="${workspace}/.mega-linter.yml"
	base_config=""
fi

# Sub-configs from .mega-linter.d/: target wins. Any existing file at
# the same name — even 0-byte — is the user's deliberate choice and is
# left untouched.
shopt -s nullglob dotglob
for cfg in "${SUB_CONFIG_DIR}"/*; do
	[[ -f "${cfg}" ]] || continue
	name=$(basename "${cfg}")
	staged_path="${workspace}/${name}"
	if [[ -e "${staged_path}" ]]; then
		continue
	fi
	stage_in "${cfg}" "${staged_path}"
done
shopt -u nullglob dotglob

gh_endgroup

# Changed-files runs (VALIDATE_ALL_CODEBASE=false) build their file list from
# `git diff`, which MegaLinter does NOT prune with ADDITIONAL_EXCLUDED_DIRECTORIES
# (that only prunes the full-codebase os.walk). MegaLinter DOES honor
# FILTER_REGEX_EXCLUDE on both paths, so derive a combined FILTER_REGEX_EXCLUDE
# from the effective config's excluded dirs and inject it. Env wins over the
# file/EXTENDS chain, so the resolver folds in the existing value. MEGALINT_UV
# overrides the uv binary (tests point it at a stub).
#
# WORKAROUND for https://github.com/oxsecurity/megalinter/issues/8360: remove
# this block and scripts/changed_filter_regex.py once the upstream fix ships in
# a MegaLinter release the custom flavor pins.
if [[ "${VALIDATE_ALL_CODEBASE:-}" == "false" && -z "${config_file}" ]]; then
	uv_bin="${MEGALINT_UV:-uv}"
	if ! command -v "${uv_bin}" >/dev/null 2>&1; then
		echo "megalint-run.sh: '${uv_bin}' not found on PATH — the changed-files" \
			"path needs uv to derive FILTER_REGEX_EXCLUDE from" \
			"ADDITIONAL_EXCLUDED_DIRECTORIES. Install uv or set MEGALINT_UV." >&2
		exit 1
	fi
	# Declaration split from assignment so a non-zero resolver exit trips
	# `set -e` instead of being swallowed (never `local x=$(...)` here).
	changed_filter_regex=""
	changed_filter_regex="$("${uv_bin}" run --frozen --project "${shared}" \
		python "${shared}/scripts/changed_filter_regex.py" \
		"${entry_config}" ${base_config:+"${base_config}"})"
	if [[ -n "${changed_filter_regex}" ]]; then
		env_args+=(-e "FILTER_REGEX_EXCLUDE=${changed_filter_regex}")
		echo "FILTER_REGEX_EXCLUDE override active (changed-run excluded dirs):" \
			"${changed_filter_regex}" >&2
	fi
fi

# Mount strategy.
if [[ "${apply_fixes}" == "none" ]]; then
	# shellcheck disable=SC2054 # commas are mount-option syntax, not array separators
	mounts=(
		-v "${workspace}:/tmp/lint:ro,z"
		-v "${workspace}/megalinter-reports:/tmp/lint/megalinter-reports:rw,z"
		--tmpfs /tmp:rw,exec,nosuid,nodev,size=4G
	)
	# Persistent vulnerability-DB cache (trivy, grype). The bind mount
	# overlays /tmp/xdg-cache on the tmpfs, so both coexist.
	if [[ -n "${vuln_cache}" ]]; then
		mounts+=(-v "${vuln_cache}:/tmp/xdg-cache:rw,z")
	fi
	# Configure tools to use the writable tmpfs for caches instead of
	# the read-only workspace. TMPDIR is the POSIX standard; the others
	# are tool-specific.
	#
	# Checkov quirk: its github_configuration framework persists GitHub API
	# responses to a conf dir resolved as os.path.join(os.getcwd(),
	# CKV_GITHUB_CONF_DIR_NAME). On the read-only /tmp/lint mount that
	# crashes with EROFS. The primary fix is `skip-framework:
	# github_configuration` in the Checkov config (.checkov.yml and
	# .mega-linter.d/.checkov.yml), which stops the runner from ever creating
	# the dir. The CKV_GITHUB_CONF_DIR_NAME below injects an absolute tmpfs
	# path (POSIX os.path.join returns the second arg when it is absolute) as
	# a defence-in-depth backstop for target repos that override the Checkov
	# config without the skip. NOTE: MegaLinter >= v9.6.0's
	# CheckovLinter.before_lint_files() overwrites CKV_GITHUB_CONF_DIR_NAME
	# with a relative path, defeating this backstop on the pinned base image —
	# the config skip is what protects that image.
	# In in-target mode, .git is inside the ro workspace mount. MegaLinter's
	# changed-files mode needs to write .git/FETCH_HEAD during git fetch, so
	# overlay a nested rw mount (same pattern as megalinter-reports above).
	if [[ "${VALIDATE_ALL_CODEBASE:-}" == "false" && -d "${workspace}/.git" ]] && ! "${use_tempdir}"; then
		mounts+=(-v "${workspace}/.git:/tmp/lint/.git:rw,z")
	fi
	env_args+=(
		-e "TMPDIR=/tmp"
		-e "RUFF_CACHE_DIR=/tmp/ruff-cache"
		-e "XDG_CACHE_HOME=/tmp/xdg-cache"
		-e "CKV_GITHUB_CONF_DIR_NAME=/tmp/checkov-github-conf"
	)
else
	mounts=(-v "${workspace}:/tmp/lint:rw,z")
	if [[ -n "${vuln_cache}" ]]; then
		mounts+=(-v "${vuln_cache}:/tmp/xdg-cache:rw,z")
		env_args+=(-e "XDG_CACHE_HOME=/tmp/xdg-cache")
	fi
fi

# In tempdir mode, .git was excluded from the rsync clone — bind-mount
# the target's real .git. If VALIDATE_ALL_CODEBASE=false, MegaLinter needs
# to write to .git/FETCH_HEAD during git diff operations, so mount read-write.
if "${git_is_dir}"; then
	if [[ "${VALIDATE_ALL_CODEBASE:-}" == "false" ]]; then
		echo "Mounting .git read-write for git diff operations (VALIDATE_ALL_CODEBASE=false)"
		mounts+=(-v "${target}/.git:/tmp/lint/.git:rw,z")
	else
		mounts+=(-v "${target}/.git:/tmp/lint/.git:ro,z")
	fi
fi

"${engine}" run --rm \
	"--pull=$pull_policy" \
	"${mounts[@]}" \
	"${env_args[@]}" \
	"${image}"
