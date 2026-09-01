#!/bin/bash
#
# kion-create-billing-source.sh — register the Kion billing source that reads a
# tenant's FOCUS exports from blob storage.
#
# Exit codes:
#   0  billing source created (payer id written back into the tenant file), or
#      --dry-run completed
#   1  the run failed
#   2  bad usage / missing required configuration
#   3  the tenant already has KION_PAYER_ID, so nothing was created AND the
#      existing source's FOCUS prefix was NOT updated. The tenant is onboarded,
#      but a human must set focus_storage_prefix in the Kion UI. Callers must
#      treat this as a warning, not a failure: it is not exit 0 because a run
#      that did not finish the job must never be summarised as plain "ok".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Temp files staged below (the curl request body, the tenant-file rewrite)
# are registered here and removed on any exit path, success or failure.
CLEANUP_FILES=()
cleanup() {
  local f
  for f in ${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}; do
    rm -f "$f"
  done
}
trap cleanup EXIT

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
  # Kion has no API for editing an existing Azure billing source (only the
  # Kion UI can), so there is no update path to attempt here. Warn loudly
  # instead of quietly declaring success: without this, a tenant onboarded
  # before the prefix bug was fixed stays pointed at a broken prefix forever,
  # and every re-run reports success without ever saying so.
  log_warn "billing source already exists (payer $EXISTING); its FOCUS prefix was NOT updated"
  log_warn "set focus_storage_prefix=$PREFIX on payer $EXISTING in the Kion UI (Kion has no API for editing an existing Azure billing source)"
  # Exit 3, not 0: stderr alone cannot reach the run summary, and a summary
  # row reading "ok" for a tenant whose prefix still needs setting by hand is
  # exactly how this stayed invisible. See the exit-code table above.
  exit 3
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

# Stage the request body in a temp file so it never appears in the curl
# command line (readable via `ps` / /proc/<pid>/cmdline for as long as the
# call is in flight). chmod it before the secret-bearing body is written,
# and clean it up on any exit path via the trap above.
body_file="$(mktemp)"
chmod 600 "$body_file"
CLEANUP_FILES+=("$body_file")
printf '%s' "$body" > "$body_file"

# The Authorization header carries the Kion API key. Keep both it and the
# body off argv by supplying them through a curl config file on stdin.
response="$(printf '%s\n' \
    "header = \"Authorization: Bearer ${KION_API_KEY}\"" \
    "data-binary = @${body_file}" \
  | curl -sS -w '\n%{http_code}' --config - \
    -H "Content-Type: application/json" -X POST "$url")"
http_code="$(echo "$response" | tail -n1)"
http_body="$(echo "$response" | sed '$d')"
case "$http_code" in
  2*) : ;;
  *) log_err "Kion returned HTTP $http_code: $http_body"; exit 1 ;;
esac

payer_id="$(printf '%s' "$http_body" | jq -r '.data.id // empty' 2>/dev/null || true)"
if [ -z "$payer_id" ]; then
  log_err "Kion accepted the request (HTTP $http_code) and created the billing source, but no payer id could be extracted from its response:"
  printf '%s\n' "$http_body" >&2
  log_err "record the payer id in $TENANT_FILE by hand (KION_PAYER_ID=<id>) before re-running this script, or it will attempt to create a duplicate billing source"
  exit 1
fi

if grep -qE '^[[:space:]]*KION_PAYER_ID=' "$TENANT_FILE"; then
  mode="$(stat -f '%Lp' "$TENANT_FILE" 2>/dev/null || stat -c '%a' "$TENANT_FILE" 2>/dev/null || true)"
  tmp="$(mktemp "${TENANT_FILE}.tmp.XXXXXX")"
  CLEANUP_FILES+=("$tmp")
  sed "s|^[[:space:]]*KION_PAYER_ID=.*|KION_PAYER_ID=${payer_id}|" "$TENANT_FILE" > "$tmp"
  mv "$tmp" "$TENANT_FILE"
  # The write-back above already succeeded and is atomic (mktemp+sed+mv). A
  # missing/unreadable mode (stat failed on both -f and -c forms) must not
  # fail the whole script here: skip the chmod, don't guard it with a bare
  # `[ -n "$mode" ] && chmod ...`, which relies on bash's easy-to-doubt
  # `&&`-list set -e exemption (the guard's own failure never propagates,
  # since chmod is the command actually checked, and it's simply never run).
  # An explicit if makes the "skip on missing mode" intent unambiguous
  # instead of resting on that idiom.
  if [ -n "$mode" ]; then
    chmod "$mode" "$TENANT_FILE"
  fi
else
  # This branch takes a hand-written tenant file, and a hand-written file may
  # not end in a newline. Appending straight onto its last line produces
  # `AZURE_CLOUD=AzureCloudKION_PAYER_ID=42`, which cfg_get reads as neither
  # key: the cloud silently becomes garbage (so the Kion account type can flip
  # Gov/Commercial) and the payer id is invisible, so the very next run creates
  # a duplicate billing source. Command substitution strips trailing newlines,
  # so a file already ending in one gives an empty last_byte and is left alone;
  # so is an empty file.
  last_byte="$(tail -c 1 "$TENANT_FILE")"
  if [ -n "$last_byte" ]; then
    printf '\n' >> "$TENANT_FILE"
  fi
  printf 'KION_PAYER_ID=%s\n' "$payer_id" >> "$TENANT_FILE"
fi
log_info "recorded KION_PAYER_ID=$payer_id in $TENANT_FILE"
