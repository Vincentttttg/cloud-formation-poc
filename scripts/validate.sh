#!/usr/bin/env bash
# ^ run this file with bash.

# Validate every template two ways:
#   1. aws cloudformation validate-template - AWS checks the YAML + overall structure.
#   2. cfn-lint                             - deeper checks of each resource's properties.
# Usage: ./scripts/validate.sh [region] [profile]

# Strict mode:
#   -e = stop on first failing command   -u = error on undefined variable
#   -o pipefail = a pipeline fails if any stage fails.
set -euo pipefail

REGION="${1:-ap-southeast-1}"   # arg #1 or default region
PROFILE="${2:-default}"         # arg #2 or default credentials

# Figure out where the repo lives, based on THIS script's own location, so the
# relative template paths below work no matter which folder you run it from.
#   ${BASH_SOURCE[0]} = path to this script file.
#   dirname           = strip the filename, leaving the folder.
#   cd ... && pwd     = turn it into a full, absolute path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"   # ".." = the folder above scripts/
cd "$REPO_ROOT"                              # run the rest from the repo root

# A bash array: the list of templates to check. Loop over it below.
TEMPLATES=(
  "option-a-parity/backend-service.yaml"
  "option-b-redesign/platform-stack.yaml"
  "option-b-redesign/service-stack.yaml"
)

echo "== aws cloudformation validate-template (structure) =="
# "${TEMPLATES[@]}" expands to every item in the array, safely quoted.
for t in "${TEMPLATES[@]}"; do
  # --template-body file://...  send the local file to AWS to validate.
  # >/dev/null                  throw away the (verbose) success output; we only
  #                             care whether it succeeds or fails.
  aws cloudformation validate-template \
    --template-body "file://$t" \
    --region "$REGION" \
    --profile "$PROFILE" >/dev/null
  echo "  OK  $t"
done

echo ""
echo "== cfn-lint (deep property checks) =="
# `command -v cfn-lint` succeeds only if cfn-lint is installed. "! ... " negates
# it, so this block runs when cfn-lint is NOT found, installing it once.
if ! command -v cfn-lint >/dev/null 2>&1; then
  echo "cfn-lint not found - installing via pip..."
  pip install cfn-lint
fi
# Run cfn-lint on all templates at once. If it finds problems it exits non-zero,
# and because of `set -e` the script stops here.
cfn-lint "${TEMPLATES[@]}"
echo "  cfn-lint: all clean"
