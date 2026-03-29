targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Naming prefix for all resources')
param namePrefix string = 'aoai-lr'

@description('Array of backend configurations with name, endpoint, and resourceId')
param backends array

@description('APIM SKU name')
param apimSku string = 'Developer'

@description('Azure AD tenant ID')
param aadTenantId string

@description('Azure AD application client ID')
param aadAppClientId string

@description('TTFT threshold (ms) to trip degraded state')
param ttftTripMs string = '8000'

@description('TTFT threshold (ms) to clear degraded state')
param ttftClearMs string = '3000'

@description('EMA smoothing factor (0-1)')
param emaAlpha string = '0.3'

@description('Consecutive bad responses before marking backend degraded')
param consecutiveBadThreshold string = '2'

@description('Azure OpenAI deployment name used for probing (must exist in all backend resources)')
param deploymentName string = 'gpt-4.1-nano'

@description('App Service Plan SKU for the probe Function App. Use Y1 for Consumption if your subscription has Dynamic VM quota.')
param functionPlanSku string = 'B1'

@description('Azure region for the Function App. Defaults to same as main location. Override if your subscription lacks App Service quota in the main region.')
param functionLocation string = location

var backendNameStrings = [for backend in backends: '"${backend.name}"']
var probeRegionsJson = '[${join(backendNameStrings, ',')}]'

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    namePrefix: namePrefix
    workbookContent: loadTextContent('workbook.json')
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    namePrefix: namePrefix
  }
}

module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    location: location
    namePrefix: namePrefix
    backends: backends
    apimSku: apimSku
    aadTenantId: aadTenantId
    aadAppClientId: aadAppClientId
    ttftTripMs: ttftTripMs
    ttftClearMs: ttftClearMs
    emaAlpha: emaAlpha
    consecutiveBadThreshold: consecutiveBadThreshold
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsInstrumentationKey: monitoring.outputs.appInsightsInstrumentationKey
  }
}

module function 'modules/function.bicep' = {
  name: 'function'
  params: {
    location: functionLocation
    namePrefix: namePrefix
    userAssignedIdentityId: identity.outputs.identityId
    userAssignedIdentityClientId: identity.outputs.identityClientId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    apimGatewayUrl: apim.outputs.apimGatewayUrl
    aadAppClientId: aadAppClientId
    probeRegions: probeRegionsJson
    deploymentName: deploymentName
    planSku: functionPlanSku
  }
}

output apimGatewayUrl string = apim.outputs.apimGatewayUrl
output apimName string = apim.outputs.apimName
output apimPrincipalId string = apim.outputs.apimPrincipalId
output functionAppName string = '${namePrefix}-func'
output identityPrincipalId string = identity.outputs.identityPrincipalId
output appInsightsName string = '${namePrefix}-ai'
