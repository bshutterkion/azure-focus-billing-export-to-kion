#!/bin/bash
#
# kion-create-billing-source.sh — register the Kion billing source that reads a
# tenant's FOCUS exports from blob storage.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TENANT_FILE=""; DOMAIN=""; APP_ID=""; CLIENT_SECRET=""
ENDPOINT=""; CONTAINER=""; PREFIX=""; NAME=""; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tenant-file)   TENANT_FILE="$2"; shift 2 ;;
    --domain)        DOMAIN="$2"; shift 2 ;;
    --app-id)        APP_ID="$2"; shift 2 ;;
    --client-secret) CLIENT_SECRET="$2"; shift 2 ;;
    --endpoint)      ENDPOINT="$2"; shift 2 ;;
    --container)     CONTAINER="$2"; shift 2 ;;
    --prefix)        PREFIX="$2"; shift 2 ;;
    --name)          NAME="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$TENANT_FILE" ] && [ -n "$DOMAIN" ] && [ -n "$APP_ID" ] || {
  log_err "--tenant-file, --domain and --app-id are required"; exit 2; }

KION_HOST="${KION_HOST:-}"; KION_API_KEY="${KION_API_KEY:-}"
KION_API_BASE="${KION_API_BASE:-/api}"
[ -n "$KION_HOST" ] && [ -n "$KION_API_KEY" ] || { log_err "KION_HOST and KION_API_KEY must be set"; exit 2; }

EXISTING="$(cfg_get "$TENANT_FILE" KION_PAYER_ID)"
if [ -n "$EXISTING" ]; then
  log_info "billing source already exists (payer $EXISTING); leaving it alone"
  exit 0
fi

MODEL="$(cfg_get "$TENANT_FILE" BILLING_MODEL)"; MODEL="${MODEL:-${BILLING_MODEL:-MCA}}"
CLOUD="$(cfg_get "$TENANT_FILE" AZURE_CLOUD)";   CLOUD="${CLOUD:-${AZURE_CLOUD:-AzureCloud}}"
ACCOUNT_TYPE_ID="$(kion_account_type "$MODEL" "$CLOUD")"
NAME="${NAME:-Azure $MODEL ($DOMAIN)}"

body="$(jq -nc \
  --argjson type "$ACCOUNT_TYPE_ID" --arg name "$NAME" --arg domain "$DOMAIN" \
  --arg app "$APP_ID" --arg secret "$CLIENT_SECRET" \
  --arg ep "$ENDPOINT" --arg cont "$CONTAINER" --arg prefix "$PREFIX" \
  '{account_type_id:$type, name:$name, domain:$domain,
    app_id:$app, client_secret:$secret,
    use_focus_reports:true,
    focus_storage_primary_endpoint:$ep,
    focus_storage_container:$cont,
    focus_storage_prefix:$prefix}')"

url="${KION_HOST%/}${KION_API_BASE%/}/v1/payer/standalone?createReport=false"
if [ "$DRY_RUN" -eq 1 ]; then
  log_info "[dry-run] would POST to $url"
  printf '%s\n' "$body" | jq 'del(.client_secret)'
  exit 0
fi

log_info "creating Kion billing source '$NAME' (account type $ACCOUNT_TYPE_ID)"
response="$(curl -sS -w '\n%{http_code}' -X POST \
  -H "Authorization: Bearer $KION_API_KEY" -H "Content-Type: application/json" \
  -d "$body" "$url")"
http_code="$(echo "$response" | tail -n1)"
http_body="$(echo "$response" | sed '$d')"
case "$http_code" in
  2*) : ;;
  *) log_err "Kion returned HTTP $http_code: $http_body"; exit 1 ;;
esac

payer_id="$(printf '%s' "$http_body" | jq -r '.data.id // empty' 2>/dev/null || true)"
if [ -n "$payer_id" ]; then
  if grep -qE '^[[:space:]]*KION_PAYER_ID=' "$TENANT_FILE"; then
    tmp="${TENANT_FILE}.tmp.$$"
    sed "s|^[[:space:]]*KION_PAYER_ID=.*|KION_PAYER_ID=${payer_id}|" "$TENANT_FILE" > "$tmp" \
      && cat "$tmp" > "$TENANT_FILE" && rm -f "$tmp"
  else
    printf 'KION_PAYER_ID=%s\n' "$payer_id" >> "$TENANT_FILE"
  fi
  log_info "recorded KION_PAYER_ID=$payer_id in $TENANT_FILE"
fi
