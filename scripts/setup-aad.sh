#!/usr/bin/env bash
# Sets up the AAD app registration for azure-openai-latency-failover.
#
# Run without --function-mi-object-id FIRST (before deploying infrastructure)
# to create the app registration and get the app client ID.
#
# After deploying infrastructure, run again with --function-mi-object-id
# to grant the Probe.Execute role to the probe function's managed identity.
#
# Usage:
#   Step 1 (before infra deploy):
#     ./scripts/setup-aad.sh
#     ./scripts/setup-aad.sh --caller-object-id <YOUR_USER_OBJECT_ID>
#
#   Step 2 (after infra deploy):
#     ./scripts/setup-aad.sh --function-mi-object-id <OBJECT_ID>
#
#   Get your user object ID with: az ad signed-in-user show --query id -o tsv

set -euo pipefail

APP_DISPLAY_NAME="aoai-latency-router"
FUNCTION_MI_OBJECT_ID=""
CALLER_OBJECT_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)
      APP_DISPLAY_NAME="$2"
      shift 2
      ;;
    --function-mi-object-id)
      FUNCTION_MI_OBJECT_ID="$2"
      shift 2
      ;;
    --caller-object-id)
      CALLER_OBJECT_ID="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

uuid5() {
  node -e "
    const { createHash } = require('crypto');
    const name = process.argv[1];
    const ns = Buffer.from('6ba7b8109dad11d180b400c04fd430c8', 'hex');
    const h = createHash('sha1').update(ns).update(name).digest();
    h[6] = (h[6] & 0x0f) | 0x50;
    h[8] = (h[8] & 0x3f) | 0x80;
    const hex = h.toString('hex');
    console.log([hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20,32)].join('-'));
  " "$1"
}

LLM_INVOKE_ROLE_ID="$(uuid5 "${APP_DISPLAY_NAME}.LLM.Invoke")"
PROBE_EXECUTE_ROLE_ID="$(uuid5 "${APP_DISPLAY_NAME}.Probe.Execute")"

APP_ROLES=$(cat <<EOF
[
  {
    "id": "${LLM_INVOKE_ROLE_ID}",
    "allowedMemberTypes": ["Application"],
    "displayName": "LLM.Invoke",
    "description": "Invoke the LLM routing API",
    "isEnabled": true,
    "value": "LLM.Invoke"
  },
  {
    "id": "${PROBE_EXECUTE_ROLE_ID}",
    "allowedMemberTypes": ["Application"],
    "displayName": "Probe.Execute",
    "description": "Execute health probes",
    "isEnabled": true,
    "value": "Probe.Execute"
  }
]
EOF
)

echo "==> Checking if app registration '${APP_DISPLAY_NAME}' already exists..."
EXISTING_APP_ID=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_APP_ID" ]]; then
  echo "==> App registration already exists (appId: ${EXISTING_APP_ID}). Updating app roles..."
  APP_ID="$EXISTING_APP_ID"
  az ad app update --id "$APP_ID" --app-roles "$APP_ROLES"
else
  echo "==> Creating app registration '${APP_DISPLAY_NAME}'..."
  APP_ID=$(az ad app create \
    --display-name "$APP_DISPLAY_NAME" \
    --sign-in-audience AzureADMyOrg \
    --app-roles "$APP_ROLES" \
    --query appId -o tsv)
  echo "==> Created app registration (appId: ${APP_ID})"
fi

echo "==> Setting identifierUris to api://${APP_ID}..."
az ad app update --id "$APP_ID" --identifier-uris "api://${APP_ID}"

echo "==> Exposing user_impersonation delegated scope..."
SCOPE_ID="$(uuid5 "${APP_DISPLAY_NAME}.user_impersonation")"
OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${OBJECT_ID}" \
  --headers "Content-Type=application/json" \
  --body "{
    \"api\": {
      \"oauth2PermissionScopes\": [
        {
          \"id\": \"${SCOPE_ID}\",
          \"adminConsentDescription\": \"Access the Azure OpenAI latency router on behalf of a user\",
          \"adminConsentDisplayName\": \"Access AOAI Latency Router\",
          \"userConsentDescription\": \"Access the Azure OpenAI latency router\",
          \"userConsentDisplayName\": \"Access AOAI Latency Router\",
          \"value\": \"user_impersonation\",
          \"type\": \"User\",
          \"isEnabled\": true
        }
      ]
    }
  }"

echo "==> Ensuring service principal exists..."
EXISTING_SP=$(az ad sp list --filter "appId eq '${APP_ID}'" --query "[0].id" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_SP" ]]; then
  SP_OBJECT_ID="$EXISTING_SP"
  echo "==> Service principal already exists (objectId: ${SP_OBJECT_ID})"
else
  SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  echo "==> Created service principal (objectId: ${SP_OBJECT_ID})"
fi

echo ""
echo "========================================"
echo "  AAD App Client ID: ${APP_ID}"
echo "========================================"
echo ""
echo "Use this value for the 'aadAppClientId' parameter in your .bicepparam file."

if [[ -n "$CALLER_OBJECT_ID" ]]; then
  echo ""
  echo "==> Granting LLM.Invoke role to caller (${CALLER_OBJECT_ID})..."
  EXISTING=$(az rest --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignedTo" \
    --query "value[?principalId=='${CALLER_OBJECT_ID}' && appRoleId=='${LLM_INVOKE_ROLE_ID}'].id | [0]" \
    -o tsv 2>/dev/null || true)
  if [[ -n "$EXISTING" ]]; then
    echo "==> LLM.Invoke already granted to caller, skipping."
  else
    az rest --method POST \
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignedTo" \
      --headers "Content-Type=application/json" \
      --body "{
        \"principalId\": \"${CALLER_OBJECT_ID}\",
        \"resourceId\": \"${SP_OBJECT_ID}\",
        \"appRoleId\": \"${LLM_INVOKE_ROLE_ID}\"
      }"
    echo "==> LLM.Invoke granted."
  fi
fi

if [[ -z "$FUNCTION_MI_OBJECT_ID" ]]; then
  echo ""
  echo "Next: deploy infrastructure, then re-run with:"
  echo "  ./scripts/setup-aad.sh --function-mi-object-id <identityPrincipalId from deployment output>"
  exit 0
fi

echo ""
echo "==> Granting Probe.Execute role to Function MI (${FUNCTION_MI_OBJECT_ID})..."

EXISTING_ASSIGNMENT=$(az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignedTo" \
  --query "value[?principalId=='${FUNCTION_MI_OBJECT_ID}' && appRoleId=='${PROBE_EXECUTE_ROLE_ID}'].id | [0]" \
  -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_ASSIGNMENT" ]]; then
  echo "==> Role assignment already exists, skipping."
else
  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignedTo" \
    --headers "Content-Type=application/json" \
    --body "{
      \"principalId\": \"${FUNCTION_MI_OBJECT_ID}\",
      \"resourceId\": \"${SP_OBJECT_ID}\",
      \"appRoleId\": \"${PROBE_EXECUTE_ROLE_ID}\"
    }"
  echo "==> Probe.Execute role granted."
fi

echo ""
echo "Setup complete. The probe function will authenticate to APIM using its managed identity."
