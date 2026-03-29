@description('Azure region for resources')
param location string

@description('Naming prefix for resources')
param namePrefix string

@description('Workbook template JSON content')
param workbookContent string = ''

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${namePrefix}-law'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = if (!empty(workbookContent)) {
  name: guid(resourceGroup().id, namePrefix, 'latency-router-workbook')
  location: location
  kind: 'shared'
  properties: {
    displayName: 'Azure OpenAI Latency Router'
    category: 'workbook'
    serializedData: workbookContent
    sourceId: appInsights.id
  }
}

output appInsightsId string = appInsights.id
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output logAnalyticsWorkspaceId string = logAnalytics.id
