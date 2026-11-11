# Printed after apply.

output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.main.name
}

output "postgres_host" {
  description = "PostgreSQL server hostname"
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "streamlit_url" {
  description = "Public URL for your Streamlit dashboard"
  value       = "https://${azurerm_container_app.streamlit.ingress[0].fqdn}"
}
