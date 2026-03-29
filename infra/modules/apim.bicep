@description('Azure region for resources')
param location string

@description('Naming prefix for resources')
param namePrefix string

@description('Array of backend configurations with name, endpoint, and resourceId')
param backends array

@description('APIM SKU name')
param apimSku string = 'Developer'

@description('APIM SKU capacity')
param apimSkuCount int = 1

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

@description('Application Insights resource ID for APIM diagnostics')
param appInsightsId string = ''

@description('Application Insights instrumentation key for APIM diagnostics')
param appInsightsInstrumentationKey string = ''

var loginEndpoint = environment().authentication.loginEndpoint

// ── APIM Instance ──────────────────────────────────────────────────────────────

resource apim 'Microsoft.ApiManagement/service@2023-09-01-preview' = {
  name: '${namePrefix}-apim'
  location: location
  sku: {
    name: apimSku
    capacity: apimSkuCount
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: 'noreply@example.com'
    publisherName: 'LLM Router'
  }
}

// ── Backends ───────────────────────────────────────────────────────────────────

resource apimBackends 'Microsoft.ApiManagement/service/backends@2023-09-01-preview' = [for backend in backends: {
  name: 'aoai-${backend.name}'
  parent: apim
  properties: {
    url: '${backend.endpoint}/openai'
    protocol: 'http'
    description: 'Azure OpenAI - ${backend.name}'
  }
}]

// ── Role Assignments (Cognitive Services OpenAI User on each AOAI resource) ───

var cognitiveServicesOpenAIUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

resource aoaiAccounts 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = [for backend in backends: {
  name: last(split(backend.resourceId, '/'))
}]

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (backend, i) in backends: {
  name: guid(apim.id, backend.resourceId, cognitiveServicesOpenAIUserRoleId)
  scope: aoaiAccounts[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

// ── Named Values ───────────────────────────────────────────────────────────────

var namedValuesList = [
  { key: 'ttft-trip-ms', val: ttftTripMs }
  { key: 'ttft-clear-ms', val: ttftClearMs }
  { key: 'ema-alpha', val: emaAlpha }
  { key: 'consecutive-bad-threshold', val: consecutiveBadThreshold }
  { key: 'aad-tenant-id', val: aadTenantId }
  { key: 'aad-app-client-id', val: aadAppClientId }
]

@batchSize(1)
resource namedValues 'Microsoft.ApiManagement/service/namedValues@2023-09-01-preview' = [for nv in namedValuesList: {
  parent: apim
  name: nv.key
  properties: {
    displayName: nv.key
    value: nv.val
  }
}]

// ── API + Operations ───────────────────────────────────────────────────────────

resource api 'Microsoft.ApiManagement/service/apis@2023-09-01-preview' = {
  parent: apim
  name: 'azure-openai'
  properties: {
    displayName: 'Azure OpenAI'
    path: 'openai'
    protocols: [ 'https' ]
    subscriptionRequired: false
  }
}

resource chatCompletionsOp 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  parent: api
  name: 'chat-completions'
  properties: {
    displayName: 'Create Chat Completion'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/chat/completions'
    templateParameters: [
      { name: 'deployment-id', required: true, type: 'string' }
    ]
  }
}

resource completionsOp 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  parent: api
  name: 'completions'
  properties: {
    displayName: 'Create Completion'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/completions'
    templateParameters: [
      { name: 'deployment-id', required: true, type: 'string' }
    ]
  }
}

resource embeddingsOp 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  parent: api
  name: 'embeddings'
  properties: {
    displayName: 'Create Embedding'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/embeddings'
    templateParameters: [
      { name: 'deployment-id', required: true, type: 'string' }
    ]
  }
}

// ── Policy (built dynamically from backends array) ─────────────────────────────

var q = base64ToString('Jw==')

var cacheLookupParts = [for (backend, i) in backends: '        <cache-lookup-value key="score-${backend.name}" variable-name="s${i}" default-value="1000" />\n        <cache-lookup-value key="degraded-${backend.name}" variable-name="d${i}" default-value="false" />']
var cacheLookupFragment = join(cacheLookupParts, '\n')

