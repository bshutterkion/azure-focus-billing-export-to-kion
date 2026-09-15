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
  ""|exports|kion-source|app) : ;;
  *) log_err "--only must be 'exports', 'kion-source' or 'app', got '$ONLY'"; exit 2 ;;
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

# Which subscription the resource group, storage account and container are
# created in. Deliberately read from the tenant file only -- no capture-first
# fallback to an inherited value, unlike AZURE_CLOUD and the export settings
# below. A subscription id identifies one tenant's subscription and nothing
# else, so a shared .env default could only ever be wrong for every tenant but
# one, and inheriting it silently is exactly the failure the guard further down
# exists to catch. Same treatment as RESOURCE_GROUP/STORAGE_ACCOUNT above.
RESOURCE_SUBSCRIPTION_ID="$(cfg_get "$TENANT_FILE" RESOURCE_SUBSCRIPTION_ID)"
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
# BILLING_MODEL is capture-first like AZURE_CLOUD. It reaches
# create-focus-exports.sh so that script can refuse subscription scope under
# MCA, where the export is created successfully and then writes nothing.
inherited_billing_model="${BILLING_MODEL:-}"
tf_billing_model="$(cfg_get "$TENANT_FILE" BILLING_MODEL)"
BILLING_MODEL="${tf_billing_model:-${inherited_billing_model:-MCA}}"

# ONBOARD_MODE decides how much of the pipeline this tenant gets.
#
#   full        storage -> exports -> app -> billing source (the original shape)
#   management  app only
#
# management exists because a customer tenant under a shared MCA billing
# account has no export of its own that carries data: the only scope with data
# is the billing account, and that lives in the roll-up tenant and covers every
# tenant at once. The useful per-tenant work is then the app registration Kion
# manages the tenant and its subscriptions with, and nothing else.
inherited_mode="${ONBOARD_MODE:-}"
tf_mode="$(cfg_get "$TENANT_FILE" ONBOARD_MODE)"
ONBOARD_MODE="${tf_mode:-${inherited_mode:-full}}"
case "$ONBOARD_MODE" in
  full|management) : ;;
  *) log_err "ONBOARD_MODE must be 'full' or 'management', got '$ONBOARD_MODE'"; exit 2 ;;
esac

# Opt-in, and never inferred from ONBOARD_MODE: this grants the app
# roleAssignments write/delete and subscriptions/write at the management-group
# scope, which is a decision to make per customer rather than a side effect of
# choosing a mode.
inherited_subcreate="${ENABLE_SUBSCRIPTION_CREATION:-}"
tf_subcreate="$(cfg_get "$TENANT_FILE" ENABLE_SUBSCRIPTION_CREATION)"
ENABLE_SUBSCRIPTION_CREATION="${tf_subcreate:-$inherited_subcreate}"
# A typo must not read as false. Quietly granting nothing, for a setting whose
# only purpose is to grant something, is the silent-wrong class this codebase
# keeps getting bitten by -- so anything unrecognised is an error, not a no.
subcreate_lc="$(printf '%s' "$ENABLE_SUBSCRIPTION_CREATION" | tr '[:upper:]' '[:lower:]')"
case "$subcreate_lc" in
  "")          SUB_CREATION=0 ;;
  1|true|yes)  SUB_CREATION=1 ;;
  *)
    log_err "ENABLE_SUBSCRIPTION_CREATION must be empty, 1, true or yes; got '$ENABLE_SUBSCRIPTION_CREATION'"
    exit 2
    ;;
esac

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

# Which steps this run performs. ONBOARD_MODE=management and --only app both
# reduce to "the app registration and nothing else"; the difference is only
# that one is a durable property of the tenant and the other of this run.
#
# --only exports and --only kion-source both keep storage on, because each
# still needs the storage account id (and kion-source the blob endpoint) that
# step produces. Only the app-only paths turn it off.
DO_STORAGE=1; DO_EXPORTS=1; DO_APP=1; DO_BILLING=1
if [ "$ONBOARD_MODE" = management ] || [ "$ONLY" = app ]; then
  DO_STORAGE=0; DO_EXPORTS=0; DO_BILLING=0
