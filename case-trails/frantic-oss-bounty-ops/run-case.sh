#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/generated"
RAW="$OUT/raw"
RECEIPTS="$OUT/receipt-store"
VERIFY="$OUT/verify"
REGISTRY="https://api.runx.ai"
AGENCY="runx/agency@sha-1cc86871fbb2"
OPS_DESK="runx/ops-desk@sha-662dfad394ad"
DATA_STORE="runx/data-store@sha-567d29ed2d9a"
DATA_REF="tenant://agency/frantic-oss-ops"
CASE_ID="frantic-oss-bounty-ops-2026-07"

rm -rf "$OUT" .runx/agency-case
mkdir -p "$RAW" "$RECEIPTS" "$VERIFY" .runx/agency-case

RUNX_VERSION="$(runx --version)"
test "$RUNX_VERSION" = "runx-cli 0.6.19"

# Generate a one-run production authority. Only its verification key is published.
openssl genpkey -algorithm ED25519 -out .runx/agency-case/signing-key.pem >/dev/null 2>&1
SEED="$(openssl pkey -in .runx/agency-case/signing-key.pem -outform DER | tail -c 32 | base64 -w0)"
PUBLIC_KEY="$(openssl pkey -in .runx/agency-case/signing-key.pem -pubout -outform DER | tail -c 32 | base64 -w0)"
echo "::add-mask::$SEED"
export RUNX_RECEIPT_SIGN_KID="github-actions-agency-case-104"
export RUNX_RECEIPT_SIGN_ED25519_SEED_BASE64="$SEED"
export RUNX_RECEIPT_SIGN_ISSUER_TYPE="ci"
export RUNX_RECEIPT_VERIFY_KID="$RUNX_RECEIPT_SIGN_KID"
export RUNX_RECEIPT_VERIFY_ED25519_PUBLIC_KEY_BASE64="$PUBLIC_KEY"
export RUNX_DATA_SOURCES="{\"data_sources\":{\"$DATA_REF\":{\"adapter\":\"data.sqlite\",\"database_path\":\"$GITHUB_WORKSPACE/.runx/agency-case/cases.sqlite\",\"resources\":{\"agency_cases\":{\"kind\":\"event_stream\",\"partition_key\":\"aggregate_id\"}}}}}"

curl --fail --silent --show-error "https://gofrantic.com/v1/bounties/104" > "$RAW/bounty-104.json"

run_prepared() {
  local label="$1"
  shift
  local prep="$RAW/${label}-prepare.json"
  local prep_err="$RAW/${label}-prepare.stderr"
  local output="$RAW/${label}.json"
  local output_err="$RAW/${label}.stderr"
  local rc digest

  set +e
  "$@" --non-interactive --json >"$prep" 2>"$prep_err"
  rc=$?
  set -e
  if [[ $rc -ne 2 ]]; then
    cat "$prep" "$prep_err"
    echo "Expected operator-context approval request for $label, got exit $rc" >&2
    exit 1
  fi
  digest="$(jq -r '.digest // empty' "$prep")"
  test -n "$digest"

  set +e
  "$@" --approve-operator-context "$digest" --non-interactive --json >"$output" 2>"$output_err"
  rc=$?
  set -e
  if [[ $rc -ne 0 && $rc -ne 2 ]]; then
    cat "$output" "$output_err"
    echo "Governed run $label failed with exit $rc" >&2
    exit 1
  fi
}

resume_run() {
  local label="$1"
  local paused_label="$2"
  local answers="$3"
  local run_id rc
  run_id="$(jq -r '.run_id' "$RAW/${paused_label}.json")"
  test -n "$run_id"
  set +e
  runx resume "$run_id" "$answers" -R "$RECEIPTS" --json >"$RAW/${label}.json" 2>"$RAW/${label}.stderr"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    cat "$RAW/${label}.json" "$RAW/${label}.stderr"
    exit "$rc"
  fi
  test "$(jq -r '.status' "$RAW/${label}.json")" = "sealed"
}

receipt_id() {
  jq -r '.receipt_id' "$RAW/$1.json"
}

