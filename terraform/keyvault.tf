# Holds the DB password and NewsAPI key. The container apps read them through a
# managed identity, so the values never sit in the app config.

data "azurerm_client_config" "current" {}

# vault names are global and capped at 24 chars, hence the hash suffix
locals {
  key_vault_name = "mp-kv-${substr(md5(var.subscription_id), 0, 8)}"
}

resource "azurerm_key_vault" "main" {
  name                = local.key_vault_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Azure roles instead of the older access policies
  enable_rbac_authorization = true

  soft_delete_retention_days = 7
  # off so I can destroy and recreate it while learning; turn on for real use
  purge_protection_enabled = false

  # Public access stays on because Terraform runs on a GitHub-hosted runner and
  # has to write the secrets. Callers still need an Azure AD token and a role.
  # A private-only vault would need a self-hosted runner.

  tags = azurerm_resource_group.main.tags
}

# Identity the apps use to read secrets. Kept separate from the apps so the
# role exists before they start.
resource "azurerm_user_assigned_identity" "apps" {
  name                = "${var.project_name}-apps-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = azurerm_resource_group.main.tags
}

# read-only access to secrets
resource "azurerm_role_assignment" "apps_read_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.apps.principal_id
}

# whoever runs Terraform has to write the secrets
resource "azurerm_role_assignment" "terraform_write_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = var.db_password
  key_vault_id = azurerm_key_vault.main.id

  # role assignments can take a minute to kick in; if the first apply 403s
  # here, just run it again
  depends_on = [azurerm_role_assignment.terraform_write_secrets]
}

resource "azurerm_key_vault_secret" "news_api_key" {
  name         = "news-api-key"
  value        = var.news_api_key
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.terraform_write_secrets]
}
