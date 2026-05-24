# outputs.tf

# Values printed after terraform apply completes.
# Use these to configure your app and CI/CD pipeline.

output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.main.name
}

output "postgres_host" {
  description = "PostgreSQL server hostname"
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgres_connection_string" {
  description = "Connection string"
  value       = "postgresql://${var.db_username}:${var.db_password}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${var.db_name}"
  sensitive   = true
}

output "streamlit_url" {
  description = "Public URL for your Streamlit dashboard"
  value       = "https://${azurerm_container_app.streamlit.ingress[0].fqdn}"
}
