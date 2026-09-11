#!/bin/bash
#
# ensure-storage.sh — resource group, storage account and container for a
# tenant's FOCUS exports. Creates only what is missing. Prints the blob
# endpoint on stdout; all progress goes to stderr.
#
# --subscription <id> pins which subscription everything is created in. Without
# it the CLI's active subscription wins, which after `az login --tenant <id>`
# is whichever one Azure happened to return first.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RG=""; STORAGE=""; CONTAINER=""; LOCATION=""; SUBSCRIPTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --resource-group)  RG="$2"; shift 2 ;;
    --storage-account) STORAGE="$2"; shift 2 ;;
    --container)       CONTAINER="$2"; shift 2 ;;
    --location)        LOCATION="$2"; shift 2 ;;
    --subscription)    SUBSCRIPTION="$2"; shift 2 ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$RG" ] && [ -n "$STORAGE" ] && [ -n "$CONTAINER" ] || {
  log_err "--resource-group, --storage-account and --container are required"; exit 2; }

# Every az call below carries --subscription, not just the create calls.
# Omitted, each one independently resolves against whichever subscription
# `az login` left active, which is a choice nobody made. Flagging only some of
# them would be worse still: the resource group would be read from one
# subscription and the storage account created in another. An empty
# SUBSCRIPTION expands to no argument at all, leaving the CLI's active
# subscription in force -- the behaviour every tenant file predating
# RESOURCE_SUBSCRIPTION_ID relies on.
if az group show --name "$RG" ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"} >/dev/null 2>&1; then
  log_info "resource group '$RG' exists"
  RG_LOCATION="$(az group show --name "$RG" --query location -o tsv ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"})"
else
  [ -n "$LOCATION" ] || { log_err "resource group '$RG' does not exist and --location was not given"; exit 1; }
  log_info "creating resource group '$RG' in $LOCATION"
  az group create --name "$RG" --location "$LOCATION" \
    ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"} --only-show-errors >/dev/null
  RG_LOCATION="$LOCATION"
fi

if az storage account show --name "$STORAGE" --resource-group "$RG" ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"} >/dev/null 2>&1; then
  log_info "storage account '$STORAGE' exists"
else
  log_info "creating storage account '$STORAGE' in ${LOCATION:-$RG_LOCATION}"
  az storage account create --name "$STORAGE" --resource-group "$RG" \
    --location "${LOCATION:-$RG_LOCATION}" \
    --sku Standard_LRS --kind StorageV2 --access-tier Hot \
    --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false \
    ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"} --only-show-errors >/dev/null
fi

# AAD auth first; fall back to account key, which only needs listKeys. Control
# plane Owner does not confer blob data access, so a freshly created account
# usually needs the key path here. Both attempts take --subscription: the key
# fallback is the one that actually creates the container in practice.
log_info "ensuring container '$CONTAINER'"
az storage container create --account-name "$STORAGE" --name "$CONTAINER" \
    --auth-mode login ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"} --only-show-errors >/dev/null 2>&1 \
  || az storage container create --account-name "$STORAGE" --name "$CONTAINER" \
    --resource-group "$RG" --auth-mode key ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"} --only-show-errors >/dev/null 2>&1 \
  || { log_err "could not create container '$CONTAINER' with either AAD or key auth"; exit 1; }

az storage account show --name "$STORAGE" --resource-group "$RG" \
  --query "primaryEndpoints.blob" -o tsv ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"}
