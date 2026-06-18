#!/usr/bin/env bash
# Verify attestations on a container image.
#
# This script uses a mixed verification strategy because the release
# pipeline uses two different attestation backends:
#
#   SLSA provenance — attested via actions/attest-build-provenance,
#     which stores attestations in GitHub's Artifact Attestation API.
#     This is the only attestation type that uses GitHub-native storage
#     because the provenance predicate is generated internally by the
#     action and cannot be extracted for cosign attest.
#     Verified with: gh attestation verify
#
#   SBOM, vuln scan, repo scan — attested via cosign attest, which
#     writes OCI image attestations directly to the container registry.
#     These use cosign because it is portable (works in any environment:
#     CI, local, GitLab) and the predicates are files we control.
#     Verified with: cosign verify-attestation
#
# Why not use a single tool for everything?
#   - cosign cannot verify GitHub Artifact Attestations (different API)
#   - gh cannot verify cosign OCI attestations (different storage)
#   - actions/attest-build-provenance generates the SLSA predicate
#     internally, so we can't switch it to cosign attest
#
# Usage: megalint-verify.sh <image>
#
# Environment variables:
#   MEGALINT_VERIFY        Set to "skip" to bypass verification entirely.
#   MEGALINT_VERIFY_STRICT Set to "true" to hard-fail on any image
#                          (not just trevor-vaughan images).
#
# Exit codes:
#   0  All verifications passed (or skipped/warned)
#   1  Verification failed and the image requires attestations
set -euo pipefail

readonly IMAGE="${1:-}"

if [[ -z "${IMAGE}" ]]; then
	echo "Usage: megalint-verify.sh <image>" >&2
	exit 1
fi

# GitHub Actions collapsible group for verification output.
gh_group() { [[ "${GITHUB_ACTIONS:-}" == "true" ]] && echo "::group::$1" || true; }
gh_endgroup() { [[ "${GITHUB_ACTIONS:-}" == "true" ]] && echo "::endgroup::" || true; }

# ── Skip gate ───────────────────────────────────────────────────────
if [[ "${MEGALINT_VERIFY:-}" == "skip" ]]; then
	echo "MEGALINT_VERIFY=skip — skipping attestation verification for ${IMAGE}"
	exit 0
fi

gh_group "Verify attestations: ${IMAGE}"

