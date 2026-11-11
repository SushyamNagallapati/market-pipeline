# Logs, metric alerts and a cost budget. Everything goes to one Log Analytics
# workspace; alerts email var.alert_email.

resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.project_name}-logs"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  # hard cap on ingestion so a noisy container can't run up the bill
  daily_quota_gb = 1

  tags = azurerm_resource_group.main.tags
}

# Postgres logs and metrics
resource "azurerm_monitor_diagnostic_setting" "postgres" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_postgresql_flexible_server.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "PostgreSQLLogs"
  }

  metric {
    category = "AllMetrics"
  }
}

# Audit trail for the vault: who read or changed which secret
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "AuditEvent"
  }
}

resource "azurerm_monitor_action_group" "email" {
  name                = "${var.project_name}-alerts"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "mp-alerts"

  email_receiver {
    name          = "owner"
    email_address = var.alert_email
  }

  tags = azurerm_resource_group.main.tags
}

resource "azurerm_monitor_metric_alert" "postgres_cpu" {
  name                = "${var.project_name}-db-cpu-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "Postgres CPU above 80% for 15 minutes"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }

  tags = azurerm_resource_group.main.tags
}

# 32 GB disk; a full disk puts Postgres into read-only mode
resource "azurerm_monitor_metric_alert" "postgres_storage" {
  name                = "${var.project_name}-db-storage-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "Postgres storage above 80%"
  severity            = 2
  frequency           = "PT15M"
  window_size         = "PT1H"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "storage_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }

  tags = azurerm_resource_group.main.tags
}

# repeated restarts usually mean a crash loop
resource "azurerm_monitor_metric_alert" "airflow_restarts" {
  name                = "${var.project_name}-airflow-restarts"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.airflow.id]
  description         = "Airflow container restarted more than 3 times in 15 minutes"
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.App/containerapps"
    metric_name      = "RestartCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 3
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }

  tags = azurerm_resource_group.main.tags
}

# Monthly spend limit for the resource group. Emails at 80% of the budget
# actual spend and again if the forecast says we'll go over.
resource "azurerm_consumption_budget_resource_group" "monthly" {
  name              = "${var.project_name}-monthly"
  resource_group_id = azurerm_resource_group.main.id
  amount            = var.monthly_budget
  time_grain        = "Monthly"

  time_period {
    start_date = "2026-11-01T00:00:00Z"
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }

  # Azure rewrites the start date after the first period
  lifecycle {
    ignore_changes = [time_period]
  }
}
