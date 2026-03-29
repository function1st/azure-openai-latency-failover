# Contributing to azure-openai-latency-failover

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Create a feature branch: `git checkout -b feature/my-change`

## Development

### Prerequisites

- Azure CLI (`az`) logged in with permissions to create APIM, Function Apps, and role assignments
- Node.js 20+
- Azure Functions Core Tools v4
- Bicep CLI (included with Azure CLI)

### Adding a New Backend Region

Add an entry to the `backends` array in your `.bicepparam` file:

```bicep
param backends = [
  // existing backends...
  { name: 'swedencentral', endpoint: 'https://my-aoai-swc.openai.azure.com', resourceId: '/subscriptions/.../resourceGroups/.../providers/Microsoft.CognitiveServices/accounts/my-aoai-swc' }
]
```

Redeploy with `az deployment group create`. The Bicep generates updated policy XML automatically.

### Modifying Thresholds

Thresholds are APIM named values, tunable in the Azure portal without redeployment:

| Named Value | Default | Description |
|---|---|---|
| `ttft-trip-ms` | 8000 | TTFT above this triggers badcount increment |
| `ttft-clear-ms` | 3000 | TTFT below this clears degraded flag |
| `ema-alpha` | 0.3 | EMA smoothing factor (higher = more reactive) |
| `consecutive-bad-threshold` | 2 | Consecutive bad readings before tripping |

### Validating Bicep

```bash
az bicep build -f infra/main.bicep
az bicep lint -f infra/main.bicep
```

## Submitting Changes

1. Ensure Bicep lints cleanly
2. Test against a real Azure environment if possible
3. Open a PR with a clear description of the change and why
4. One approval required to merge

## Reporting Issues

Open a GitHub issue with:
- What you expected vs. what happened
- Your APIM tier and region configuration
- Relevant APIM policy logs or App Insights traces