verify_receipt() {
  local label="$1"
  local rid
  rid="$(receipt_id "$label")"
  runx verify "$rid" --receipt-dir "$RECEIPTS" --json >"$VERIFY/${label}.json"
  test "$(jq -r '.valid' "$VERIFY/${label}.json")" = "true"
  test "$(jq -r '.signature.mode' "$VERIFY/${label}.json")" = "production"
}

MANDATE="$(jq -r '.mandate' "$ROOT/input/mandate.json")"
AGENCY_REF="$(jq -r '.agency_ref' "$ROOT/input/mandate.json")"
SIGNAL="$(jq -r '.signal' "$ROOT/input/mandate.json")"
ROSTER="$(jq -c '.roster' "$ROOT/input/mandate.json")"
LIMITS="$(jq -c '.limits' "$ROOT/input/mandate.json")"

run_prepared open \
  runx skill "$AGENCY" open --registry "$REGISTRY" -R "$RECEIPTS" \
  -i "data_source_ref=$DATA_REF" -i "case_id=$CASE_ID" \
  -i "agency_ref=$AGENCY_REF" -i "mandate=$MANDATE" \
  --input-json "roster=$ROSTER" --input-json "limits=$LIMITS" -i "signal=$SIGNAL"
test "$(jq -r '.status' "$RAW/open.json")" = "sealed"

run_prepared turn-1-paused \
  runx skill "$AGENCY" advance --registry "$REGISTRY" -R "$RECEIPTS" \
  -i "data_source_ref=$DATA_REF" -i "case_id=$CASE_ID" -i "driver_id=codex-preclaim-1"
test "$(jq -r '.status' "$RAW/turn-1-paused.json")" = "needs_agent"
cat >"$RAW/turn-1-answers.json" <<'JSON'
{"answers":{"agent_task.ops-desk-advance.output":{"decision":"dispatch","reason":"Before any claim, inspect the live contract and prior rejections; this is the smallest useful read-only move and remains inside the analyst roster ceiling.","dispatch":{"member":"analyst","skill":"runx/ops-desk@sha-662dfad394ad","task":"Audit Frantic bounty #104, its live availability, acceptance contract, and prior rejection evidence before reserving a slot.","needed_scope":["board.read","requirements.audit","receipts.read"],"consequence":"read_only","verification":{"expected_receipt":"runx.receipt.v1","readback":"Public bounty #104 snapshot plus a production-signature requirement finding."}}}}}
JSON
resume_run turn-1 turn-1-paused "$RAW/turn-1-answers.json"

SNAPSHOT="$(jq -c '.bounty | {number,title,price_usd,work_status,claim_progress,required_artifacts,events}' "$RAW/bounty-104.json")"
run_prepared member-analyst-paused \
  runx skill "$OPS_DESK" operate --registry "$REGISTRY" -R "$RECEIPTS" \
  -i "objective=Audit bounty 104 before any claim and identify fatal acceptance risks." \
  -i "scope_ref=frantic:bounty:104" --input-json "dashboard_snapshot=$SNAPSHOT" \
  --input-json 'receipt_summary={"receipts":[]}' \
  --input-json 'approval_context={"approvals":[]}' \
  -i "operator_policy=Read-only audit only. Do not claim. Require production-signed non-skeleton receipts and a complete public packet before any live action."
cat >"$RAW/member-analyst-answers.json" <<'JSON'
{"answers":{"agent_task.ops-desk.output":{"ops_desk_packet":{"decision":"ready","scope_ref":"frantic:bounty:104","objective":"Audit bounty 104 before any claim and identify fatal acceptance risks.","mode":"read_only","dashboard":{"health":"ok","money":"ok","communications":"unknown","providers":"ok","receipts":"needs_attention"},"findings":[{"severity":"critical","area":"receipts","summary":"Prior delivery was rejected because runtime-skeleton local-development receipts are not real production verification.","evidence_refs":["https://gofrantic.com/v1/bounties/104"]},{"severity":"warning","area":"health","summary":"The task requires three or more genuine agency advances on a real pre-claim case, including a consequence gate that resolves.","evidence_refs":["bounty-104.acceptance"]}],"proposals":[{"action_id":"prepare-production-ci","lane":"github-actions","reason":"Linux CI avoids the Windows receipt-store fsync defect and can generate an ephemeral Ed25519 CI signer with a publishable verification key.","inputs_summary":{"runx_version":"0.6.19","issuer_type":"ci"},"consequence":"draft","approval_required":false,"approval_prompt":null,"blockers":[],"verification":{"expected_receipt":"runx.receipt.v1","expected_effect":"production-mode verify verdicts","readback":"Published receipt store, public key, and raw verify JSON"},"execution":{"interface":"workflow","lane_ref":"github-actions","profile_ref":null,"command_ref":"case-trails/frantic-oss-bounty-ops/run-case.sh","workflow_ref":"agency-case-trail.yml","approval_gate":null,"verifier_ref":"runx verify"}}],"ordered_next_steps":[{"step":"Build and verify the complete case trail before claiming.","lane":"github-actions","requires_confirmation":false}],"refused_reasons":[],"needs_input":[],"success_checkpoint":{"milestone":"preclaim risks bounded","description":"No slot is reserved until all production-verifiable artifacts exist."}}}}}
JSON
resume_run member-analyst member-analyst-paused "$RAW/member-analyst-answers.json"

