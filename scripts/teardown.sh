#!/usr/bin/env bash
# ^ run this file with bash.

# Delete a CloudFormation stack and wait until it is fully gone. Deleting the
# stack deletes ALL the resources it created (ALB, ECS, roles, etc.).
#
# Usage: ./scripts/teardown.sh <stack-name> [params.json] [region] [profile]
#
# The params file is the 2nd arg (optional) - same position idea as deploy.sh,
# where the params file also comes before region/profile. Pass it only when the
# stack used an S3 env file; teardown then also removes it:
#     - demo bucket (a "<stack>-envbucket" stack exists) -> empty + delete it
#     - shared bucket                                     -> remove ONLY this
#       service's .env object, leaving the bucket (other services' files stay)

# Strict mode: stop on error, error on undefined var, fail pipelines properly.
set -euo pipefail

# AWS CLI v2 pipes output through an interactive pager (more/less) when stdout is
# a terminal; under Git Bash that pager waits for a keypress the script never
# sends, hanging forever. Empty AWS_PAGER = print directly, no pager.
export AWS_PAGER=""

STACK_NAME="${1:?stack name required}"   # which stack to delete (required)
PARAMS="${2:-}"                          # optional params file (for env-file cleanup)
REGION="${3:-ap-southeast-1}"            # region (default ap-southeast-1)
PROFILE="${4:-default}"                  # credentials (default profile)

echo "Deleting stack: $STACK_NAME ..."
aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --profile "$PROFILE"

echo "Waiting for delete to complete (this can take a few minutes)..."
aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --profile "$PROFILE"
echo "Deleted: $STACK_NAME"

# --- Optional S3 env-file cleanup ----------------------------------------------
if [ -n "$PARAMS" ] && [ -f "$PARAMS" ]; then
  # Pull the bucket + key this stack used out of its params file.
  ENV_BUCKET="$(sed -n 's/.*"EnvFileS3Bucket=\([^"]*\)".*/\1/p' "$PARAMS" | head -1)"
  ENV_KEY="$(sed -n 's/.*"EnvFileS3Key=\([^"]*\)".*/\1/p' "$PARAMS" | head -1)"

  if [ -n "$ENV_BUCKET" ] && [ -n "$ENV_KEY" ]; then
    # Did deploy.sh create a throwaway demo bucket for this stack?
    if aws cloudformation describe-stacks --stack-name "${STACK_NAME}-envbucket" \
         --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1; then
      echo "Removing demo bucket (stack ${STACK_NAME}-envbucket) ..."
      # A bucket must be EMPTY before it can be deleted.
      aws s3 rm "s3://$ENV_BUCKET" --recursive --region "$REGION" --profile "$PROFILE" || true
      aws cloudformation delete-stack --stack-name "${STACK_NAME}-envbucket" --region "$REGION" --profile "$PROFILE"
      aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}-envbucket" --region "$REGION" --profile "$PROFILE"
      echo "Deleted: ${STACK_NAME}-envbucket"
    else
      # Shared bucket: remove ONLY the file this service added; keep the bucket.
      echo "Removing this service's env file s3://$ENV_BUCKET/$ENV_KEY (leaving the shared bucket) ..."
      aws s3 rm "s3://$ENV_BUCKET/$ENV_KEY" --region "$REGION" --profile "$PROFILE" || true
    fi
  fi
fi
