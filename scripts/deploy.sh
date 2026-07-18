#!/usr/bin/env bash
# ^ "shebang": run this file with bash (found via the PATH).

# Deploy a CloudFormation stack. Also handles the S3 env-file pattern: if the
# params file references an env file, this can create the bucket and/or upload a
# local .env BEFORE deploying (the file must be in S3 before the ECS task starts).
#
# Usage:  ./scripts/deploy.sh <template.yaml> <stack-name> <params.json> [region] [profile]
#
# Optional env-file behaviour (only kicks in when the params reference an env file):
#   ENV_FILE=<path>   local .env to upload first (skip = assume it's already in S3)
#   CREATE_BUCKET=1   also create the bucket first, as a demo (default: bucket pre-exists)

# Strict mode: -e stop on first error, -u error on undefined variable,
# -o pipefail make a pipeline fail if any stage fails.
set -euo pipefail

# Note: we do NOT set MSYS_NO_PATHCONV here. All parameter values reach AWS via the
# params file (file://...), never as inline "/..." arguments, so Git Bash's path
# conversion is harmless - and we rely on it to turn the absolute template path
# ("/d/...") into the Windows form ("D:/...") that aws.exe understands.

TEMPLATE="${1:?template file required}"      # the .yaml template to deploy
STACK_NAME="${2:?stack name required}"       # name for this deployment (the "stack")
PARAMS_FILE="${3:?params file required}"     # JSON file holding the parameter values
REGION="${4:-ap-southeast-1}"                # AWS region (default ap-southeast-1)
PROFILE="${5:-default}"                      # AWS credentials to use (default profile)

# Where this script lives, so we can find sibling templates regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Optional S3 env-file handling (the script-level mirror of the template's
#     HasEnvFile condition) -------------------------------------------------------
# Pull EnvFileS3Bucket / EnvFileS3Key out of the params file, if present. The sed
# grabs the text between "EnvFileS3Bucket=" and the closing quote.
ENV_BUCKET="$(sed -n 's/.*"EnvFileS3Bucket=\([^"]*\)".*/\1/p' "$PARAMS_FILE" | head -1)"
ENV_KEY="$(sed -n 's/.*"EnvFileS3Key=\([^"]*\)".*/\1/p' "$PARAMS_FILE" | head -1)"

if [ -n "$ENV_BUCKET" ] && [ -n "$ENV_KEY" ]; then
  echo "Params reference an S3 env file: s3://$ENV_BUCKET/$ENV_KEY"

  # Demo convenience: create the bucket first. Real deploys omit this (the shared
  # bucket, e.g. acdstagingbucket, already exists).
  if [ "${CREATE_BUCKET:-0}" = "1" ]; then
    echo "  CREATE_BUCKET=1: ensuring bucket via stack ${STACK_NAME}-envbucket ..."
    aws cloudformation deploy \
      --template-file "$SCRIPT_DIR/../env-file/envfile-bucket.yaml" \
      --stack-name "${STACK_NAME}-envbucket" \
      --parameter-overrides "BucketName=$ENV_BUCKET" \
      --region "$REGION" \
      --profile "$PROFILE" \
      --no-fail-on-empty-changeset
  fi

  # Upload the local .env so it exists in S3 before the ECS task tries to read it.
  if [ -n "${ENV_FILE:-}" ]; then
    echo "  uploading $ENV_FILE -> s3://$ENV_BUCKET/$ENV_KEY"
    aws s3 cp "$ENV_FILE" "s3://$ENV_BUCKET/$ENV_KEY" --region "$REGION" --profile "$PROFILE"
  else
    echo "  ENV_FILE not set - assuming the file already exists in S3."
  fi
fi

# --- Deploy the stack ----------------------------------------------------------
# Flags: --template-file (local template), --stack-name (the stack),
#   --parameter-overrides file://... (read values from a file),
#   --capabilities CAPABILITY_NAMED_IAM (you acknowledge it creates named IAM roles),
#   --region / --profile (where + as whom),
#   --no-fail-on-empty-changeset (re-deploying with no changes = success, not error).
aws cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides "file://$PARAMS_FILE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --profile "$PROFILE" \
  --no-fail-on-empty-changeset

# --- Show the stack's Outputs (e.g. the ALB DNS name) as a table ---------------
echo ""
echo "=== Outputs for $STACK_NAME ==="
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" \
  --output table