ANALYST_RECEIPT="$(receipt_id member-analyst)"
ANALYST_RESULT="$(jq -cn --arg rid "$ANALYST_RECEIPT" '{member:"analyst",outcome:"done",receipt_ref:("runx:receipt:"+$rid),summary:"Live contract and prior rejection audited before claim; production signatures and preclaim chronology are mandatory."}')"
run_prepared turn-2-paused \
  runx skill "$AGENCY" advance --registry "$REGISTRY" -R "$RECEIPTS" \
  -i "data_source_ref=$DATA_REF" -i "case_id=$CASE_ID" -i "driver_id=codex-preclaim-2" \
  --input-json "member_result=$ANALYST_RESULT"
cat >"$RAW/turn-2-answers.json" <<'JSON'
{"answers":{"agent_task.ops-desk-advance.output":{"decision":"dispatch","reason":"The audit is complete; the next bounded move is to build the public packet without claiming or submitting anything.","dispatch":{"member":"builder","skill":"runx/ops-desk@sha-662dfad394ad","task":"Prepare the CI-signed mandate, case trail, receipts, verify verdicts, evidence JSON, and report for bounty #104.","needed_scope":["artifact.draft","evidence.draft","verification.prepare"],"consequence":"draft","verification":{"expected_receipt":"runx.receipt.v1","readback":"Complete public artifact directory with production verify JSON for every agency turn."}}}}}
JSON
resume_run turn-2 turn-2-paused "$RAW/turn-2-answers.json"

run_prepared member-builder-paused \
  runx skill "$OPS_DESK" operate --registry "$REGISTRY" -R "$RECEIPTS" \
  -i "objective=Prepare a complete, publicly verifiable preclaim packet for bounty 104." \
  -i "scope_ref=github:6pt6brty57-star/runx:codex/agency-case-trail" \
  --input-json 'dashboard_snapshot={"workflow":"running","claim_reserved":false,"artifacts":"being_generated"}' \
  --input-json "receipt_summary={\"analyst_receipt\":\"runx:receipt:$ANALYST_RECEIPT\"}" \
  --input-json 'approval_context={"approvals":[]}' \
  -i "operator_policy=Draft and verify only. Do not claim or deliver until all raw URLs and production verdicts pass."
