#!/usr/bin/env bash
# ^ "shebang": tells the OS to run this file with bash (found via the PATH).

# Thin wrapper over `aws cloudformation deploy` so you don't retype the long
# command every time.
# Usage: ./scripts/deploy.sh <template.yaml> <stack-name> <params.json> [region] [profile]

# `set` changes how the shell behaves. These three flags make it "strict":
#   -e          exit right away if any command fails (returns non-zero).
#   -u          treat using an undefined variable as an error (catches typos).
#   -o pipefail in a pipeline "a | b | c", fail if ANY part fails, not just the last.
set -euo pipefail

# Positional arguments (what you type after the script name).
#   ${1:?msg}  = use argument #1; if it's missing/empty, print "msg" and exit.
#   ${4:-x}    = use argument #4; if it's missing, fall back to the default "x".
TEMPLATE="${1:?template file required}"      # path to the .yaml template to deploy
STACK_NAME="${2:?stack name required}"       # name for this deployment (the "stack")
PARAMS_FILE="${3:?params file required}"     # JSON file holding the parameter values
REGION="${4:-ap-southeast-1}"                # which AWS region to deploy into
PROFILE="${5:-default}"                      # which AWS credentials to use (from ~/.aws)

# Run the actual deploy. Flags used (each "\" just continues the line):
#   --template-file        the local template file to deploy.
#   --stack-name           the stack name (all resources are grouped under it).
#   --parameter-overrides  supply parameter values; "file://" reads them from a file.
#   --capabilities         you explicitly acknowledge this stack creates *named* IAM
#                          roles. AWS blocks that by default as a safety check, so you
#                          must opt in with CAPABILITY_NAMED_IAM.
#   --region               the AWS region (data centre group) to deploy in.
#   --profile              which named credential set / account to act as.
#   --no-fail-on-empty-changeset  if NOTHING changed since the last deploy, treat that
#                          as success (exit 0) instead of an error. Lets you re-run the
#                          same deploy safely without it "failing" on no-op.
aws cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides "file://$PARAMS_FILE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --profile "$PROFILE" \
  --no-fail-on-empty-changeset

# Print the stack's Outputs (e.g. the ALB DNS name) as a readable table.
echo ""
echo "=== Outputs for $STACK_NAME ==="
# --query  filters/reshapes the JSON result (JMESPath syntax); here: pull every
#          Output's key + value. --output table renders it as an ASCII table.
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" \
  --output table
