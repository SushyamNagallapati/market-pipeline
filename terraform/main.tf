# Core infrastructure: resource group, Postgres, and the Container Apps that run
# Airflow and Streamlit. Networking is in network.tf, secrets in keyvault.tf.
# Images come from Docker Hub rather than ACR.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
  required_version = ">= 1.5.0"

  # State lives in Azure Storage so it's backed up and locked during applies.
  # The block is empty on purpose; the settings come from backend.hcl, which
  # scripts/bootstrap-tfstate.sh writes. Then:
  #   terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# Resource Group
resource "azurerm_resource_group" "main" {
  name     = "${var.project_name}-rg"
  location = var.location

  tags = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# PostgreSQL Flexible Server
# Flexible Server, since Single Server is deprecated
resource "azurerm_postgresql_flexible_server" "main" {
  name                         = "${var.project_name}-db"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = var.db_location
  version                      = "15"
  administrator_login          = var.db_username
  administrator_password       = var.db_password
  sku_name                     = "B_Standard_B1ms"
  storage_mb                   = 32768
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  zone                         = "1"

  # reachable only through the private endpoint
  public_network_access_enabled = false

  tags = azurerm_resource_group.main.tags
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# No firewall rules on purpose: public access is off and the only way in is the
# private endpoint in network.tf. Local development uses the Docker Postgres.

# Container Apps Environment
resource "azurerm_container_app_environment" "main" {
  name                = "${var.project_name}-env"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  # puts the apps in our VNet so they can reach the private endpoint
  infrastructure_subnet_id = azurerm_subnet.apps.id

  # container stdout/stderr ends up here
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  tags = azurerm_resource_group.main.tags
}

# Streamlit Container App
resource "azurerm_container_app" "streamlit" {
  name                         = "${var.project_name}-dashboard"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  # the apps can only start once they are allowed to read the vault
  depends_on = [azurerm_role_assignment.apps_read_secrets]

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }

  template {
    container {
      name   = "streamlit"
      image  = "${var.dockerhub_username}/market-streamlit:latest"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "POSTGRES_HOST"
        value = azurerm_postgresql_flexible_server.main.fqdn
      }
      env {
        name  = "POSTGRES_DB"
        value = var.db_name
      }
      env {
        name  = "POSTGRES_USER"
        value = var.db_username
      }
      env {
        name        = "POSTGRES_PASSWORD"
        secret_name = "db-password"
      }
      env {
        name  = "POSTGRES_PORT"
        value = "5432"
      }
    }
  }

  secret {
    name                = "db-password"
    key_vault_secret_id = azurerm_key_vault_secret.db_password.id
    identity            = azurerm_user_assigned_identity.apps.id
  }

  ingress {
    external_enabled = true
    target_port      = 8501
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  tags = azurerm_resource_group.main.tags

  # pipeline.yml rolls out new images; don't let Terraform revert them to :latest
  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

# Airflow Container App
resource "azurerm_container_app" "airflow" {
  name                         = "${var.project_name}-airflow"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  # the apps can only start once they are allowed to read the vault
  depends_on = [azurerm_role_assignment.apps_read_secrets]

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }

  template {
    # Airflow takes no HTTP traffic, so nothing would ever wake it from scale-to-zero.
    # Exactly one replica: two schedulers would run every DAG twice.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "airflow"
      image  = "${var.dockerhub_username}/market-airflow:latest"
      cpu    = 1.0
      memory = "2Gi"

      # the image has no default command, so start scheduler and webserver together
      command = ["airflow", "standalone"]

      env {
        name  = "POSTGRES_HOST"
        value = azurerm_postgresql_flexible_server.main.fqdn
      }
      env {
        name  = "POSTGRES_DB"
        value = var.db_name
      }
      env {
        name  = "POSTGRES_USER"
        value = var.db_username
      }
      env {
        name        = "POSTGRES_PASSWORD"
        secret_name = "db-password"
      }
      env {
        name        = "NEWS_API_KEY"
        secret_name = "news-api-key"
      }
      env {
        name  = "POSTGRES_PORT"
        value = "5432"
      }
    }
  }

  secret {
    name                = "db-password"
    key_vault_secret_id = azurerm_key_vault_secret.db_password.id
    identity            = azurerm_user_assigned_identity.apps.id
  }

  secret {
    name                = "news-api-key"
    key_vault_secret_id = azurerm_key_vault_secret.news_api_key.id
    identity            = azurerm_user_assigned_identity.apps.id
  }

  tags = azurerm_resource_group.main.tags

  # pipeline.yml rolls out new images; don't let Terraform revert them to :latest
  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}