else
  case "$ONLY" in
    exports)     DO_APP=0; DO_BILLING=0 ;;
    kion-source) DO_EXPORTS=0 ;;
  esac
fi

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

# The cloud needs the same check, for the same reason, because "which cloud"
# has two independent sources of truth here and nothing keeps them in step:
# resolve_cloud reads ARM/Graph/blob/AD endpoints from the CLI's *active*
# cloud, while AZURE_CLOUD above picks the Kion account type id (MCA 16 vs MCA
# Gov 18, CSP 3 vs CSP Gov 11). Signed in to AzureUSGovernment with a tenant
# file saying AzureCloud, the run would use Gov endpoints and create Gov
# storage, then register the source in Kion as AzureMCA instead of AzureMCAGov
# -- right data, wrong account type, and not one error anywhere. This tool
# never runs `az cloud set`, and onboard-all.sh loops Gov and Commercial
# tenants from one checkout, so only a check catches it.
#
# The check is deliberately outside the --skip-login branch above, exactly like
# the tenant check: --skip-login skips `az login`, it does not make an
# operator-supplied session safe to assume things about. It makes it less so.
#
# Switching the cloud here would mutate global CLI state the operator may be
# relying on elsewhere, and would need a fresh login anyway, so say what is
# wrong and stop.
active_cloud="$(az account show --query environmentName -o tsv 2>/dev/null || echo "")"
if [ "$active_cloud" != "$AZURE_CLOUD" ]; then
  log_err "active Azure cloud '$active_cloud' is not the configured cloud '$AZURE_CLOUD'"
  log_err "run 'az cloud set --name $AZURE_CLOUD' and sign in to tenant $TENANT_ID again"
  exit 1
fi

# RESOURCE_SUBSCRIPTION_ID gets the same treatment as the tenant and cloud
# checks above, and for the same reason: it is a hand-typed value that decides
# where resources land, and getting it wrong produces right data in the wrong
# place with no error.
#
# `az account list` returns every subscription in the CLI profile for this
# cloud, across every tenant that has ever signed into it -- and onboard-all.sh
# signs into each tenant in turn, so by the second tenant the profile holds the
# first tenant's subscriptions too. An id copied from the wrong row (or left
# behind from a previous customer's file) is therefore usually still *valid*,
# just not this tenant's: with access, the run would create this customer's
# storage inside another customer's tenant and register it in Kion without
# complaint. Filter by the tenant being onboarded and check membership here.
if [ "$DO_STORAGE" -eq 0 ]; then
  # No resources are created in this mode, so the storage keys are inert. Say
  # so rather than ignoring them: an operator who filled in STORAGE_ACCOUNT and
  # then finds no storage account has no way to tell a deliberate skip from a
  # broken run, and silently ignoring configuration somebody typed on purpose
  # is this project's most repeated bug.
  ignored=""
  for k in RESOURCE_GROUP STORAGE_ACCOUNT CONTAINER LOCATION RESOURCE_SUBSCRIPTION_ID BILLING_SCOPE_ID; do
    if [ -n "$(cfg_get "$TENANT_FILE" "$k")" ]; then
      ignored="$ignored $k"
    fi
  done
  if [ -n "$ignored" ]; then
    log_warn "no storage or exports are created in this mode; these keys in $TENANT_FILE are ignored:$ignored"
  fi
elif [ -n "$RESOURCE_SUBSCRIPTION_ID" ]; then
  guid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  if [[ ! "$RESOURCE_SUBSCRIPTION_ID" =~ $guid_re ]]; then
    log_err "RESOURCE_SUBSCRIPTION_ID '$RESOURCE_SUBSCRIPTION_ID' in $TENANT_FILE is not a subscription id"
    log_err "expected a bare GUID (8-4-4-4-12 hex characters)"
    exit 1
  fi
  tenant_subs="$(az account list --query "[?tenantId=='$TENANT_ID'].id" -o tsv | tr '\n' ' ')"
  sub_found=0
  for s in $tenant_subs; do
    [ "$s" = "$RESOURCE_SUBSCRIPTION_ID" ] && sub_found=1
  done
  if [ "$sub_found" -eq 0 ]; then
    log_err "RESOURCE_SUBSCRIPTION_ID '$RESOURCE_SUBSCRIPTION_ID' is not a subscription of tenant $TENANT_ID"
    log_err "subscriptions visible in this tenant:${tenant_subs:+ $tenant_subs}"
    log_err "check $TENANT_FILE; creating this tenant's storage in another tenant's subscription is what this check exists to prevent"
    exit 1
  fi
  log_info "resources will be created in subscription $RESOURCE_SUBSCRIPTION_ID"
