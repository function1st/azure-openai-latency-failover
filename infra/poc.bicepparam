using './main.bicep'

// NOTE: All Azure OpenAI resources must be in the same resource group as this deployment.
param namePrefix = 'aoai-lr'
param backends = [
  {
    name: 'eastus2'
    endpoint: 'https://<YOUR-EUS2-RESOURCE>.openai.azure.com'
    resourceId: '/subscriptions/<YOUR-SUBSCRIPTION-ID>/resourceGroups/<YOUR-RESOURCE-GROUP>/providers/Microsoft.CognitiveServices/accounts/<YOUR-EUS2-RESOURCE>'
  }
  {
    name: 'westus3'
    endpoint: 'https://<YOUR-WUS3-RESOURCE>.openai.azure.com'
    resourceId: '/subscriptions/<YOUR-SUBSCRIPTION-ID>/resourceGroups/<YOUR-RESOURCE-GROUP>/providers/Microsoft.CognitiveServices/accounts/<YOUR-WUS3-RESOURCE>'
  }
  {
    name: 'uaenorth'
    endpoint: 'https://<YOUR-UAEN-RESOURCE>.openai.azure.com'
    resourceId: '/subscriptions/<YOUR-SUBSCRIPTION-ID>/resourceGroups/<YOUR-RESOURCE-GROUP>/providers/Microsoft.CognitiveServices/accounts/<YOUR-UAEN-RESOURCE>'
  }
]
param aadTenantId = '<YOUR-TENANT-ID>'
param aadAppClientId = '<YOUR-AAD-APP-CLIENT-ID>'
param deploymentName = '<YOUR-DEPLOYMENT-NAME>'  // must match the deployment name in all AOAI resources