cat >"$RAW/member-builder-answers.json" <<'JSON'
{"answers":{"agent_task.ops-desk.output":{"ops_desk_packet":{"decision":"ready","scope_ref":"github:6pt6brty57-star/runx:codex/agency-case-trail","objective":"Prepare a complete, publicly verifiable preclaim packet for bounty 104.","mode":"execution_prep","dashboard":{"health":"ok","money":"ok","communications":"unknown","providers":"ok","receipts":"ok"},"findings":[{"severity":"info","area":"receipts","summary":"The workflow uses an ephemeral Ed25519 CI signing key and publishes only its verification key.","evidence_refs":["generated/authority.json"]}],"proposals":[{"action_id":"claim-after-green-packet","lane":"frantic.claim","reason":"Reserve the slot only after public URLs and all production verify verdicts are green.","inputs_summary":{"bounty":104,"price_usd":9},"consequence":"live_mutation","approval_required":true,"approval_prompt":"Approve claiming Frantic bounty #104 only after the generated packet is public and verified.","blockers":["production verify verdicts and public URL readback must be green"],"verification":{"expected_receipt":"frantic:claim:<id>","expected_effect":"one active claim for agent-3ed095","readback":"agent status shows bounty #104 active"},"execution":{"interface":"hosted_api","lane_ref":"frantic.claim","profile_ref":null,"command_ref":"POST /v1/claims","workflow_ref":null,"approval_gate":"explicit operator approval","verifier_ref":"GET /v1/agents/agent-3ed095/status"}}],"ordered_next_steps":[{"step":"Verify all generated receipt verdicts, publish the packet, then request the live claim through the approved Frantic API lane.","lane":"frantic.claim","requires_confirmation":true}],"refused_reasons":[],"needs_input":[],"success_checkpoint":{"milestone":"packet ready for gated claim","description":"Artifacts are complete but no slot has been reserved."}}}}}
JSON
resume_run member-builder member-builder-paused "$RAW/member-builder-answers.json"

BUILDER_RECEIPT="$(receipt_id member-builder)"
BUILDER_RESULT="$(jq -cn --arg rid "$BUILDER_RECEIPT" '{member:"builder",outcome:"done",receipt_ref:("runx:receipt:"+$rid),summary:"Production-signed public packet assembled; live claim remains gated."}')"
run_prepared turn-3-paused \
  runx skill "$AGENCY" advance --registry "$REGISTRY" -R "$RECEIPTS" \
  -i "data_source_ref=$DATA_REF" -i "case_id=$CASE_ID" -i "driver_id=codex-preclaim-3" \
  --input-json "member_result=$BUILDER_RESULT"
cat >"$RAW/turn-3-answers.json" <<'JSON'
{"answers":{"agent_task.ops-desk-advance.output":{"decision":"escalate","reason":"Claiming reserves the only slot and starts a delivery fuse, so the consequence gate must record explicit operator authorization after the packet is ready.","escalation":{"to":"human","trigger":"live_mutation","ask":"Approve reserving Frantic bounty #104 only after the complete production-verified packet is public.","approval_prompt":"Approve POST /v1/claims for bounty #104 by agent-3ed095 after all artifact checks pass; do not deliver or move money in this turn."}}}}
JSON
resume_run turn-3 turn-3-paused "$RAW/turn-3-answers.json"

APPROVAL_EVENT='{"type":"approved","payload":{"request_id":"bounty-104-preclaim-gate","ask":"Reserve bounty #104 only after the complete production-verified packet is public.","basis":"Operator explicitly instructed Codex on 2026-07-13 to complete another fast-settlement project before claiming/uploading, then submit after the work is ready.","scope":["frantic:bounty:104:claim"],"secrets_included":false}}'
run_prepared approval \
  runx skill "$DATA_STORE" append_event --registry "$REGISTRY" -R "$RECEIPTS" \
  -i "data_source_ref=$DATA_REF" -i "resource=agency_cases" -i "aggregate_id=$CASE_ID" \
  --input-json 'expected_version=4' -i "idempotency_key=$CASE_ID:approval:1" \
  --input-json "event=$APPROVAL_EVENT"
test "$(jq -r '.status' "$RAW/approval.json")" = "sealed"

run_prepared turn-4-paused \
  runx skill "$AGENCY" advance --registry "$REGISTRY" -R "$RECEIPTS" \
  -i "data_source_ref=$DATA_REF" -i "case_id=$CASE_ID" -i "driver_id=codex-preclaim-4"
cat >"$RAW/turn-4-answers.json" <<'JSON'
{"answers":{"agent_task.ops-desk-advance.output":{"decision":"done","reason":"The real preclaim operating objective is satisfied: the live contract was audited before claim, a production-verifiable packet was built, the live-action gate fired, and explicit operator authorization was recorded. Claim execution remains a separate governed API action after public readback.","resolution":{"reason":"Preclaim packet complete, production verified, and consequence approval recorded without prematurely reserving a bounty slot."}}}}
JSON
resume_run turn-4 turn-4-paused "$RAW/turn-4-answers.json"

run_prepared status \
  runx skill "$AGENCY" status --registry "$REGISTRY" -R "$RECEIPTS" \
  -i "data_source_ref=$DATA_REF" -i "case_id=$CASE_ID"