var candidateParts = [for (backend, i) in backends: '            if ((string)context.Variables["d${i}"] == "false") { var s = double.Parse((string)context.Variables["s${i}"]); if (s &lt; bestScore || (s == bestScore &amp;&amp; rng.Next(2) == 0)) { bestScore = s; bestName = "${backend.name}"; } }']
var candidateFragment = join(candidateParts, '\n')

var fallbackParts = [for (backend, i) in backends: '                { var s = double.Parse((string)context.Variables["s${i}"]); if (s &lt; bestScore || (s == bestScore &amp;&amp; rng.Next(2) == 0)) { bestScore = s; bestName = "${backend.name}"; } }']
var fallbackFragment = join(fallbackParts, '\n')

var routingExpression = join([
  '@{'
  '            var rng = new Random();'
  '            var bestName = "";'
  '            var bestScore = double.MaxValue;'
  candidateFragment
  '            if (bestName == "") {'
  fallbackFragment
  '            }'
  '            return "aoai-" + bestName;'
  '        }'
], '\n')

var newScoreExpr = '@{ var alpha = double.Parse("{{ema-alpha}}"); var latest = (double)context.Variables["ttft"]; var old = double.Parse((string)context.Variables["oldScore"]); return (alpha * latest + (1 - alpha) * old).ToString(); }'

var traceExpr = '@{ var name = (string)context.Variables["backendName"]; var ttft = (double)context.Variables["ttft"]; var newScore = (string)context.Variables["newScore"]; return "backend=" + name + " ttft=" + ttft.ToString("F0") + "ms newEma=" + newScore; }'

