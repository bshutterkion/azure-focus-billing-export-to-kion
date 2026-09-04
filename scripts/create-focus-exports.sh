#!/bin/bash
#
# create-focus-exports.sh — create Azure Cost Management FOCUS exports.
#
# FocusCost only: the FOCUS dataset already carries both actual (BilledCost)
# and amortized (EffectiveCost) costs.
#
# `az costmanagement export create` cannot create FOCUS exports (it accepts
# only ActualCost, AmortizedCost and Usage), so this uses `az rest`, which
# reuses the CLI's existing auth.
#
# Output: progress goes to stderr. On success, stdout carries, per export
# created (or, with --print-only, per export that *would* be created):
#   <export name>            (omitted with --print-only)
#   KION_PREFIX=<value>
# KION_PREFIX is the prefix Kion's billing source must be pointed at: Azure
# inserts the export name itself as a folder below rootFolderPath, so the
# value is always "<rootFolderPath>/<export name>", never the bare
# rootFolderPath a caller might otherwise guess at.
#
# --tenant-id is required when subscription scope has to discover the tenant's
# subscriptions itself; see the comment on the `az account list` call below.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

STORAGE_ID=""; CONTAINER=""; PREFIX="focus"
SCOPE="subscription"; BILLING_SCOPE_ID=""; SUBSCRIPTIONS=""; TENANT_ID=""
FOCUS_VERSION="1.0"; RECURRENCE="Daily"; TIMEFRAME="MonthToDate"
API_VERSION="2025-03-01"
PRINT_ONLY=0; NO_RUN_NOW=0

while [ $# -gt 0 ]; do
  case "$1" in
    --storage-account-id) STORAGE_ID="$2"; shift 2 ;;
    --container)          CONTAINER="$2"; shift 2 ;;
    --prefix)             PREFIX="$2"; shift 2 ;;
    --scope)              SCOPE="$2"; shift 2 ;;
    --billing-scope-id)   BILLING_SCOPE_ID="$2"; shift 2 ;;
    --subscriptions)      SUBSCRIPTIONS="$2"; shift 2 ;;
    --tenant-id)          TENANT_ID="$2"; shift 2 ;;
    --focus-version)      FOCUS_VERSION="$2"; shift 2 ;;
    --recurrence)         RECURRENCE="$2"; shift 2 ;;
    --timeframe)          TIMEFRAME="$2"; shift 2 ;;
    --api-version)        API_VERSION="$2"; shift 2 ;;
    --print-only)         PRINT_ONLY=1; shift ;;
    --no-run-now)         NO_RUN_NOW=1; shift ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$STORAGE_ID" ] && [ -n "$CONTAINER" ] || {
  log_err "--storage-account-id and --container are required"; exit 2; }

# Strip trailing slashes so "--prefix focus/" and "--prefix focus" produce an
# identical rootFolderPath/KION_PREFIX. A trailing empty path segment is not
# guaranteed to survive Azure's own path handling untouched, and Defect 1
# (Task 9) would otherwise return via exactly this kind of hand-edited-.env
# trailing slash.
while [ "${PREFIX%/}" != "$PREFIX" ]; do
  PREFIX="${PREFIX%/}"
done

resolve_cloud