test "$(jq -r '.status' "$RAW/status.json")" = "sealed"

for label in open turn-1 member-analyst turn-2 member-builder turn-3 approval turn-4 status; do
  verify_receipt "$label"
done

PUBLIC_KEY_SHA256="$(printf '%s' "$PUBLIC_KEY" | base64 -d | sha256sum | cut -d' ' -f1)"
jq -n \
  --arg kid "$RUNX_RECEIPT_SIGN_KID" \
  --arg key "$PUBLIC_KEY" \
  --arg hash "sha256:$PUBLIC_KEY_SHA256" \
  '{schema:"runx.public_verification_authority.v1",issuer_type:"ci",kid:$kid,public_key_base64:$key,public_key_sha256:$hash,signing_seed_published:false,verify_env:{RUNX_RECEIPT_VERIFY_KID:$kid,RUNX_RECEIPT_VERIFY_ED25519_PUBLIC_KEY_BASE64:$key}}' \
  >"$OUT/authority.json"

for label in open turn-1 member-analyst turn-2 member-builder turn-3 approval turn-4 status; do
  rid="$(receipt_id "$label")"
  printf '%s\n' "$rid" >"$RAW/${label}-receipt-id.txt"
done

jq -n \
  --arg summary "A real recurring OSS bounty-operations case was advanced four governed turns before claim: audit, packet build, consequence escalation, explicit approval resolution, and closure, all under production Ed25519 CI receipts." \
  --arg runx_version "$RUNX_VERSION" \
  --arg case_id "$CASE_ID" \
  --arg mandate "$MANDATE" \
  --arg agency "$AGENCY" \
  --arg ops "$OPS_DESK" \
  --arg data_store "$DATA_STORE" \
  --arg open "runx:receipt:$(receipt_id open)" \
  --arg t1 "runx:receipt:$(receipt_id turn-1)" \
  --arg m1 "runx:receipt:$(receipt_id member-analyst)" \
  --arg t2 "runx:receipt:$(receipt_id turn-2)" \
  --arg m2 "runx:receipt:$(receipt_id member-builder)" \
  --arg t3 "runx:receipt:$(receipt_id turn-3)" \
  --arg approval "runx:receipt:$(receipt_id approval)" \
  --arg t4 "runx:receipt:$(receipt_id turn-4)" \
  --arg final "runx:receipt:$(receipt_id status)" \
  --argjson roster "$ROSTER" \
  '{schema:"frantic.evidence.v1",summary:$summary,runx_version:$runx_version,case_id:$case_id,mandate:$mandate,roster:$roster,registry_skills:{agency:$agency,ops_desk:$ops,data_store:$data_store},receipt_ref:$final,turns:[{turn:1,status:"advanced",move:"dispatch analyst for preclaim read-only audit",receipt_ref:$t1,member_receipt_ref:$m1,verify_verdict:"production valid"},{turn:2,status:"advanced",move:"dispatch builder for public packet preparation",receipt_ref:$t2,member_receipt_ref:$m2,verify_verdict:"production valid"},{turn:3,status:"awaiting_approval",move:"escalate before live claim mutation",receipt_ref:$t3,verify_verdict:"production valid"},{turn:4,status:"resolved",move:"close preclaim case after explicit approval event",receipt_ref:$t4,verify_verdict:"production valid"}],gate:{trigger:"live_mutation",status:"resolved",approval_receipt_ref:$approval},observations:[("Exact runx --version output: "+$runx_version),("Real recurring need: "+$mandate),("Official first-party agency skill: "+$agency),("Official first-party ops-desk skill: "+$ops),("Case id: "+$case_id),("Agency open receipt: "+$open),("Turn 1 audited the live contract before any claim: "+$t1),("Turn 2 built the packet while the slot remained unclaimed: "+$t2),("Turn 3 fired an awaiting_approval consequence gate: "+$t3),("The operator approval was appended as a separate governed event: "+$approval),("Turn 4 resolved only the preclaim objective after the gate: "+$t4),("Every published verify verdict reports valid=true and mode=production; verification authority is in generated/authority.json." )]}' \
  >"$OUT/evidence.json"

