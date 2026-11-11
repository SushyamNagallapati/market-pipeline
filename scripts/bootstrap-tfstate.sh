#!/usr/bin/env bash
# One-time setup of the storage account that holds Terraform state. It's a
# script rather than Terraform because Terraform needs the state storage to
# exist before it can create anything.
#
# Usage: ./scripts/bootstrap-tfstate.sh   (LOCATION=westus2 to change region)
# Safe to re-run.

set -euo pipefail

LOCATION="${LOCATION:-eastus}"
RG="${RG:-market-pipeline-tfstate-rg}"
CONTAINER="${CONTAINER:-tfstate}"

# account names are global, 3-24 chars, lowercase and digits only; the
# subscription-based suffix keeps the name stable across re-runs
SUB_ID="$(az account show --query id -o tsv)"
SUFFIX="$(printf '%s' "$SUB_ID" | tr -d '-' | cut -c1-8)"
SA="${SA:-mpstate${SUFFIX}}"

echo "Subscription : $(az account show --query name -o tsv)"
echo "Resource grp : $RG ($LOCATION)"
echo "Storage acct : $SA"
echo "Container    : $CONTAINER"
read -r -p "Create these in the subscription above? [y/N] " ok
[[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "Aborted."; exit 1; }

az group create --name "$RG" --location "$LOCATION" --output none

az storage account create \
  --name "$SA" --resource-group "$RG" --location "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --output none

# versioning keeps old copies of the state file
az storage account blob-service-properties update \
  --account-name "$SA" --resource-group "$RG" \
  --enable-versioning true --output none

# Azure AD login instead of storage keys
az storage container create \
  --name "$CONTAINER" --account-name "$SA" --auth-mode login --output none

cat > "$(dirname "$0")/../terraform/backend.hcl" <<HCL
resource_group_name  = "$RG"
storage_account_name = "$SA"
container_name       = "$CONTAINER"
key                  = "market-pipeline.tfstate"
use_azuread_auth     = true
HCL

echo
echo "Done. Wrote terraform/backend.hcl. Next:"
echo "  cd terraform && terraform init -backend-config=backend.hcl"
echo "If the container step was denied, grant yourself the role:"
echo "  az role assignment create --assignee \$(az ad signed-in-user show --query id -o tsv) \\"
echo "    --role 'Storage Blob Data Contributor' \\"
echo "    --scope \$(az storage account show -n $SA -g $RG --query id -o tsv)"