# Scopes to export at. Management group scope is not supported for FOCUS.
SCOPES=""
case "$SCOPE" in
  subscription)
    if [ -z "$SUBSCRIPTIONS" ]; then
      # `az account list` returns every subscription in the CLI profile for the
      # current cloud -- across every tenant that has ever signed in to it, not
      # just the active one. onboard-all.sh signs into each tenant in turn, so
      # by the second tenant the profile holds the first tenant's subscriptions
      # too: the tool's own loop creates the condition. Unfiltered, that either
      # trips the >1 guard below on a legitimate single-subscription tenant, or
      # (with access) creates an export against a subscription in the wrong
      # tenant. Filter server-side by the tenant actually being onboarded.
      [ -n "$TENANT_ID" ] || {
        log_err "--tenant-id is required to discover subscriptions at subscription scope"
        log_err "without it 'az account list' would return every tenant's subscriptions in this CLI profile, not just this tenant's"
        exit 2; }
      SUBSCRIPTIONS="$(az account list --query "[?tenantId=='$TENANT_ID'].id" -o tsv | tr '\n' ' ')"
    fi
    found=""; count=0
    # Every entry must be a bare GUID: subscription ids never carry commas or
    # other separators. Rejecting anything else catches
    # --subscriptions "sub-a,sub-b" (a single shell word, so the loop below
    # would otherwise count it as one subscription and PUT to a nonsense
    # "subscriptions/sub-a,sub-b" scope) before it ever reaches the guard
    # whose entire purpose is "never more than one subscription".
    guid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    for s in $SUBSCRIPTIONS; do
      [ -n "$s" ] || continue
      if [[ ! "$s" =~ $guid_re ]]; then
        log_err "malformed subscription id '$s': expected a bare GUID (8-4-4-4-12 hex characters)"
        exit 1
      fi
      SCOPES="$SCOPES subscriptions/$s"
      found="$found $s"
      count=$((count + 1))
    done
    # Kion keeps only the newest manifest under a billing source's prefix, so
    # N subscription exports produce N manifests and Kion ingests exactly
    # one: the other N-1 subscriptions' costs vanish with no error anywhere.
    # Fail loudly before creating anything rather than risk missing money in
    # a customer's bill.
    if [ "$count" -gt 1 ]; then
      log_err "EXPORT_SCOPE=subscription resolved to $count subscriptions:$found"
      log_err "one Kion billing source can consume only one export; set EXPORT_SCOPE=billingAccount (or billingProfile) with BILLING_SCOPE_ID for a tenant with more than one subscription"
      log_err "billing scopes require an MCA or EA billing account. A CSP (Microsoft Partner Agreement) customer tenant does not support them: its only tenant-wide FOCUS scope is Customer scope, which lives in the partner tenant and is not reachable from here. A multi-subscription CSP tenant cannot be onboarded with this tool."
      exit 1
    fi
    ;;
  billingProfile|billingAccount)
    [ -n "$BILLING_SCOPE_ID" ] || { log_err "--billing-scope-id is required for scope '$SCOPE'"; exit 2; }
    # Validate that the resolved scope is actually shaped like the scope the
    # caller declared. Without this, --scope billingAccount --billing-scope-id
    # /subscriptions/<id> (or any other string) silently creates a
    # subscription-scoped export instead: exactly the money-losing failure
    # mode the subscription-count guard above exists to prevent, reached
    # through the path that is now the default and whose value is hand-typed.
    normalized="${BILLING_SCOPE_ID#/}"
    case "$SCOPE" in
      billingAccount)
        shape_re='^providers/Microsoft\.Billing/billingAccounts/[^/]+$'
        shape_desc="providers/Microsoft.Billing/billingAccounts/<id>"
        ;;
      billingProfile)
        shape_re='^providers/Microsoft\.Billing/billingAccounts/[^/]+/billingProfiles/[^/]+$'
        shape_desc="providers/Microsoft.Billing/billingAccounts/<id>/billingProfiles/<id>"
        ;;
    esac
    if [[ ! "$normalized" =~ $shape_re ]]; then
      log_err "scope '$SCOPE' requires --billing-scope-id shaped like $shape_desc; got '$BILLING_SCOPE_ID'"
      exit 1
    fi
    SCOPES="$normalized"
    ;;
  *) log_err "unknown scope '$SCOPE'"; exit 2 ;;
esac
[ -n "$SCOPES" ] || { log_err "no scopes resolved; nothing to export"; exit 1; }

