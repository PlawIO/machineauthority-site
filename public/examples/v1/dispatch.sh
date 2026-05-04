#!/bin/sh
# machineauthority.org/examples/v1/dispatch.sh
#
# Walk a complete Machine Authority Protocol v1.0 elicitation loop end-to-end
# and verify every signature with the reference implementation. Same vibe as
# `cosign verify-blob` -- one command, exit 0 on success.
#
# Usage (do NOT pipe untrusted shell scripts straight to sh):
#   curl -sLO https://machineauthority.org/examples/v1/dispatch.sh
#   less dispatch.sh        # read every byte before executing
#   sh dispatch.sh
#
# What this does:
#   1. Clones the MAP reference implementation at the v1.0.1 release tag.
#   2. Runs `npm install` inside reference/ to pull ajv@^8.17.1 + ajv-formats@^3.0.1
#      (the schema gate at reference/lib/schema.js depends on Draft 2020-12 Ajv).
#   3. Verifies a standalone DEFER decision envelope's aab_signature
#      (Ed25519 over the canonical envelope, MAP-DECISION-ENVELOPE-1).
#   4. Verifies a standalone CAC against canonical CAR bytes
#      (Ed25519 over MAP-CAC-JWS-1, RFC 7797 detached payload).
#   5. Verifies the same CAC re-encoded in the DSSE+in-toto profile
#      (MAP-CAC-DSSE-1).
#   6. Walks the full elicitation loop (DAR -> ApprovalDecision -> ExecutionReceipt)
#      with DPoP-bound resume_token (RFC 9449), cross-binding the CAR hash,
#      action_id, request_id, dispatcher JWK thumbprint, and approver signature.
#
# Requires: git, node (>= 20), npm. Signatures use node:crypto Ed25519, but the
# verifier CLIs invoke reference/lib/schema.js which loads ajv/dist/2020 and
# ajv-formats -- so this script runs `npm install` inside reference/ before any
# verifier is invoked. Exits 0 only if every step verifies. Cleans up tmpdir on exit.

set -e

REPO="${MAP_REPO:-https://github.com/PlawIO/machineauthority-protocol.git}"
# Pin to a tagged release so the demo cannot regress under you. Override with
# MAP_REF=main if you want to test against tip; in production never resolve a
# moving ref into a script you piped to sh.
REF="${MAP_REF:-v1.0.1}"

green() { printf '\033[1;32m%s\033[0m' "$*"; }
red()   { printf '\033[1;31m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }

say() { printf '%s %s\n' "$(green '==>')" "$*"; }
err() { printf '%s %s\n' "$(red '!!')" "$*" >&2; }

need() {
  command -v "$1" >/dev/null 2>&1 || { err "missing required tool: $1"; exit 2; }
}

need git
need node
need npm

NODE_MAJOR=$(node -e 'console.log(process.versions.node.split(".")[0])')
if [ "$NODE_MAJOR" -lt 20 ]; then
  err "node >= 20 required (have $(node -v)); the verifier uses Ed25519 from node:crypto"
  exit 2
fi

RUNNER="node"
if command -v bun >/dev/null 2>&1; then RUNNER="bun"; fi

TMPDIR=$(mktemp -d -t map-dispatch-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

say "Fetching MAP v1.0 reference implementation (ref: $REF)"
if ! git clone --quiet --depth 1 --branch "$REF" "$REPO" "$TMPDIR/map" >/dev/null 2>&1; then
  err "ref '$REF' not found in $REPO; override with MAP_REF=<tag-or-branch>"
  exit 2
fi
cd "$TMPDIR/map"
dim "    pinned to $(git rev-parse --short HEAD) on $REF"
echo

say "Installing reference deps (ajv@^8.17.1 + ajv-formats@^3.0.1) for the schema gate"
( cd reference && npm install --silent --no-audit --no-fund --omit=dev )
echo

say "Step 1/4: verify DEFER envelope signature (Ed25519, MAP-DECISION-ENVELOPE-1)"
$RUNNER reference/cli/env-verify.js \
  --envelope examples/decision-defer.json \
  --keys     reference/keys/jwks-aab.json
echo

say "Step 2/4: verify CAC over canonical CAR (MAP-CAC-JWS-1, RFC 7797 detached)"
$RUNNER reference/cli/cac-verify.js \
  --car  examples/car-simple.json \
  --cac  examples/cac/jws/cac-approve.json \
  --keys reference/keys/jwks-approver.json
echo

say "Step 3/4: verify CAC in DSSE+in-toto profile (MAP-CAC-DSSE-1)"
$RUNNER reference/cli/cac-verify.js \
  --car  examples/car-simple.json \
  --cac  examples/cac/dsse/cac-approve-dsse.json \
  --keys reference/keys/jwks-approver.json
echo

say "Step 4/4: walk the full elicitation loop (DAR -> AD -> ER) with DPoP-bound resume"
$RUNNER reference/cli/loop-verify.js \
  --dar           examples/elicitation-loop/dar.json \
  --approval      examples/elicitation-loop/approval-decision-approve.json \
  --receipt       examples/elicitation-loop/execution-receipt.json \
  --aab-keys      reference/keys/jwks-aab.json \
  --approver-keys reference/keys/jwks-approver.json
echo

cat <<EOF
$(green '==>') $(green 'OK') $(dim '-- MAP v1.0 dispatch demo verified end-to-end')

  - DEFER envelope signature        EdDSA / MAP-DECISION-ENVELOPE-1
  - CAC signature                   EdDSA / MAP-CAC-JWS-1 (RFC 7797 detached)
  - DSSE+in-toto CAC profile        MAP-CAC-DSSE-1
  - Elicitation loop                DAR -> ApprovalDecision -> ExecutionReceipt
                                    DPoP-bound (RFC 9449), CAR-hash bound,
                                    action_id / request_id cross-bound

Spec:        https://machineauthority.org/spec/car
             https://machineauthority.org/spec/decision-envelope
             https://machineauthority.org/spec/elicitation-loop
             https://machineauthority.org/spec/cryptographic-attestation
Conformance: https://github.com/PlawIO/machineauthority-protocol/blob/main/CONFORMANCE.md
Reference:   https://github.com/PlawIO/machineauthority-protocol/tree/main/reference
EOF
