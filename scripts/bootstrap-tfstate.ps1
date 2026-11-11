# PowerShell version of bootstrap-tfstate.sh: creates the storage account that
# holds Terraform state. Works in PowerShell 7 on Windows, macOS and Linux.
#
# Usage: ./scripts/bootstrap-tfstate.ps1 [-Location westus2]
# Safe to re-run.

[CmdletBinding()]
param(
    [string]$Location = 'eastus',
    [string]$ResourceGroup = 'market-pipeline-tfstate-rg',
    [string]$Container = 'tfstate',
    [string]$StorageAccount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# az is a native command, so $ErrorActionPreference doesn't catch its failures
function Invoke-Az {
    & az @args
    if ($LASTEXITCODE -ne 0) {
        throw "az $($args -join ' ') failed with exit code $LASTEXITCODE"
    }
}

$subscription = az account show --query '{id:id, name:name}' -o json | ConvertFrom-Json
if (-not $subscription) { throw 'Not logged in. Run az login first.' }

# same naming rule as the bash script: stable suffix from the subscription id
if (-not $StorageAccount) {
    $suffix = ($subscription.id -replace '-', '').Substring(0, 8)
    $StorageAccount = "mpstate$suffix"
}

Write-Host "Subscription : $($subscription.name)"
Write-Host "Resource grp : $ResourceGroup ($Location)"
Write-Host "Storage acct : $StorageAccount"
Write-Host "Container    : $Container"
$answer = Read-Host 'Create these in the subscription above? [y/N]'
if ($answer -notin 'y', 'Y') {
    Write-Host 'Aborted.'
    exit 1
}

Invoke-Az group create --name $ResourceGroup --location $Location --output none

Invoke-Az storage account create `
    --name $StorageAccount --resource-group $ResourceGroup --location $Location `
    --sku Standard_LRS --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false `
    --output none

# versioning keeps old copies of the state file
Invoke-Az storage account blob-service-properties update `
    --account-name $StorageAccount --resource-group $ResourceGroup `
    --enable-versioning true --output none

Invoke-Az storage container create `
    --name $Container --account-name $StorageAccount --auth-mode login --output none

$backendFile = Join-Path $PSScriptRoot '../terraform/backend.hcl'
@"
resource_group_name  = "$ResourceGroup"
storage_account_name = "$StorageAccount"
container_name       = "$Container"
key                  = "market-pipeline.tfstate"
use_azuread_auth     = true
"@ | Set-Content -Path $backendFile -Encoding utf8

Write-Host ''
Write-Host 'Done. Wrote terraform/backend.hcl. Next:'
Write-Host '  cd terraform; terraform init -backend-config=backend.hcl'
