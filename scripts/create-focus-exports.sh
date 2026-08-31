#!/bin/bash
#
# create-focus-exports.sh — create Azure Cost Management FOCUS exports.
#
# FocusCost only: the FOCUS dataset already carries both actual (BilledCost)
# and amortized (EffectiveCost) costs, and Kion's FOCUS ingestion cannot read
# the ActualCost/AmortizedCost dataset types.
#
# `az costmanagement export create` cannot create FOCUS exports (it accepts
# only ActualCost, AmortizedCost and Usage), so this uses `az rest`, which
# reuses the CLI's existing auth.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

STORAGE_ID=""; CONTAINER=""; PREFIX="focus"
SCOPE="subscription"; BILLING_SCOPE_ID=""; SUBSCRIPTIONS=""
FOCUS_VERSION="1.0"; RECURRENCE="Daily"; TIMEFRAME="MonthToDate"
API_VERSION="2023-08-01"

while [ $# -gt 0 ]; do
  case "$1" in
    --storage-account-id) STORAGE_ID="$2"; shift 2 ;;
    --container)          CONTAINER="$2"; shift 2 ;;
    --prefix)             PREFIX="$2"; shift 2 ;;
    --scope)              SCOPE="$2"; shift 2 ;;
    --billing-scope-id)   BILLING_SCOPE_ID="$2"; shift 2 ;;
    --subscriptions)      SUBSCRIPTIONS="$2"; shift 2 ;;
    --focus-version)      FOCUS_VERSION="$2"; shift 2 ;;
    --recurrence)         RECURRENCE="$2"; shift 2 ;;
    --timeframe)          TIMEFRAME="$2"; shift 2 ;;
    --api-version)        API_VERSION="$2"; shift 2 ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$STORAGE_ID" ] && [ -n "$CONTAINER" ] || {
  log_err "--storage-account-id and --container are required"; exit 2; }

resolve_cloud

# Scopes to export at. Management group scope is not supported for FOCUS.
SCOPES=""
case "$SCOPE" in
  subscription)
    if [ -z "$SUBSCRIPTIONS" ]; then
      SUBSCRIPTIONS="$(az account list --query "[].id" -o tsv | tr '\n' ' ')"
    fi
    for s in $SUBSCRIPTIONS; do
      [ -n "$s" ] && SCOPES="$SCOPES subscriptions/$s"
    done
    ;;
  billingProfile|billingAccount)
    [ -n "$BILLING_SCOPE_ID" ] || { log_err "--billing-scope-id is required for scope '$SCOPE'"; exit 2; }
    SCOPES="${BILLING_SCOPE_ID#/}"
    ;;
  *) log_err "unknown scope '$SCOPE'"; exit 2 ;;
esac
[ -n "$SCOPES" ] || { log_err "no scopes resolved; nothing to export"; exit 1; }

START="$(date -u +%Y-%m-%d)T00:00:00Z"
END="$(date -u -v+5y +%Y-%m-%d 2>/dev/null || date -u -d '+5 years' +%Y-%m-%d)T00:00:00Z"

for scope in $SCOPES; do
  leaf="${scope##*/}"
  name="kion-focus-${leaf}"
  body="$(jq -nc \
    --arg rec "$RECURRENCE" --arg from "$START" --arg to "$END" \
    --arg sid "$STORAGE_ID" --arg cont "$CONTAINER" --arg root "$PREFIX/$leaf" \
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
  else
    log_err "failed to create export '$name' at $scope"
    exit 1
  fi
done