#disable-next-line no-hardcoded-env-urls
var policyXml = join([
  '<policies>'
  '    <inbound>'
  '        <base />'
  '        <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized" require-expiration-time="true" require-signed-tokens="true" output-token-variable-name="jwt">'
  '            <openid-config url="${loginEndpoint}${aadTenantId}/v2.0/.well-known/openid-configuration" />'
  '            <audiences>'
  '                <audience>${aadAppClientId}</audience>'
  '                <audience>api://${aadAppClientId}</audience>'
  '            </audiences>'
  '            <issuers>'
  '                <issuer>${loginEndpoint}${aadTenantId}/v2.0</issuer>'
  '                <issuer>https://sts.windows.net/${aadTenantId}/</issuer>'
  '            </issuers>'
  '            <required-claims>'
  '                <claim name="roles" match="any">'
  '                    <value>LLM.Invoke</value>'
  '                    <value>Probe.Execute</value>'
  '                </claim>'
  '            </required-claims>'
  '        </validate-jwt>'
  '        <choose>'
  '            <when condition=${q}@(context.Request.Headers.ContainsKey("X-Probe-Target") &amp;&amp; ((Jwt)context.Variables["jwt"]).Claims.ContainsKey("roles") &amp;&amp; ((Jwt)context.Variables["jwt"]).Claims["roles"].Contains("Probe.Execute"))${q}>'
  '                <set-variable name="chosenBackend" value=${q}@("aoai-" + context.Request.Headers.GetValueOrDefault("X-Probe-Target",""))${q} />'
  '            </when>'
  '            <otherwise>'
  cacheLookupFragment
  '                <set-variable name="chosenBackend" value=${q}${routingExpression}${q} />'
  '            </otherwise>'
  '        </choose>'
  '        <set-variable name="backendStart" value="@(DateTime.UtcNow)" />'
  '        <set-backend-service backend-id=${q}@((string)context.Variables["chosenBackend"])${q} />'
  '        <authentication-managed-identity resource="https://cognitiveservices.azure.com" />'
  '    </inbound>'
  '    <backend>'
  '        <forward-request buffer-response="false" />'
  '    </backend>'
  '    <outbound>'
  '        <base />'
  '        <set-variable name="ttft" value=${q}@((DateTime.UtcNow - (DateTime)context.Variables["backendStart"]).TotalMilliseconds)${q} />'
  '        <set-variable name="backendName" value=${q}@(((string)context.Variables["chosenBackend"]).Substring(5))${q} />'
  '        <cache-lookup-value key=${q}@("score-" + (string)context.Variables["backendName"])${q} variable-name="oldScore" default-value="1000" />'
  '        <set-variable name="newScore" value=${q}${newScoreExpr}${q} />'
  '        <cache-store-value key=${q}@("score-" + (string)context.Variables["backendName"])${q} value=${q}@((string)context.Variables["newScore"])${q} duration="600" />'
  '        <choose>'
  '            <when condition=${q}@((double)context.Variables["ttft"] > double.Parse("{{ttft-trip-ms}}"))${q}>'
  '                <cache-lookup-value key=${q}@("badcount-" + (string)context.Variables["backendName"])${q} variable-name="badcount" default-value="0" />'
  '                <set-variable name="newBadCount" value=${q}@((int.Parse((string)context.Variables["badcount"]) + 1).ToString())${q} />'
  '                <cache-store-value key=${q}@("badcount-" + (string)context.Variables["backendName"])${q} value=${q}@((string)context.Variables["newBadCount"])${q} duration="900" />'
  '                <choose>'
  '                    <when condition=${q}@(int.Parse((string)context.Variables["newBadCount"]) >= int.Parse("{{consecutive-bad-threshold}}"))${q}>'
  '                        <cache-store-value key=${q}@("degraded-" + (string)context.Variables["backendName"])${q} value="true" duration="900" />'
  '                    </when>'
  '                </choose>'
  '            </when>'
  '            <when condition=${q}@((double)context.Variables["ttft"] &lt; double.Parse("{{ttft-clear-ms}}"))${q}>'
  '                <cache-store-value key=${q}@("degraded-" + (string)context.Variables["backendName"])${q} value="false" duration="600" />'
  '                <cache-store-value key=${q}@("badcount-" + (string)context.Variables["backendName"])${q} value="0" duration="600" />'
  '            </when>'
  '        </choose>'
  '        <set-header name="X-Routed-Backend" exists-action="override">'
  '            <value>@((string)context.Variables["chosenBackend"])</value>'
  '        </set-header>'
  '        <trace source="latency-router" severity="information">'
  '            <message>${traceExpr}</message>'
  '        </trace>'
  '    </outbound>'
  '    <on-error>'
  '        <base />'
  '        <choose>'
  '            <when condition=${q}@(context.Variables.ContainsKey("chosenBackend"))${q}>'
  '                <set-variable name="backendName" value=${q}@(((string)context.Variables["chosenBackend"]).Substring(5))${q} />'
  '                <cache-store-value key=${q}@("score-" + (string)context.Variables["backendName"])${q} value="99999" duration="600" />'
  '                <cache-store-value key=${q}@("degraded-" + (string)context.Variables["backendName"])${q} value="true" duration="900" />'
  '            </when>'
  '        </choose>'
  '    </on-error>'
  '</policies>'
], '\n')

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-09-01-preview' = {
  parent: api
  name: 'policy'
  dependsOn: [
    namedValues
    apimBackends
  ]
  properties: {
    value: policyXml
    format: 'rawxml'
  }
}

// ── Product ────────────────────────────────────────────────────────────────────

resource product 'Microsoft.ApiManagement/service/products@2023-09-01-preview' = {
  parent: apim
  name: 'llm-router'
  properties: {
    displayName: 'LLM Router'
    subscriptionRequired: false
    state: 'published'
  }
}

resource productApi 'Microsoft.ApiManagement/service/products/apis@2023-09-01-preview' = {
  parent: product
  name: api.name
}

// ── Application Insights Integration ───────────────────────────────────────────

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2023-09-01-preview' = if (!empty(appInsightsInstrumentationKey)) {
  parent: apim
  name: 'appinsights-logger'
  properties: {
    loggerType: 'applicationInsights'
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
    resourceId: appInsightsId
  }
}

resource apimDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2023-09-01-preview' = if (!empty(appInsightsInstrumentationKey)) {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────────

output apimGatewayUrl string = apim.properties.gatewayUrl
output apimName string = apim.name
output apimPrincipalId string = apim.identity.principalId