else
  # Not an error -- every tenant file predating this setting relies on the
  # active subscription -- but it must not be invisible either. "It arbitrarily
  # chooses a subscription" is only arbitrary while nothing says which one.
  active_sub="$(az account show --query id -o tsv 2>/dev/null || echo "")"
  log_warn "RESOURCE_SUBSCRIPTION_ID is unset; using the CLI's active subscription ${active_sub:-<unknown>}. Set RESOURCE_SUBSCRIPTION_ID in $TENANT_FILE to pin it."
fi

# 2) storage
BLOB_ENDPOINT=""; STORAGE_ID=""
if [ "$DO_STORAGE" -eq 1 ]; then
  BLOB_ENDPOINT="$("$HERE/ensure-storage.sh" --resource-group "$RG" --storage-account "$STORAGE" \
    --container "$CONTAINER" ${LOCATION:+--location "$LOCATION"} \
    ${RESOURCE_SUBSCRIPTION_ID:+--subscription "$RESOURCE_SUBSCRIPTION_ID"})"
  require_value "$BLOB_ENDPOINT" "the blob endpoint" "ensure-storage.sh"
  # This id becomes the export's deliveryInfo destination and (in
  # create-kion-app.sh) the Storage Blob Data Reader role scope, so it has to be
  # resolved in the same subscription ensure-storage.sh just used.
  STORAGE_ID="$(az storage account show --name "$STORAGE" --resource-group "$RG" --query id -o tsv \
    ${RESOURCE_SUBSCRIPTION_ID:+--subscription "$RESOURCE_SUBSCRIPTION_ID"})"
  report_step storage ok
else
  report_step storage skipped
fi

# 3) exports — before the billing source, so Kion is never pointed at an
#    empty container with nothing feeding it. --only kion-source skips this
#    to re-run just the app + billing-source registration.
RUN_NOW_FLAG=""
[ "$NO_RUN_NOW" -eq 1 ] && RUN_NOW_FLAG="--no-run-now"

