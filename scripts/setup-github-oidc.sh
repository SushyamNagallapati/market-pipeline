#!/usr/bin/env bash
# One-time setup so GitHub Actions can log in to Azure without a stored password.
# It creates an Azure app registration and tells Azure to trust tokens GitHub
# issues for this repo.
#
# Needs az and gh, both logged in. Safe to re-run.
# Usage: ./scripts/setup-github-oidc.sh <storage-account-from-bootstrap-tfstate>

set -euo pipefail

STATE_SA="${1:?Usage: $0 <tfstate-storage-account-name>}"
STATE_RG="${STATE_RG:-market-pipeline-tfstate-rg}"
APP_NAME="${APP_NAME:-market-pipeline-github}"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
SUB_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

echo "GitHub repo  : $REPO"
echo "Subscription : $(az account show --query name -o tsv) ($SUB_ID)"
echo "Identity name: $APP_NAME"
echo "Will grant it: Contributor + User Access Administrator on the subscription,"
echo "              and blob access to the state storage"
read -r -p "Continue? [y/N] " ok
[[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "Aborted."; exit 1; }

# the identity, reused if it already exists
APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
if [[ -z "$APP_ID" ]]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
  az ad sp create --id "$APP_ID" --output none
fi

# the subject says which workflow runs Azure will trust
add_cred() {  # name, subject
  if az ad app federated-credential list --id "$APP_ID" --query "[?name=='$1'].name" -o tsv | grep -q .; then
    echo "credential $1 exists"; return
  fi
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"$1\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$2\",
    \"audiences\": [\"api://AzureADTokenExchange\"]}" --output none
}
add_cred "github-main"        "repo:${REPO}:ref:refs/heads/main"        # app deploy
add_cred "github-pr"          "repo:${REPO}:pull_request"               # terraform plan
add_cred "github-production"  "repo:${REPO}:environment:production"     # terraform apply

# permissions
az role assignment create --assignee "$APP_ID" --role Contributor \
  --scope "/subscriptions/$SUB_ID" --output none || true
# Contributor can't create role assignments, and Terraform needs to (Key Vault)
az role assignment create --assignee "$APP_ID" --role "User Access Administrator" \
  --scope "/subscriptions/$SUB_ID" --output none || true
STATE_SCOPE="$(az storage account show -n "$STATE_SA" -g "$STATE_RG" --query id -o tsv)"
az role assignment create --assignee "$APP_ID" --role "Storage Blob Data Contributor" \
  --scope "$STATE_SCOPE" --output none || true

cat <<OUT

Done. Add these to GitHub yourself (they send values to GitHub):

  gh variable set AZURE_CLIENT_ID          --body "$APP_ID"
  gh variable set AZURE_TENANT_ID          --body "$TENANT_ID"
  gh variable set AZURE_SUBSCRIPTION_ID    --body "$SUB_ID"
  gh variable set TFSTATE_RESOURCE_GROUP   --body "$STATE_RG"
  gh variable set TFSTATE_STORAGE_ACCOUNT  --body "$STATE_SA"
  gh variable set ALERT_EMAIL              --body "you@example.com"   # your real address
  gh secret set DB_PASSWORD        # prompts for the value
  gh secret set NEWS_API_KEY       # prompts for the value

Also create a GitHub environment named "production" with yourself as required
reviewer (Settings > Environments) so applies wait for your approval.
You can now delete the old AZURE_CREDENTIALS secret.
OUT