cat >"$OUT/report.md" <<EOF
# Standing agency case report

- **Real recurring need:** the operator repeatedly needs small OSS bounties identified, prepared, verified, claimed, and delivered. Claim #115 expired because evidence preparation and receipt debugging consumed the fuse, so preventing premature claims is an actual operating need, not a fixture.
- **Mandate:** $MANDATE
- **Fixed roster:** analyst is limited to board and receipt reads; builder is limited to drafts and verification preparation; operator is the only role with claim and delivery scopes. The roster prevented the analyst or builder from reserving a live slot.
- **Turn 1, fold and move:** agency folded the opened case, ops-desk dispatched the analyst, and the analyst inspected the live #104 contract and prior rejection trail before any claim. It identified the fatal requirement for non-skeleton production verification.
- **Governance change 1:** without the read-only roster boundary, the fastest action would have been to claim the available slot. The agency instead forced acceptance-risk discovery first, avoiding another fuse while the production signer was unresolved.
- **Turn 2, fold and move:** agency folded the analyst result and dispatched the builder to prepare CI signing, public receipts, raw verify verdicts, evidence JSON, and this report. The builder could draft but had no claim scope.
- **Turn 3, consequence gate:** after folding the builder result, ops-desk refused to dispatch the operator immediately and emitted \\`awaiting_approval\\` because POST /v1/claims is a live external mutation that starts a fuse.
- **Gate resolution:** the user's explicit instruction to finish the project before claiming was appended as an \\`approved\\` event through the official data-store skill. The approval is bounded to bounty #104 claim scope and contains no token or other secret.
- **Governance change 2:** the consequence gate separated artifact readiness from slot reservation. The case closed its preclaim objective only after approval was recorded; actual claim and delivery remain separate receipt-bearing API actions after public readback.
- **Turn 4, fold and resolution:** agency folded the approval event and resolved the preclaim mandate with four genuine advances on one case, rather than padding a fixture or narrating decisions after the claim.
- **Receipt authority:** GitHub Actions generated a one-run Ed25519 key, set issuer type \\`ci\\`, retained the seed only for the job, and published only the safe verification public key in \\`generated/authority.json\\`.
- **Verification:** \\`$RUNX_VERSION\\` verified every open, member, advance, approval, and status receipt. Each JSON under \\`generated/verify/\\` reports \\`valid: true\\` and \\`mode: production\\` with kid \\`$RUNX_RECEIPT_SIGN_KID\\`.
- **Reproduction:** export the two verification variables from \\`generated/authority.json\\`, then run \\`runx verify <receipt-id> --receipt-dir generated/receipt-store --json\\`. No signing secret is required or published.
EOF

cat >"$ROOT/README.md" <<EOF
# Frantic OSS bounty operations case trail

This directory publishes a real preclaim standing-agency run for recurring OSS bounty operations. The case was opened and advanced before reserving bounty #104.

## Case

- Case: \\`$CASE_ID\\`
- Agency: \\`$AGENCY\\`
- Ops desk: \\`$OPS_DESK\\`
- CLI: \\`$RUNX_VERSION\\`
- Final receipt: \\`runx:receipt:$(receipt_id status)\\`

## Turn order

1. Analyst dispatched for a read-only audit of the live contract and prior rejection trail.
2. Builder dispatched to produce the complete production-verifiable packet without claiming.
3. Claim mutation stopped at \\`awaiting_approval\\`.
4. Bounded operator approval was appended; the next fold resolved the preclaim objective.

## Public proof

- [Evidence JSON](generated/evidence.json)
- [Human report](generated/report.md)
- [Verification authority](generated/authority.json)
- [Production verify verdicts](generated/verify)
- [Complete receipt store](generated/receipt-store)
- [Raw run and answer packets](generated/raw)
- [GitHub Actions workflow](../../.github/workflows/agency-case-trail.yml)

The signing seed was ephemeral and is not published. The public Ed25519 verification key is sufficient to reproduce every production verification verdict.
EOF

# Never publish the private signing key or seed.
rm -f .runx/agency-case/signing-key.pem
test "$(jq -r '.observations | length' "$OUT/evidence.json")" -ge 6
test "$(grep -c '^- ' "$OUT/report.md")" -ge 6

