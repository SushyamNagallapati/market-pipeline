// Same network as terraform/network.tf, written in Bicep for comparison.
// Deploys into an existing resource group:
//   az deployment group create -g market-pipeline-rg \
//     -f infra/bicep/network.bicep -p infra/bicep/network.bicepparam

@description('Azure region. Defaults to the resource group\'s region.')
param location string = resourceGroup().location

param projectName string = 'market-pipeline'
param vnetAddressSpace string = '10.10.0.0/16'
param appsSubnetPrefix string = '10.10.0.0/23'
param dataSubnetPrefix string = '10.10.2.0/27'

@description('Resource ID of the Postgres flexible server the private endpoint points at.')
param postgresServerId string

param tags object = {
  project: projectName
  environment: 'dev'
  managed_by: 'bicep'
}

// only the apps subnet may reach Postgres, everything else is refused
resource dataNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${projectName}-data-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-postgres-from-apps'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: appsSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: dataSubnetPrefix
          destinationPortRange: '5432'
        }
      }
      {
        name: 'deny-all-other-inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Subnets are defined inline here. Terraform needs separate subnet resources.
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${projectName}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressSpace]
    }
    subnets: [
      {
        name: 'snet-apps'
        properties: {
          addressPrefix: appsSubnetPrefix
          // Container Apps rejects the environment without this delegation
          delegations: [
            {
              name: 'container-apps'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'snet-data'
        properties: {
          addressPrefix: dataSubnetPrefix
          networkSecurityGroup: {
            id: dataNsg.id
          }
          // makes the NSG apply to the private endpoint
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

// DNS zones are global, so no region
resource postgresDns 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.postgres.database.azure.com'
  location: 'global'
  tags: tags
}

resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: postgresDns
  name: '${projectName}-postgres-dns-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource postgresEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${projectName}-db-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: vnet.properties.subnets[1].id
    }
    privateLinkServiceConnections: [
      {
        name: '${projectName}-db-connection'
        properties: {
          privateLinkServiceId: postgresServerId
          groupIds: ['postgresqlServer']
        }
      }
    ]
  }
}

// registers the endpoint's IP in the DNS zone
resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: postgresEndpoint
  name: 'postgres-dns'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'postgres'
        properties: {
          privateDnsZoneId: postgresDns.id
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output appsSubnetId string = vnet.properties.subnets[0].id
output privateEndpointId string = postgresEndpoint.id
