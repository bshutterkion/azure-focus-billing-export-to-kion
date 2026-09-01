#!/bin/bash
#
# onboard-tenant.sh — stand up one tenant end to end. Every step is
# independently re-runnable, so a partial failure is resumed by running again.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

TENANT_FILE=""; SKIP_LOGIN=0; ONLY=""; NO_RUN_NOW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tenant-file) TENANT_FILE="$2"; shift 2 ;;
    --skip-login)  SKIP_LOGIN=1; shift ;;
    --only)        ONLY="$2"; shift 2 ;;
    --no-run-now)  NO_RUN_NOW=1; shift ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$TENANT_FILE" ] && [ -f "$TENANT_FILE" ] || { log_err "tenant file not found: $TENANT_FILE"; exit 2; }
case "$ONLY" in
  ""|exports|kion-source) : ;;
  *) log_err "--only must be 'exports' or 'kion-source', got '$ONLY'"; exit 2 ;;
esac

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

# EXPORT_SCOPE follows the same capture-first precedence as AZURE_CLOUD
# above. Default is billingAccount, not subscription: a tenant with more
# than one subscription would otherwise produce one export per subscription,
# and Kion keeps only the newest manifest under a prefix, silently dropping
# every other subscription's costs. subscription scope stays available and
# correct for a single-subscription tenant.
inherited_scope="${EXPORT_SCOPE:-}"
tf_scope="$(cfg_get "$TENANT_FILE" EXPORT_SCOPE)"
SCOPE="${tf_scope:-${inherited_scope:-billingAccount}}"
BILLING_SCOPE_ID="$(cfg_get "$TENANT_FILE" BILLING_SCOPE_ID)"
SUBSCRIPTIONS="$(cfg_get "$TENANT_FILE" SUBSCRIPTIONS)"
MG="$(cfg_get "$TENANT_FILE" MANAGEMENT_GROUP)"

# EXPORT_API_VERSION follows the same capture-first precedence as
# AZURE_CLOUD above: Azure moves this version out from under
# create-focus-exports.sh's default, and 2023-08-01 and earlier cannot
# create FOCUS exports at all, so a tenant may need to pin a specific
# version independent of (and overriding) the shared .env default.
inherited_export_api_version="${EXPORT_API_VERSION:-}"
tf_export_api_version="$(cfg_get "$TENANT_FILE" EXPORT_API_VERSION)"
EXPORT_API_VERSION="${tf_export_api_version:-$inherited_export_api_version}"

# FOCUS_VERSION, EXPORT_RECURRENCE and EXPORT_TIMEFRAME get the same
# capture-first treatment. They used to be read straight from the environment,
# so the README's "per-tenant values override .env" promise was false for
# exactly these three: a tenant file setting one was parsed by nobody and
# silently ignored, which is this project's recurring silent-wrong class.
inherited_focus_version="${FOCUS_VERSION:-}"
tf_focus_version="$(cfg_get "$TENANT_FILE" FOCUS_VERSION)"
FOCUS_VERSION="${tf_focus_version:-$inherited_focus_version}"

inherited_recurrence="${EXPORT_RECURRENCE:-}"
tf_recurrence="$(cfg_get "$TENANT_FILE" EXPORT_RECURRENCE)"
EXPORT_RECURRENCE="${tf_recurrence:-$inherited_recurrence}"

inherited_timeframe="${EXPORT_TIMEFRAME:-}"
tf_timeframe="$(cfg_get "$TENANT_FILE" EXPORT_TIMEFRAME)"
EXPORT_TIMEFRAME="${tf_timeframe:-$inherited_timeframe}"

# report_step NAME STATE — one machine-readable line on stdout per step, as it
# completes, so onboard-all.sh can render a per-step summary row even when the
# run dies partway through. Progress and diagnostics stay on stderr; this is
# the only thing this script writes to stdout.
report_step() { printf 'STEP=%s:%s\n' "$1" "$2"; }
report_step_detail() { printf 'STEP_DETAIL=%s\n' "$1"; }

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
report_step storage ok

# 3) exports — before the billing source, so Kion is never pointed at an
#    empty container with nothing feeding it. --only kion-source skips this
#    to re-run just the app + billing-source registration.
RUN_NOW_FLAG=""
[ "$NO_RUN_NOW" -eq 1 ] && RUN_NOW_FLAG="--no-run-now"

EXPORTS_OUT=""
if [ "$ONLY" != "kion-source" ]; then
  # --tenant-id is what keeps subscription discovery from seeing the previous
  # tenant's subscriptions, which are still in this CLI profile after
  # onboard-all.sh signed into them earlier in the same loop.
  EXPORTS_OUT="$("$HERE/create-focus-exports.sh" \
    --storage-account-id "$STORAGE_ID" --container "$CONTAINER" --prefix "$PREFIX" \
    --scope "$SCOPE" --tenant-id "$TENANT_ID" \
    ${BILLING_SCOPE_ID:+--billing-scope-id "$BILLING_SCOPE_ID"} \
    ${SUBSCRIPTIONS:+--subscriptions "$SUBSCRIPTIONS"} \
    ${FOCUS_VERSION:+--focus-version "$FOCUS_VERSION"} \
    ${EXPORT_RECURRENCE:+--recurrence "$EXPORT_RECURRENCE"} \
    ${EXPORT_TIMEFRAME:+--timeframe "$EXPORT_TIMEFRAME"} \
    ${EXPORT_API_VERSION:+--api-version "$EXPORT_API_VERSION"} \
    $RUN_NOW_FLAG)"
  report_step exports ok
