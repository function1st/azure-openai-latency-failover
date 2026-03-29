#!/usr/bin/env bash
# Tears down all resources created by azure-openai-latency-failover.
# Preserves the Azure OpenAI resources in the resource group.
#
# Usage:
#   ./scripts/teardown.sh -g <RESOURCE_GROUP> [-p <NAME_PREFIX>] [-l <LOCATION>]
#
# Examples:
#   ./scripts/teardown.sh -g my-resource-group
#   ./scripts/teardown.sh -g my-resource-group -p aoai-lr -l eastus2

set -euo pipefail

RESOURCE_GROUP=""
NAME_PREFIX="aoai-lr"
LOCATION="eastus2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    -p|--prefix)         NAME_PREFIX="$2";    shift 2 ;;
    -l|--location)       LOCATION="$2";       shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "Error: -g <RESOURCE_GROUP> is required." >&2
  exit 1
fi

SUBSCRIPTION=$(az account show --query id -o tsv)
COGNITIVE_ROLE="5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"

echo "==> Removing Cognitive Services role assignments..."
for AOAI_ID in $(az cognitiveservices account list -g "$RESOURCE_GROUP" --query "[].id" -o tsv 2>/dev/null || true); do
  ASSIGNMENTS=$(az role assignment list --scope "$AOAI_ID" --role "$COGNITIVE_ROLE" --query "[].id" -o tsv 2>/dev/null || true)
  if [[ -n "$ASSIGNMENTS" ]]; then
    echo "    Removing from $(basename $AOAI_ID)..."
    echo "$ASSIGNMENTS" | xargs -I{} az role assignment delete --ids {} 2>/dev/null || true
  fi
done

echo "==> Deleting deployed resources (preserving Azure OpenAI resources)..."
RESOURCE_IDS=$(az resource list -g "$RESOURCE_GROUP" \
  --query "[?type!='Microsoft.CognitiveServices/accounts'].id" -o tsv 2>/dev/null || true)

if [[ -n "$RESOURCE_IDS" ]]; then
  echo "$RESOURCE_IDS" | xargs az resource delete --ids --no-wait 2>/dev/null || true
fi

echo "==> Purging soft-deleted APIM instance (if exists)..."
sleep 10
az apim deletedservice purge \
  --service-name "${NAME_PREFIX}-apim" \
  --location "$LOCATION" 2>/dev/null && echo "    Purged ${NAME_PREFIX}-apim." || echo "    No soft-deleted APIM found (ok)."

echo "==> Deleting AAD app registration..."
APP_ID=$(az ad app list --display-name "aoai-latency-router" --query "[0].appId" -o tsv 2>/dev/null || true)
if [[ -n "$APP_ID" ]]; then
  az ad app delete --id "$APP_ID" 2>/dev/null && echo "    Deleted app registration (appId: ${APP_ID})."
else
  echo "    No app registration found (ok)."
fi

echo ""
echo "Teardown complete. Azure OpenAI resources preserved."
echo "To redeploy, run: ./scripts/setup-aad.sh"
