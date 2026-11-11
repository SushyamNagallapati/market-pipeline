using './network.bicep'

// replace <subscription-id> before deploying
param postgresServerId = '/subscriptions/<subscription-id>/resourceGroups/market-pipeline-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/market-pipeline-db'
