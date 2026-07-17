#!/usr/bin/env bash
# Thin wrapper over `aws cloudformation deploy`.
# Usage: ./scripts/deploy.sh <template.yaml> <stack-name> <params.json> [region] [profile]
set -euo pipefail

TEMPLATE="${1:?template file required}"
STACK_NAME="${2:?stack name required}"
PARAMS_FILE="${3:?params file required}"
REGION="${4:-ap-southeast-1}"
PROFILE="${5:-default}"

aws cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides "file://$PARAMS_FILE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --profile "$PROFILE" \
  --no-fail-on-empty-changeset

echo ""
echo "=== Outputs for $STACK_NAME ==="
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" \
  --output table
