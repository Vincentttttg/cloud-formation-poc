# Thin wrapper over `aws cloudformation deploy`.
# Usage: .\scripts\deploy.ps1 -Template <template.yaml> -StackName <name> -ParamsFile <params.json> [-Region ap-southeast-1] [-ProfileName default]
param(
    [Parameter(Mandatory = $true)][string]$Template,
    [Parameter(Mandatory = $true)][string]$StackName,
    [Parameter(Mandatory = $true)][string]$ParamsFile,
    [string]$Region = "ap-southeast-1",
    [string]$ProfileName = "default"
)

$ErrorActionPreference = "Stop"

aws cloudformation deploy `
    --template-file $Template `
    --stack-name $StackName `
    --parameter-overrides "file://$ParamsFile" `
    --capabilities CAPABILITY_NAMED_IAM `
    --region $Region `
    --profile $ProfileName `
    --no-fail-on-empty-changeset
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "=== Outputs for $StackName ==="
aws cloudformation describe-stacks `
    --stack-name $StackName `
    --region $Region `
    --profile $ProfileName `
    --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" `
    --output table
