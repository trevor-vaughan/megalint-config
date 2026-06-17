#!/usr/bin/env bash
# Verify attestations on a container image using cosign.
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

# ── Skip gate ───────────────────────────────────────────────────────
if [[ "${MEGALINT_VERIFY:-}" == "skip" ]]; then
	echo "MEGALINT_VERIFY=skip — skipping attestation verification for ${IMAGE}"
	exit 0
fi

# ── Determine failure mode ──────────────────────────────────────────
# trevor-vaughan images: hard-fail on missing attestations.
# Everything else: warn unless MEGALINT_VERIFY_STRICT=true.
# Inlined at each call site to avoid SC2310 (set -e disabled in conditional).

# ── Check cosign availability ───────────────────────────────────────
if ! command -v cosign >/dev/null 2>&1; then
	if [[ "${IMAGE}" == ghcr.io/trevor-vaughan/* || "${MEGALINT_VERIFY_STRICT:-}" == "true" ]]; then
		echo "ERROR: cosign is not installed but is required to verify ${IMAGE}" >&2
		echo "Install cosign: https://docs.sigstore.dev/cosign/system_config/installation/" >&2
		exit 1
	else
		echo "WARNING: cosign not found — skipping attestation verification for ${IMAGE}"
		exit 0
	fi
fi

# ── Attestation types to verify ─────────────────────────────────────
# SBOM is attested via cosign (--type spdxjson, --tlog-upload=false)
# because the SPDX document exceeds sigstore's 16 MiB Rekor limit.
# cosign's spdxjson type maps to predicate https://spdx.dev/Document.
declare -A ATTESTATIONS=(
	["SLSA provenance"]="https://slsa.dev/provenance/v1"
	["SBOM (SPDX)"]="https://spdx.dev/Document"
	["Vulnerability scan"]="https://cosign.sigstore.dev/attestation/vuln/v1"
	["Repository scan"]="https://megalinter.io/attestation/repo-scan/v1"
)

readonly CERT_IDENTITY_RE='https://github.com/trevor-vaughan/megalint-config/.*'
readonly CERT_OIDC_ISSUER='https://token.actions.githubusercontent.com'

# ── Verify each attestation ─────────────────────────────────────────
failures=0
for name in "${!ATTESTATIONS[@]}"; do
	predicate="${ATTESTATIONS[$name]}"
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

# ── Report result ───────────────────────────────────────────────────
if [[ ${failures} -gt 0 ]]; then
	if [[ "${IMAGE}" == ghcr.io/trevor-vaughan/* || "${MEGALINT_VERIFY_STRICT:-}" == "true" ]]; then
		echo "ERROR: ${failures} attestation(s) failed verification for ${IMAGE}" >&2
		exit 1
	else
		echo "WARNING: ${failures} attestation(s) could not be verified for ${IMAGE}"
		exit 0
	fi
fi

echo "All attestations verified for ${IMAGE}"
exit 0