else
  report_step exports skipped
fi

# 4) & 5) the app Kion authenticates as, and the Kion billing source itself.
# --only exports skips both to re-run just the FOCUS export creation.
if [ "$ONLY" != "exports" ]; then
  # --only kion-source skipped step 3, so EXPORTS_OUT never got the
  # KION_PREFIX= line create-focus-exports.sh normally reports. Recompute it
  # with --print-only: same scope-resolution and naming logic, including the
  # multi-subscription hard-fail, but no Azure call. Never reconstruct the
  # path by string-concatenation here — create-focus-exports.sh is the only
  # script that knows both rootFolderPath and the export name it chose.
  if [ -z "$EXPORTS_OUT" ]; then
    EXPORTS_OUT="$("$HERE/create-focus-exports.sh" --print-only \
      --storage-account-id "$STORAGE_ID" --container "$CONTAINER" --prefix "$PREFIX" \
      --scope "$SCOPE" --tenant-id "$TENANT_ID" \
      ${BILLING_SCOPE_ID:+--billing-scope-id "$BILLING_SCOPE_ID"} \
      ${SUBSCRIPTIONS:+--subscriptions "$SUBSCRIPTIONS"})"
  fi
  KION_PREFIX="$(printf '%s\n' "$EXPORTS_OUT" | sed -n 's/^KION_PREFIX=//p' | tail -n1)"
  require_value "$KION_PREFIX" "KION_PREFIX" "create-focus-exports.sh"

  # --prefix "$KION_PREFIX", never the bare EXPORT_PREFIX: create-kion-app.sh's
  # framed summary is what an operator copies into the Kion UI, and it must
  # print the same value that reaches the billing source below. The two
  # diverging is the branch's original headline defect.
  app_out="$("$HERE/create-kion-app.sh" --resource-group "$RG" --storage-account "$STORAGE" \
    --container "$CONTAINER" --prefix "$KION_PREFIX" \
    ${MG:+--management-group "$MG"} ${KION_HOST:+--kion-url "$KION_HOST"})"
  APP_ID="$(printf '%s\n' "$app_out" | sed -n 's/^APP_ID=//p')"
  TENANT_DOMAIN="$(printf '%s\n' "$app_out" | sed -n 's/^TENANT_DOMAIN=//p')"
  CREDENTIAL_FILE="$(printf '%s\n' "$app_out" | sed -n 's/^CREDENTIAL_FILE=//p')"
  require_value "$APP_ID" "APP_ID" "create-kion-app.sh"
  require_value "$TENANT_DOMAIN" "TENANT_DOMAIN" "create-kion-app.sh"
  require_value "$CREDENTIAL_FILE" "CREDENTIAL_FILE" "create-kion-app.sh"
  CLIENT_SECRET="$(cfg_get "$CREDENTIAL_FILE" AZURE_CLIENT_SECRET)"
  require_value "$CLIENT_SECRET" "AZURE_CLIENT_SECRET" "$CREDENTIAL_FILE"
  report_step app ok

  # Exit 3 means "source already existed, prefix not updated": a warning, not a
  # failure, so it must not abort the run under set -e -- but it must also not
  # be summarised as plain "ok". Anything else keeps its own exit code.
  set +e
  "$HERE/kion-create-billing-source.sh" --tenant-file "$TENANT_FILE" \
    --domain "$TENANT_DOMAIN" --app-id "$APP_ID" --client-secret "$CLIENT_SECRET" \
    --endpoint "$BLOB_ENDPOINT" --container "$CONTAINER" --prefix "$KION_PREFIX"
  bs_rc=$?
  set -e
  case "$bs_rc" in
    0) report_step billing-source ok ;;
    3)
      existing_payer="$(cfg_get "$TENANT_FILE" KION_PAYER_ID)"
      # create-kion-app.sh minted a fresh client secret above (--append, so
      # nothing existing was invalidated) and this run has no way to deliver it
      # to Kion. Say so here rather than leave it generated and discarded: the
      # operator is already going to the Kion UI to set the prefix, and the new
      # secret in the credential file is the one to paste while they are there.
      log_warn "a new client secret was generated for app $APP_ID and NOT delivered to Kion; paste it from $CREDENTIAL_FILE alongside the prefix above"
      report_step billing-source warn
      report_step_detail "payer $existing_payer exists; set focus_storage_prefix=$KION_PREFIX and the new secret from $CREDENTIAL_FILE in the Kion UI"
      ;;
    *) exit "$bs_rc" ;;
  esac
else
  report_step app skipped
  report_step billing-source skipped
fi

case "$ONLY" in
  exports)     log_info "tenant $TENANT_ID: FOCUS exports re-created" ;;
  kion-source) log_info "tenant $TENANT_ID: Kion billing source re-registered" ;;
  *)           log_info "tenant $TENANT_ID onboarded" ;;
esac
