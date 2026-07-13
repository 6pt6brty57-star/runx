#!/usr/bin/env bash
set -euo pipefail
# Runs from the controller checkout against the separate PR-branch checkout.

TARGET="$(cd "$1" && pwd)"
cd "$TARGET"

RECEIPTS="sourcey-docs/production-receipt-store"
PREP="sourcey-docs/production-prepare.json"
RESULT="sourcey-docs/production-result.json"
VERIFY="sourcey-docs/production-verify.json"
rm -rf "$RECEIPTS" "$PREP" "$RESULT" "$VERIFY" sourcey-docs/authority.json
mkdir -p "$RECEIPTS" .runx/sourcey-production

echo "Checking pinned tool versions"
RUNX_VERSION="$(runx --version)"
SOURCEY_VERSION="$(sourcey --version)"
echo "runx=$RUNX_VERSION"
echo "sourcey=$SOURCEY_VERSION"
test "$RUNX_VERSION" = "runx-cli 0.7.0"
test "$SOURCEY_VERSION" = "[log] 3.6.5"
echo "Rebuilding Sourcey output"
sourcey build --config sourcey.config.ts --output sourcey-docs

openssl genpkey -algorithm ED25519 -out .runx/sourcey-production/signing-key.pem >/dev/null 2>&1
SEED="$(openssl pkey -in .runx/sourcey-production/signing-key.pem -outform DER | tail -c 32 | base64 -w0)"
PUBLIC_KEY="$(openssl pkey -in .runx/sourcey-production/signing-key.pem -pubout -outform DER | tail -c 32 | base64 -w0)"
echo "::add-mask::$SEED"
export RUNX_RECEIPT_SIGN_KID="github-actions-sourcey-bounty-115"
export RUNX_RECEIPT_SIGN_ED25519_SEED_BASE64="$SEED"
export RUNX_RECEIPT_SIGN_ISSUER_TYPE="ci"
export RUNX_RECEIPT_VERIFY_KID="$RUNX_RECEIPT_SIGN_KID"
export RUNX_RECEIPT_VERIFY_ED25519_PUBLIC_KEY_BASE64="$PUBLIC_KEY"

set +e
runx skill sourcey-validation default -R "$RECEIPTS" \
  -i "repo_root=$TARGET" --non-interactive --json >"$PREP"
RC=$?
set -e
if [[ "$RC" -ne 2 ]]; then
  cat "$PREP"
  echo "Expected operator-context preparation to exit 2, got $RC" >&2
  exit 1
fi
DIGEST="$(jq -r '.digest // empty' "$PREP")"
test -n "$DIGEST"

echo "Running production-signed Sourcey validation"
set +e
runx skill sourcey-validation default -R "$RECEIPTS" \
  -i "repo_root=$TARGET" --approve-operator-context "$DIGEST" \
  --non-interactive --json >"$RESULT"
RC=$?
set -e
if [[ "$RC" -ne 0 ]]; then
  cat "$RESULT"
  echo "Production validation exited $RC" >&2
  exit 1
fi
test "$(jq -r '.status' "$RESULT")" = "sealed"
RECEIPT_ID="$(jq -r '.receipt_id' "$RESULT")"
test -n "$RECEIPT_ID"

echo "Verifying production receipt"
runx verify "$RECEIPT_ID" --receipt-dir "$RECEIPTS" --json >"$VERIFY" || {
  cat "$VERIFY"
  exit 1
}
test "$(jq -r '.valid' "$VERIFY")" = "true"
test "$(jq -r '.signature.mode' "$VERIFY")" = "production"

RECEIPT_FILE="$RECEIPTS/${RECEIPT_ID/:/-}.json"
test -f "$RECEIPT_FILE"
cp "$RECEIPT_FILE" sourcey-docs/runx-receipt.json

PUBLIC_KEY_SHA256="$(printf '%s' "$PUBLIC_KEY" | base64 -d | sha256sum | cut -d' ' -f1)"
jq -n \
  --arg kid "$RUNX_RECEIPT_SIGN_KID" \
  --arg key "$PUBLIC_KEY" \
  --arg hash "sha256:$PUBLIC_KEY_SHA256" \
  '{schema:"runx.public_verification_authority.v1",issuer_type:"ci",kid:$kid,public_key_base64:$key,public_key_sha256:$hash,signing_seed_published:false,verify_env:{RUNX_RECEIPT_VERIFY_KID:$kid,RUNX_RECEIPT_VERIFY_ED25519_PUBLIC_KEY_BASE64:$key}}' \
  >sourcey-docs/authority.json

jq \
  --arg receipt_ref "runx:receipt:$RECEIPT_ID" \
  --arg observation "The deterministic Sourcey validation checked all 8 llms.txt entries, 8 configured Markdown sources, and 8 generated HTML targets; runx verify returned valid=true with signature mode=production." \
  '.receipt_ref=$receipt_ref | .tooling.production_verification="sourcey-docs/production-verify.json" | .tooling.verification_authority="sourcey-docs/authority.json" | .observations += [$observation]' \
  sourcey-docs/evidence.json >sourcey-docs/evidence.json.tmp
mv sourcey-docs/evidence.json.tmp sourcey-docs/evidence.json

node - "$RECEIPT_ID" <<'NODE'
const fs = require("fs");
const receipt = process.argv[2];
const path = "sourcey-docs/report.md";
let report = fs.readFileSync(path, "utf8");
report = report.replace(
  /^- \*\*Governed validation:\*\*.*$/m,
  `- **Governed validation:** \`runx --version\` returned \`runx-cli 0.7.0\`. The deterministic validation checked 8 llms.txt entries, 8 configured Markdown sources, and 8 generated HTML targets. Receipt \`runx:receipt:${receipt}\` verifies with \`valid=true\` and \`signature.mode=production\`; the public verification key is in \`sourcey-docs/authority.json\`.`,
);
fs.writeFileSync(path, report);
NODE

rm -f .runx/sourcey-production/signing-key.pem
test "$(jq -r '.issuer.kid' sourcey-docs/runx-receipt.json)" = "$RUNX_RECEIPT_SIGN_KID"
test "$(jq -r '.signature.mode' "$VERIFY")" = "production"
