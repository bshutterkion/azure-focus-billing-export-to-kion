#!/bin/bash
#
# onboard-tenant.sh — stand up one tenant end to end. Every step is
# independently re-runnable, so a partial failure is resumed by running again.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

TENANT_FILE=""; SKIP_LOGIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tenant-file) TENANT_FILE="$2"; shift 2 ;;
    --skip-login)  SKIP_LOGIN=1; shift ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$TENANT_FILE" ] && [ -f "$TENANT_FILE" ] || { log_err "tenant file not found: $TENANT_FILE"; exit 2; }

TENANT_ID="$(cfg_get "$TENANT_FILE" TENANT_ID)"
[ -n "$TENANT_ID" ] || { log_err "$TENANT_FILE has no TENANT_ID"; exit 2; }

# Per-tenant values override the shared environment, but only when the
# tenant file actually sets them. Capture the inherited value first: reading
# the tenant file straight into $AZURE_CLOUD would stomp an inherited value
# with an empty string before the fallback ever saw it, silently landing a
# Gov tenant that omits AZURE_CLOUD on Commercial endpoints.
inherited_cloud="${AZURE_CLOUD:-}"
tf_cloud="$(cfg_get "$TENANT_FILE" AZURE_CLOUD)"
AZURE_CLOUD="${tf_cloud:-${inherited_cloud:-AzureCloud}}"
export AZURE_CLOUD

RG="$(cfg_get "$TENANT_FILE" RESOURCE_GROUP)"
STORAGE="$(cfg_get "$TENANT_FILE" STORAGE_ACCOUNT)"
CONTAINER="$(cfg_get "$TENANT_FILE" CONTAINER)"
LOCATION="$(cfg_get "$TENANT_FILE" LOCATION)"
PREFIX="$(cfg_get "$TENANT_FILE" EXPORT_PREFIX)"; PREFIX="${PREFIX:-${EXPORT_PREFIX:-focus}}"
SCOPE="$(cfg_get "$TENANT_FILE" EXPORT_SCOPE)"; SCOPE="${SCOPE:-subscription}"
BILLING_SCOPE_ID="$(cfg_get "$TENANT_FILE" BILLING_SCOPE_ID)"
SUBSCRIPTIONS="$(cfg_get "$TENANT_FILE" SUBSCRIPTIONS)"
MG="$(cfg_get "$TENANT_FILE" MANAGEMENT_GROUP)"

# require_value VALUE LABEL SOURCE — fail loudly, naming which value came up
# empty and which step produced it. Without this, an empty app id, domain,
# secret or endpoint parsed out of another script's output would flow
# straight into the Kion billing source call and quietly register a broken
# source.
require_value() {
  [ -n "$1" ] || { log_err "$3 did not produce a value for $2"; exit 1; }
}

# 1) log in to this tenant
if [ "$SKIP_LOGIN" -eq 0 ]; then
  current="$(az account show --query tenantId -o tsv 2>/dev/null || echo "")"
  if [ "$current" != "$TENANT_ID" ]; then
    log_info "signing in to tenant $TENANT_ID"
    az login --tenant "$TENANT_ID" --only-show-errors >/dev/null
  fi
fi
current="$(az account show --query tenantId -o tsv 2>/dev/null || echo "")"
[ "$current" = "$TENANT_ID" ] || { log_err "active tenant '$current' is not the configured tenant '$TENANT_ID'"; exit 1; }

# 2) storage
BLOB_ENDPOINT="$("$HERE/ensure-storage.sh" --resource-group "$RG" --storage-account "$STORAGE" \
  --container "$CONTAINER" ${LOCATION:+--location "$LOCATION"})"
require_value "$BLOB_ENDPOINT" "the blob endpoint" "ensure-storage.sh"
STORAGE_ID="$(az storage account show --name "$STORAGE" --resource-group "$RG" --query id -o tsv)"

# 3) exports — before the billing source, so Kion is never pointed at an
#    empty container with nothing feeding it
"$HERE/create-focus-exports.sh" \
  --storage-account-id "$STORAGE_ID" --container "$CONTAINER" --prefix "$PREFIX" \
  --scope "$SCOPE" ${BILLING_SCOPE_ID:+--billing-scope-id "$BILLING_SCOPE_ID"} \
  ${SUBSCRIPTIONS:+--subscriptions "$SUBSCRIPTIONS"} \
  ${FOCUS_VERSION:+--focus-version "$FOCUS_VERSION"} \
  ${EXPORT_RECURRENCE:+--recurrence "$EXPORT_RECURRENCE"} \
  ${EXPORT_TIMEFRAME:+--timeframe "$EXPORT_TIMEFRAME"} >/dev/null

# 4) the app Kion authenticates as
app_out="$("$HERE/create-kion-app.sh" --resource-group "$RG" --storage-account "$STORAGE" \
  --container "$CONTAINER" ${MG:+--management-group "$MG"} ${KION_HOST:+--kion-url "$KION_HOST"})"
APP_ID="$(printf '%s\n' "$app_out" | sed -n 's/^APP_ID=//p')"
TENANT_DOMAIN="$(printf '%s\n' "$app_out" | sed -n 's/^TENANT_DOMAIN=//p')"
CREDENTIAL_FILE="$(printf '%s\n' "$app_out" | sed -n 's/^CREDENTIAL_FILE=//p')"
require_value "$APP_ID" "APP_ID" "create-kion-app.sh"
require_value "$TENANT_DOMAIN" "TENANT_DOMAIN" "create-kion-app.sh"
require_value "$CREDENTIAL_FILE" "CREDENTIAL_FILE" "create-kion-app.sh"
CLIENT_SECRET="$(cfg_get "$CREDENTIAL_FILE" AZURE_CLIENT_SECRET)"
require_value "$CLIENT_SECRET" "AZURE_CLIENT_SECRET" "$CREDENTIAL_FILE"

# 5) the Kion billing source
"$HERE/kion-create-billing-source.sh" --tenant-file "$TENANT_FILE" \
  --domain "$TENANT_DOMAIN" --app-id "$APP_ID" --client-secret "$CLIENT_SECRET" \
  --endpoint "$BLOB_ENDPOINT" --container "$CONTAINER" --prefix "$PREFIX"

log_info "tenant $TENANT_ID onboarded"