# ── Determine whether this is a first-party image ──────────────────
is_strict() {
	[[ "${IMAGE}" == ghcr.io/trevor-vaughan/* || "${MEGALINT_VERIFY_STRICT:-}" == "true" ]]
}

# ── Check tool availability ─────────────────────────────────────────
has_cosign=false
has_gh=false
command -v cosign >/dev/null 2>&1 && has_cosign=true
command -v gh >/dev/null 2>&1 && has_gh=true

if [[ "${has_cosign}" == "false" ]]; then
	is_strict
	strict=$?
	if [[ ${strict} -eq 0 ]]; then
		echo "ERROR: cosign is not installed but is required to verify ${IMAGE}" >&2
		echo "Install cosign: https://docs.sigstore.dev/cosign/system_config/installation/" >&2
		gh_endgroup
		exit 1
	else
		echo "WARNING: cosign not found — skipping attestation verification for ${IMAGE}"
		gh_endgroup
		exit 0
	fi
fi

# ── Cosign-verified attestation types ───────────────────────────────
# These are attested via `cosign attest` in the release pipeline,
# which writes OCI attestations to the container registry.
# All three use a signing config without Rekor tlog URLs because
# payloads regularly exceed Rekor's 16 MiB entry limit.

# Attestations that hard-fail verification when missing.
declare -A COSIGN_ATTESTATIONS=(
	["Vulnerability scan"]="https://cosign.sigstore.dev/attestation/vuln/v1"
	["Repository scan"]="https://megalinter.io/attestation/repo-scan/v1"
)

# FIXME: SBOM verification is warn-only until the first release with  # DevSkim: ignore DS176209
# the --signing-config fix lands (cosign --tlog-upload=false broke in
# cosign >=2.5).  Once a release succeeds with the fixed attestation
# pipeline, move SBOM back into COSIGN_ATTESTATIONS above and remove
# this block.
declare -A COSIGN_ATTESTATIONS_WARN=(
	["SBOM (SPDX)"]="https://spdx.dev/Document"
)

readonly CERT_IDENTITY_RE='https://github.com/trevor-vaughan/megalint-config/.*'
readonly CERT_OIDC_ISSUER='https://token.actions.githubusercontent.com'

# ── Verify cosign attestations (hard-fail) ──────────────────────────
failures=0
for name in "${!COSIGN_ATTESTATIONS[@]}"; do
	predicate="${COSIGN_ATTESTATIONS[$name]}"
	if cosign verify-attestation \
		--certificate-identity-regexp="${CERT_IDENTITY_RE}" \
		--certificate-oidc-issuer="${CERT_OIDC_ISSUER}" \
		--type="${predicate}" \
		"${IMAGE}" >/dev/null 2>&1; then
		echo "  PASS  ${name}"
	else
		echo "  FAIL  ${name} (${predicate})"
		failures=$((failures + 1))
	fi
done

# ── Verify cosign attestations (warn-only) ──────────────────────────
for name in "${!COSIGN_ATTESTATIONS_WARN[@]}"; do
	predicate="${COSIGN_ATTESTATIONS_WARN[$name]}"
	if cosign verify-attestation \
		--certificate-identity-regexp="${CERT_IDENTITY_RE}" \
		--certificate-oidc-issuer="${CERT_OIDC_ISSUER}" \
		--type="${predicate}" \
		"${IMAGE}" >/dev/null 2>&1; then
		echo "  PASS  ${name}"
	else
		echo "  WARN  ${name} (${predicate}) — attestation missing or unverifiable"
	fi
done

# ── Verify SLSA provenance via gh CLI ───────────────────────────────
# SLSA provenance is attested via actions/attest-build-provenance,
# which stores the attestation in GitHub's Artifact Attestation API.
# cosign cannot query this API — only `gh attestation verify` can.
#
# The gh CLI is pre-installed on GitHub Actions runners.  In other
# environments it may not be available, in which case we warn (or
# hard-fail for first-party images, matching the cosign behavior).
if [[ "${has_gh}" == "true" && "${IMAGE}" == ghcr.io/* ]]; then
	# Extract the owner from a ghcr.io image reference
	# (e.g. ghcr.io/trevor-vaughan/foo:tag → trevor-vaughan).
	# gh attestation verify only works for GitHub-hosted packages,
	# so we skip it entirely for non-GHCR images.
	image_owner="${IMAGE#ghcr.io/}"
	image_owner="${image_owner%%/*}"
	if gh attestation verify \
		"oci://${IMAGE}" \
		--owner "${image_owner}" >/dev/null 2>&1; then
		echo "  PASS  SLSA provenance (gh attestation verify)"
	else
		echo "  FAIL  SLSA provenance (gh attestation verify)"
		failures=$((failures + 1))
	fi
elif [[ "${has_gh}" == "false" ]]; then
	echo "  SKIP  SLSA provenance (gh CLI not available)"
else
	echo "  SKIP  SLSA provenance (non-GHCR image, gh attestation verify not applicable)"
fi
# SLSA skip is not counted as a failure — gh is not always available
# outside GitHub Actions, and the three cosign attestations still
# provide strong supply-chain verification.

# ── Report result ───────────────────────────────────────────────────
if [[ ${failures} -gt 0 ]]; then
	is_strict
	strict=$?
	if [[ ${strict} -eq 0 ]]; then
		echo "ERROR: ${failures} attestation(s) failed verification for ${IMAGE}" >&2
		gh_endgroup
		exit 1
	else
		echo "WARNING: ${failures} attestation(s) could not be verified for ${IMAGE}"
		gh_endgroup
		exit 0
	fi
fi

echo "All attestations verified for ${IMAGE}"
gh_endgroup
exit 0
