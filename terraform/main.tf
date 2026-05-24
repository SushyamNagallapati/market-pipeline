# main.tf
# -------
# Provisions Azure infrastructure for the market pipeline.
# Resources created:
# - Resource group
# - Azure PostgreSQL Flexible Server
# - Azure Container Apps Environment
# - Azure Container Apps (Airflow, Streamlit)
# Note: Using Docker Hub instead of ACR

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
  required_version = ">= 1.5.0"
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# ── Resource Group ─────────────────────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = "${var.project_name}-rg"
  location = var.location

  tags = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ── PostgreSQL Flexible Server ─────────────────────────────────────────────
# Flexible Server is the current standard — Single Server is deprecated
resource "azurerm_postgresql_flexible_server" "main" {
  name                   = "${var.project_name}-db"
  resource_group_name    = azurerm_resource_group.main.name
  location               = var.db_location
  version                = "15"
  administrator_login    = var.db_username
  administrator_password = var.db_password
  sku_name               = "B_Standard_B1ms"
  storage_mb             = 32768
  backup_retention_days  = 7
  geo_redundant_backup_enabled = false
  zone                   = "1"

  tags = azurerm_resource_group.main.tags
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_local" {
  name             = "allow-local-dev"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = var.local_ip
  end_ip_address   = var.local_ip
}

# ── Container Apps Environment ─────────────────────────────────────────────
resource "azurerm_container_app_environment" "main" {
  name                = "${var.project_name}-env"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = azurerm_resource_group.main.tags
}

# ── Streamlit Container App ────────────────────────────────────────────────
resource "azurerm_container_app" "streamlit" {
  name                         = "${var.project_name}-dashboard"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

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
    name  = "db-password"
    value = var.db_password
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
}

# ── Airflow Container App ──────────────────────────────────────────────────
resource "azurerm_container_app" "airflow" {
  name                         = "${var.project_name}-airflow"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  template {
    container {
      name   = "airflow"
      image  = "${var.dockerhub_username}/market-airflow:latest"
      cpu    = 1.0
      memory = "2Gi"

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
    name  = "db-password"
    value = var.db_password
  }

  secret {
    name  = "news-api-key"
    value = var.news_api_key
  }

  tags = azurerm_resource_group.main.tags
}

# ── Azure Kubernetes Service (AKS) ────────────────────────────────────────
# Managed Kubernetes cluster — Azure handles the control plane
# We manage the worker nodes and what runs on them
resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.project_name}-aks"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = "${var.project_name}-aks"

  default_node_pool {
    name       = "default"
    node_count = 2              # 2 nodes — if one goes down, pods move to the other
    vm_size    = "Standard_D2s_v5" # cheapest VM that fits our workloads
  }

  # System assigned identity — AKS manages its own Azure permissions
  identity {
    type = "SystemAssigned"
  }

  tags = azurerm_resource_group.main.tags
}
