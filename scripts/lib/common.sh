#!/bin/bash
# Shared helpers. Sourced by every script; defines no side effects on import.

log_info() { echo "==> $*" >&2; }
log_warn() { echo "    WARNING: $*" >&2; }
log_err()  { echo "ERROR: $*" >&2; }

# cfg_get FILE KEY — read one value without executing the file. Last
# assignment wins; surrounding quotes and trailing whitespace are stripped.
cfg_get() {
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2=//p" "$1" | tail -1 \
    | sed 's/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/; s/[[:space:]]*$//'
}

# resolve_cloud — set ARM_ENDPOINT, GRAPH_ENDPOINT, BLOB_SUFFIX, AD_ENDPOINT
# from the active az cloud, falling back to documented literals per cloud.
resolve_cloud() {
  local cloud="${AZURE_CLOUD:-AzureCloud}"
  ARM_ENDPOINT="$(az cloud show --query 'endpoints.resourceManager' -o tsv 2>/dev/null | sed 's:/*$::')"
  GRAPH_ENDPOINT="$(az cloud show --query 'endpoints.microsoftGraphResourceId' -o tsv 2>/dev/null | sed 's:/*$::')"
  BLOB_SUFFIX="$(az cloud show --query 'suffixes.storageEndpoint' -o tsv 2>/dev/null)"
  AD_ENDPOINT="$(az cloud show --query 'endpoints.activeDirectory' -o tsv 2>/dev/null | sed 's:/*$::')"
  if [ "$cloud" = "AzureUSGovernment" ]; then
    : "${ARM_ENDPOINT:=https://management.usgovcloudapi.net}"
    : "${GRAPH_ENDPOINT:=https://graph.microsoft.us}"
    : "${BLOB_SUFFIX:=core.usgovcloudapi.net}"
    : "${AD_ENDPOINT:=https://login.microsoftonline.us}"
  else
    : "${ARM_ENDPOINT:=https://management.azure.com}"
    : "${GRAPH_ENDPOINT:=https://graph.microsoft.com}"
    : "${BLOB_SUFFIX:=core.windows.net}"
    : "${AD_ENDPOINT:=https://login.microsoftonline.com}"
  fi
  export ARM_ENDPOINT GRAPH_ENDPOINT BLOB_SUFFIX AD_ENDPOINT
}

# kion_account_type MODEL CLOUD — Kion account type id.
kion_account_type() {
  case "$1:$2" in
    MCA:AzureUSGovernment) echo 18 ;;
    MCA:*)                 echo 16 ;;
    CSP:AzureUSGovernment) echo 11 ;;
    CSP:*)                 echo 3  ;;
    *) log_err "unknown billing model '$1'"; return 1 ;;
  esac
}

# Summary rows accumulate in a temp file so subshells can append to them.
summary_reset() { SUMMARY_FILE="${SUMMARY_FILE:-$(mktemp)}"; : > "$SUMMARY_FILE"; export SUMMARY_FILE; }
summary_add()   { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SUMMARY_FILE"; }
summary_print() {
  echo ""
  printf '%-24s %-8s %s\n' "TENANT" "STATUS" "DETAIL"
  printf '%-24s %-8s %s\n' "------" "------" "------"
  while IFS=$'\t' read -r t s d; do printf '%-24s %-8s %s\n' "$t" "$s" "$d"; done < "$SUMMARY_FILE"
}
summary_exit_code() { grep -q $'\tfailed\t' "$SUMMARY_FILE" && echo 1 || echo 0; }
