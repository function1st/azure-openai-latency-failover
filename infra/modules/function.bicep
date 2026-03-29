@description('Azure region for resources')
param location string

@description('Naming prefix for resources')
param namePrefix string

@description('Resource ID of the user-assigned managed identity')
param userAssignedIdentityId string

@description('Client ID of the user-assigned managed identity')
param userAssignedIdentityClientId string

@description('Application Insights connection string')
param appInsightsConnectionString string

@description('APIM gateway URL')
param apimGatewayUrl string

@description('AAD application client ID for token acquisition')
param aadAppClientId string

@description('JSON array of backend names for probing')
param probeRegions string

@description('Azure OpenAI deployment name used by the probe (must exist in all backend resources)')
param deploymentName string

var sanitizedPrefix = toLower(replace(namePrefix, '-', ''))
var storageAccountName = take('${sanitizedPrefix}funcst', 24)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

@description('App Service Plan SKU. Defaults to B1. Use Y1 for Consumption if your subscription supports Dynamic VMs.')
param planSku string = 'B1'

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${namePrefix}-func-plan'
  location: location
  kind: 'linux'
  sku: {
    name: planSku
    tier: planSku == 'Y1' ? 'Dynamic' : 'Basic'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: '${namePrefix}-func'
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Node|20'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'node' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'APIM_ENDPOINT', value: apimGatewayUrl }
        { name: 'AAD_APP_CLIENT_ID', value: aadAppClientId }
        { name: 'PROBE_REGIONS', value: probeRegions }
        { name: 'AZURE_CLIENT_ID', value: userAssignedIdentityClientId }
        { name: 'DEPLOYMENT_NAME', value: deploymentName }
      ]
    }
  }
}