EXPORTS_OUT=""
if [ "$DO_EXPORTS" -eq 1 ]; then
  # --tenant-id is what keeps subscription discovery from seeing the previous
  # tenant's subscriptions, which are still in this CLI profile after
  # onboard-all.sh signed into them earlier in the same loop.
  #
  # --billing-model lets create-focus-exports.sh refuse subscription scope
  # under MCA, where the export is created and then writes nothing at all.
  EXPORTS_OUT="$("$HERE/create-focus-exports.sh" \
    --storage-account-id "$STORAGE_ID" --container "$CONTAINER" --prefix "$PREFIX" \
    --scope "$SCOPE" --tenant-id "$TENANT_ID" --billing-model "$BILLING_MODEL" \
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
if [ "$DO_APP" -eq 1 ]; then
  # --only kion-source skipped step 3, so EXPORTS_OUT never got the
  # KION_PREFIX= line create-focus-exports.sh normally reports. Recompute it
  # with --print-only: same scope-resolution and naming logic, including the
  # multi-subscription hard-fail, but no Azure call. Never reconstruct the
  # path by string-concatenation here — create-focus-exports.sh is the only
  # script that knows both rootFolderPath and the export name it chose.
  #
  # Skipped entirely when there is no billing source to point anywhere: an
  # app-only run has no export, so there is no prefix to compute and nothing
  # for a guessed one to do but mislead whoever reads the banner.
  KION_PREFIX=""
  if [ "$DO_BILLING" -eq 1 ]; then
    if [ -z "$EXPORTS_OUT" ]; then
      EXPORTS_OUT="$("$HERE/create-focus-exports.sh" --print-only \
        --storage-account-id "$STORAGE_ID" --container "$CONTAINER" --prefix "$PREFIX" \
        --scope "$SCOPE" --tenant-id "$TENANT_ID" --billing-model "$BILLING_MODEL" \
        ${BILLING_SCOPE_ID:+--billing-scope-id "$BILLING_SCOPE_ID"} \
        ${SUBSCRIPTIONS:+--subscriptions "$SUBSCRIPTIONS"})"
    fi
    KION_PREFIX="$(printf '%s\n' "$EXPORTS_OUT" | sed -n 's/^KION_PREFIX=//p' | tail -n1)"
    require_value "$KION_PREFIX" "KION_PREFIX" "create-focus-exports.sh"
  fi

  # Storage arguments are passed only when this run created storage.
  # create-kion-app.sh already skips the Storage Blob Data Reader grant and
  # prints no FOCUS endpoint/container/prefix lines when they are absent, which
  # is exactly right for an app-only run: there is no container to grant on.
  #
  # --prefix is "$KION_PREFIX", never the bare EXPORT_PREFIX: create-kion-app.sh's
  # framed summary is what an operator copies into the Kion UI, and it must
  # print the same value that reaches the billing source below. The two
  # diverging is the branch's original headline defect.
  app_args=()
  if [ "$DO_STORAGE" -eq 1 ]; then
    app_args+=(--resource-group "$RG" --storage-account "$STORAGE" --container "$CONTAINER")
    if [ -n "$RESOURCE_SUBSCRIPTION_ID" ]; then
      app_args+=(--subscription "$RESOURCE_SUBSCRIPTION_ID")
    fi
  fi
  if [ -n "$KION_PREFIX" ]; then
    app_args+=(--prefix "$KION_PREFIX")
  fi
  if [ -n "$MG" ]; then
    app_args+=(--management-group "$MG")
  fi
  if [ -n "${KION_HOST:-}" ]; then
    app_args+=(--kion-url "$KION_HOST")
  fi
  # Explicit `if`, not `[ ... ] && app_args+=(...)`: this file relies on set -e,
  # and a bare &&-list guard rests on an exemption that is easy to misread.
  if [ "$SUB_CREATION" -eq 1 ]; then
    app_args+=(--enable-subscription-creation)
  fi
  app_out="$("$HERE/create-kion-app.sh" ${app_args[@]+"${app_args[@]}"})"
  APP_ID="$(printf '%s\n' "$app_out" | sed -n 's/^APP_ID=//p')"
  TENANT_DOMAIN="$(printf '%s\n' "$app_out" | sed -n 's/^TENANT_DOMAIN=//p')"
  CREDENTIAL_FILE="$(printf '%s\n' "$app_out" | sed -n 's/^CREDENTIAL_FILE=//p')"
  require_value "$APP_ID" "APP_ID" "create-kion-app.sh"
  require_value "$TENANT_DOMAIN" "TENANT_DOMAIN" "create-kion-app.sh"
  require_value "$CREDENTIAL_FILE" "CREDENTIAL_FILE" "create-kion-app.sh"
  CLIENT_SECRET="$(cfg_get "$CREDENTIAL_FILE" AZURE_CLIENT_SECRET)"
  require_value "$CLIENT_SECRET" "AZURE_CLIENT_SECRET" "$CREDENTIAL_FILE"
  report_step app ok
else
  report_step app skipped
fi

# 5) the Kion billing source. Separate from the app step now, because an
# app-only run does both halves of that pair differently: it creates the app
# and registers nothing, since the tenant's spend arrives through another
# tenant's export entirely.
if [ "$DO_BILLING" -eq 1 ]; then
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
  report_step billing-source skipped
fi

if [ "$ONBOARD_MODE" = management ] || [ "$ONLY" = app ]; then
  log_info "tenant $TENANT_ID: app registration ready; this tenant's spend is expected to arrive through another tenant's export"
else
  case "$ONLY" in
    exports)     log_info "tenant $TENANT_ID: FOCUS exports re-created" ;;
    kion-source) log_info "tenant $TENANT_ID: Kion billing source re-registered" ;;
    *)           log_info "tenant $TENANT_ID onboarded" ;;
  esac
fi
