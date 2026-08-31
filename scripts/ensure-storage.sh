#!/bin/bash
#
# ensure-storage.sh — resource group, storage account and container for a
# tenant's FOCUS exports. Creates only what is missing. Prints the blob
# endpoint on stdout; all progress goes to stderr.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RG=""; STORAGE=""; CONTAINER=""; LOCATION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --resource-group)  RG="$2"; shift 2 ;;
    --storage-account) STORAGE="$2"; shift 2 ;;
    --container)       CONTAINER="$2"; shift 2 ;;
    --location)        LOCATION="$2"; shift 2 ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$RG" ] && [ -n "$STORAGE" ] && [ -n "$CONTAINER" ] || {
  log_err "--resource-group, --storage-account and --container are required"; exit 2; }

if az group show --name "$RG" >/dev/null 2>&1; then
  log_info "resource group '$RG' exists"
  RG_LOCATION="$(az group show --name "$RG" --query location -o tsv)"
else
  [ -n "$LOCATION" ] || { log_err "resource group '$RG' does not exist and --location was not given"; exit 1; }
  log_info "creating resource group '$RG' in $LOCATION"
  az group create --name "$RG" --location "$LOCATION" --only-show-errors >/dev/null
  RG_LOCATION="$LOCATION"
fi

if az storage account show --name "$STORAGE" --resource-group "$RG" >/dev/null 2>&1; then
  log_info "storage account '$STORAGE' exists"
else
  log_info "creating storage account '$STORAGE' in ${LOCATION:-$RG_LOCATION}"
  az storage account create --name "$STORAGE" --resource-group "$RG" \
    --location "${LOCATION:-$RG_LOCATION}" \
    --sku Standard_LRS --kind StorageV2 --access-tier Hot \
    --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false \
    --only-show-errors >/dev/null
fi

# AAD auth first; fall back to account key, which only needs listKeys. Control
# plane Owner does not confer blob data access, so a freshly created account
# usually needs the key path here.
log_info "ensuring container '$CONTAINER'"
az storage container create --account-name "$STORAGE" --name "$CONTAINER" \
    --auth-mode login --only-show-errors >/dev/null 2>&1 \
  || az storage container create --account-name "$STORAGE" --name "$CONTAINER" \
    --resource-group "$RG" --auth-mode key --only-show-errors >/dev/null 2>&1 \
  || { log_err "could not create container '$CONTAINER' with either AAD or key auth"; exit 1; }

az storage account show --name "$STORAGE" --resource-group "$RG" --query "primaryEndpoints.blob" -o tsv
