#!/usr/bin/env bash
# Run MegaLinter against a target directory using the shared linter configs
# from this repository.
#
# Usage:
#   megalint-run.sh <shared-dir> <target-dir> <engine> <image> <apply-fixes> [pull-policy]
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
#   GITHUB_TOKEN, VALIDATE_ALL_CODEBASE, GITHUB_REPOSITORY,
#   GITHUB_RUN_ID, CI    Forwarded to the container when set on the host.

set -euo pipefail

usage() {
	echo "usage: $0 <shared-dir> <target-dir> <engine> <image> <apply-fixes> [pull-policy]" >&2
	exit 2
}

[[ $# -ge 5 && $# -le 6 ]] || usage

shared_raw="$1"
target_raw="$2"
engine="$3"
image="$4"
apply_fixes="$5"
pull_policy="${6:-never}"

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

# Env vars forwarded to the container.
FORWARDED_ENV_VARS=(
	GITHUB_TOKEN
	VALIDATE_ALL_CODEBASE
	GITHUB_REPOSITORY
	GITHUB_RUN_ID
	CI
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
			rm -rf "${target}/megalinter-reports"
			cp -a "${workspace}/megalinter-reports" "${target}/megalinter-reports" || true
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

# Main MegaLinter config. Target wins at every name we might stage:
# if the target already supplies a file, the shared copy is NOT staged
# over it. This is unconditional — a 0-byte file is treated as the
# user's choice, not a phantom to overwrite.
if [[ -f "${workspace}/.mega-linter.local.yml" ]]; then
	if [[ ! -e "${workspace}/.mega-linter.shared.yml" ]]; then
		stage_in "${shared}/.mega-linter.yml" "${workspace}/.mega-linter.shared.yml"
	fi
	env_args+=(-e "MEGALINTER_CONFIG=.mega-linter.local.yml")
elif [[ ! -e "${workspace}/.mega-linter.yml" ]]; then
	stage_in "${shared}/.mega-linter.yml" "${workspace}/.mega-linter.yml"
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

# Mount strategy.
if [[ "${apply_fixes}" == "none" ]]; then
	# shellcheck disable=SC2054 # commas are mount-option syntax, not array separators
	mounts=(
		-v "${workspace}:/tmp/lint:ro,z"
		-v "${workspace}/megalinter-reports:/tmp/lint/megalinter-reports:rw,z"
		--tmpfs /tmp:rw,exec,nosuid,nodev,size=4G
	)
	# Configure tools to use the writable tmpfs for caches instead of
	# the read-only workspace. TMPDIR is the POSIX standard; the others
	# are tool-specific.
	#
	# Checkov quirk (verified against checkov 3.2.529, the version
	# bundled with megalinter:v9): Github.setup_conf_dir() in
	# checkov/github/dal.py ignores CKV_GITHUB_CONF_DIR_PATH and
	# computes the directory as os.path.join(os.getcwd(),
	# CKV_GITHUB_CONF_DIR_NAME). When the workspace is mounted
	# read-only at /tmp/lint, the default name `github_conf` resolves
	# to `/tmp/lint/github_conf` and persist_all_confs() crashes with
	# EROFS. POSIX os.path.join(a, b) returns b when b is absolute, so
	# we abuse the NAME slot to inject an absolute path on the tmpfs.
	env_args+=(
		-e "TMPDIR=/tmp"
		-e "RUFF_CACHE_DIR=/tmp/ruff-cache"
		-e "XDG_CACHE_HOME=/tmp/xdg-cache"
		-e "CKV_GITHUB_CONF_DIR_NAME=/tmp/checkov-github-conf"
	)
else
	mounts=(-v "${workspace}:/tmp/lint:rw,z")
fi

# In tempdir mode, .git was excluded from the rsync clone — bind-mount
# the target's real .git in as read-only so linters can still use it.
if "${git_is_dir}"; then
	mounts+=(-v "${target}/.git:/tmp/lint/.git:ro,z")
fi

"${engine}" run --rm \
	--pull="${pull_policy}" \
	"${mounts[@]}" \
	"${env_args[@]}" \
	"${image}"
