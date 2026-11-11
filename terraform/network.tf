# Keeps Postgres off the public internet. The apps sit in the VNet and reach the
# database through a private endpoint; private DNS makes the usual hostname
# resolve to the endpoint's private IP.

# Virtual Network
resource "azurerm_virtual_network" "main" {
  name                = "${var.project_name}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.vnet_address_space]

  tags = azurerm_resource_group.main.tags
}

# Subnet for the Container Apps environment.
# Needs at least a /23, and has to be delegated to Container Apps or Azure
# rejects the environment (found on the first apply).
resource "azurerm_subnet" "apps" {
  name                 = "snet-apps"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.apps_subnet_prefix]

  delegation {
    name = "container-apps"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# holds the private endpoint
resource "azurerm_subnet" "data" {
  name                 = "snet-data"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.data_subnet_prefix]

  # Azure ignores NSGs on private endpoint subnets unless this is on
  private_endpoint_network_policies = "Enabled"
}

# Network Security Group (NSG) on the data subnet
# lowest priority number is checked first, first match wins
resource "azurerm_network_security_group" "data" {
  name                = "${var.project_name}-data-nsg"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  # only the apps subnet may reach Postgres
  security_rule {
    name                       = "allow-postgres-from-apps"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.apps_subnet_prefix
    source_port_range          = "*"
    destination_address_prefix = var.data_subnet_prefix
    destination_port_range     = "5432"
  }

  # refuse everything else, including other things inside the VNet
  security_rule {
    name                       = "deny-all-other-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }

  tags = azurerm_resource_group.main.tags
}

resource "azurerm_subnet_network_security_group_association" "data" {
  subnet_id                 = azurerm_subnet.data.id
  network_security_group_id = azurerm_network_security_group.data.id
}

# Private DNS
# Inside the VNet this zone answers with the private IP instead of the public
# one. Azure fixes the zone name for Postgres private endpoints.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name

  tags = azurerm_resource_group.main.tags
}

# only things inside our VNet see these answers
resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${var.project_name}-postgres-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.main.id

  tags = azurerm_resource_group.main.tags
}

# Private Endpoint for Postgres
resource "azurerm_private_endpoint" "postgres" {
  name                = "${var.project_name}-db-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.data.id

  private_service_connection {
    name                           = "${var.project_name}-db-connection"
    private_connection_resource_id = azurerm_postgresql_flexible_server.main.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  # registers the endpoint's IP in the zone
  private_dns_zone_group {
    name                 = "postgres-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.postgres.id]
  }

  tags = azurerm_resource_group.main.tags
}
