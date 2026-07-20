#!/usr/bin/env bash
# ^ run this file with bash.

# End-to-end smoke test for the Option A (single-stack) template:
#   validate  ->  deploy  ->  curl the ALB until HTTP 200  ->  teardown.
#
# Usage:  ./scripts/quick-test.sh [stack-name] [params-file] [curl-path] [region] [profile]
# Defaults: demo-api-test, the demo params file, path "/", ap-southeast-1, default.
#
# Set KEEP=1 to leave the stack running for inspection instead of tearing down:
#   KEEP=1 ./scripts/quick-test.sh

# Strict mode: stop on error, error on undefined variable, fail pipelines properly.
set -euo pipefail

# AWS CLI v2 pipes output through an interactive pager (more/less) when stdout is
# a terminal; under Git Bash that pager waits for a keypress the script never
# sends, hanging forever. Empty AWS_PAGER = print directly, no pager.
export AWS_PAGER=""

# Arguments, each with a default (${N:-default}) so you can run it with none.
STACK_NAME="${1:-demo-api-test}"                              # name for the test stack
PARAMS_FILE="${2:-option-a-parity/params/demo-service-dev.json}"  # which params to deploy
CURL_PATH="${3:-/}"                                           # URL path to test (e.g. /health)
REGION="${4:-ap-southeast-1}"                                # AWS region
PROFILE="${5:-default}"                                      # AWS credentials

# Resolve the repo root from this script's own location (see validate.sh comments)
# so the relative paths below work from any folder.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

TEMPLATE="option-a-parity/backend-service.yaml"

# A "cleanup" function that deletes the stack. We register it with `trap ... EXIT`
# below so it runs no matter HOW the script ends - success, an error, or Ctrl-C.
# That guarantees a failed deploy or a failed curl never leaves a stack (and its
# hourly ALB charge) sitting around. KEEP=1 opts out of the auto-delete.
cleanup() {
  if [[ "${KEEP:-0}" == "1" ]]; then     # ${KEEP:-0} = value of KEEP, or 0 if unset
    echo ""
    echo "KEEP=1 - leaving '$STACK_NAME' running."
    echo "Tear down later with: ./scripts/teardown.sh $STACK_NAME"
    return
  fi
  echo ""
  echo "=== [4/4] Teardown ==="
  # "|| true" so a teardown hiccup doesn't itself abort the script.
  # 2nd arg is the params file (empty here - quick-test uses no env file).
  "$SCRIPT_DIR/teardown.sh" "$STACK_NAME" "" "$REGION" "$PROFILE" || true
}
trap cleanup EXIT     # run cleanup() automatically when the script exits

echo "=== [1/4] Validate ==="
"$SCRIPT_DIR/validate.sh" "$REGION" "$PROFILE"

echo ""
echo "=== [2/4] Deploy ($STACK_NAME) ==="
"$SCRIPT_DIR/deploy.sh" "$TEMPLATE" "$STACK_NAME" "$PARAMS_FILE" "$REGION" "$PROFILE"

echo ""
echo "=== [3/4] Verify (curl) ==="
# Read the ALB DNS name back out of the stack's Outputs.
# --query pulls just the AlbDnsName output value; --output text gives a bare string.
DNS="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" \
  --output text)"
URL="http://${DNS}${CURL_PATH}"
echo "Hitting $URL"

# Poll the URL until it answers 200, or give up after 30 tries (~2.5 min). The ALB
# can take a few seconds to start routing even after the stack says "done".
OK=0
for i in $(seq 1 30); do
  # curl flags: -s silent, -o /dev/null discard the body,
  #   -w "%{http_code}" print ONLY the HTTP status code.
  # "|| true" so a connection error doesn't trip `set -e` mid-loop.
  CODE="$(curl -s -o /dev/null -w "%{http_code}" "$URL" || true)"
  if [[ "$CODE" == "200" ]]; then
    echo "  HTTP 200 - service is live and reachable through the ALB."
    OK=1
    break
  fi
  echo "  attempt $i: got HTTP $CODE, retrying in 5s..."
  sleep 5
done

# If we never saw a 200, fail the script. The EXIT trap still runs teardown.
if [[ "$OK" != "1" ]]; then
  echo "  FAILED: service did not return HTTP 200 in time."
  exit 1
fi
