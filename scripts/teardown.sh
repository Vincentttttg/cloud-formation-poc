#!/usr/bin/env bash
# ^ run this file with bash.

# Delete a CloudFormation stack and wait until it is fully gone.
# Deleting the stack deletes ALL the resources it created (ALB, ECS, roles, etc.).
# Usage: ./scripts/teardown.sh <stack-name> [region] [profile]

# Strict mode (stop on error, error on undefined var, fail pipelines properly).
set -euo pipefail

STACK_NAME="${1:?stack name required}"   # which stack to delete (required)
REGION="${2:-ap-southeast-1}"            # region (default ap-southeast-1)
PROFILE="${3:-default}"                  # credentials (default profile)

echo "Deleting stack: $STACK_NAME ..."
# Kicks off the delete and returns immediately (it runs in the background at AWS).
aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --profile "$PROFILE"

echo "Waiting for delete to complete (this can take a few minutes)..."
# `wait stack-delete-complete` blocks (polls AWS) until the stack is really gone,
# so the script only prints "Deleted" once it's actually finished.
aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --profile "$PROFILE"

echo "Deleted: $STACK_NAME"