START="$(date -u +%Y-%m-%d)T00:00:00Z"
END="$(date -u -v+5y +%Y-%m-%d 2>/dev/null || date -u -d '+5 years' +%Y-%m-%d)T00:00:00Z"

# sanitize_leaf — a billing account/profile id (the scope's leaf) can carry
# characters an Azure resource name cannot, e.g. MCA's
# "<account-guid>:<profile-guid>_<date>". Keep alphanumerics, hyphens and
# underscores; replace everything else with a hyphen. Deterministic, so a
# re-run updates the same export instead of creating a duplicate.
sanitize_leaf() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_-]/-/g'
}

# Azure does not publish a hard length limit for Cost Management export
# names, but the name becomes a blob path segment, so keep it well inside
# every observed/recommended ceiling.
MAX_EXPORT_NAME_LEN=64
NAME_PREFIX="kion-focus-"

for scope in $SCOPES; do
  leaf="${scope##*/}"
  safe_leaf="$(sanitize_leaf "$leaf")"
  name="${NAME_PREFIX}${safe_leaf}"
  if [ "${#name}" -gt "$MAX_EXPORT_NAME_LEN" ]; then
    keep=$((MAX_EXPORT_NAME_LEN - ${#NAME_PREFIX}))
    safe_leaf="${safe_leaf:0:$keep}"
    name="${NAME_PREFIX}${safe_leaf}"
  fi
  # rootFolderPath uses the same sanitized, possibly-truncated leaf as the
  # export name, so KION_PREFIX ("$root/$name") is always exactly what Azure
  # will actually write to, never a guess built from the raw, unsafe leaf.
  root="$PREFIX/$safe_leaf"
  kion_prefix="$root/$name"

  if [ "$PRINT_ONLY" -eq 1 ]; then
    echo "KION_PREFIX=$kion_prefix"
    continue
  fi

  body="$(jq -nc \
    --arg rec "$RECURRENCE" --arg from "$START" --arg to "$END" \
    --arg sid "$STORAGE_ID" --arg cont "$CONTAINER" --arg root "$root" \
    --arg tf "$TIMEFRAME" --arg ver "$FOCUS_VERSION" \
    '{properties:{
        schedule:{status:"Active", recurrence:$rec,
                  recurrencePeriod:{from:$from, to:$to}},
        format:"Csv",
        deliveryInfo:{destination:{resourceId:$sid, container:$cont, rootFolderPath:$root}},
        definition:{type:"FocusCost", timeframe:$tf,
                    dataSet:{granularity:"Daily", configuration:{dataVersion:$ver}}},
        partitionData:true,
        dataOverwriteBehavior:"CreateNewReport",
        compressionMode:"None"}}')"
  url="${ARM_ENDPOINT}/${scope}/providers/Microsoft.CostManagement/exports/${name}?api-version=${API_VERSION}"
  log_info "creating FOCUS export '$name' at $scope"
  if az rest --method put --url "$url" --body "$body" --only-show-errors >/dev/null; then
    echo "$name"
    echo "KION_PREFIX=$kion_prefix"
  else
    log_err "failed to create export '$name' at $scope"
    exit 1
  fi

  if [ "$NO_RUN_NOW" -eq 1 ]; then
    continue
  fi
  # Trigger an on-demand run: a newly created export's nextRunTimeEstimate is
  # about a day out, so without this an operator finishes onboarding and sees
  # nothing in Kion until the next day, indistinguishable from a broken
  # setup. A failed kick-off is a warning, not an error: the export exists
  # and will run on its normal schedule regardless.
  run_url="${ARM_ENDPOINT}/${scope}/providers/Microsoft.CostManagement/exports/${name}/run?api-version=${API_VERSION}"
  if az rest --method post --url "$run_url" --only-show-errors >/dev/null; then
    log_info "triggered an on-demand run for '$name'"
  else
    log_warn "could not trigger an on-demand run for '$name'; it will still run on its normal schedule"
  fi
done
