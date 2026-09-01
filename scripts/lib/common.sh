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
#
# One tab-separated row per tenant, in the design spec's column order:
#
#   tenant  storage  exports  app  billing-source  status  [detail]
#
# Each per-step cell is one of: ok, warn, failed, skipped, or "-" when the run
# never got that far. A three-column (tenant, status, detail) summary is what
# let a run that deliberately did NOT update Kion's FOCUS prefix report a bare
# "ok"; per-step cells make that visible as a `warn` in the billing-source
# column without downgrading the run to a failure.
#
# `detail` is a seventh column, beyond the spec's six: a `warn` cell is useless
# to an operator without naming the payer id that needs its prefix set by hand,
# and the spec has no column for that text.
summary_reset() { SUMMARY_FILE="${SUMMARY_FILE:-$(mktemp)}"; : > "$SUMMARY_FILE"; export SUMMARY_FILE; }
summary_add() {
  # Fail loudly rather than writing a misaligned row: a caller still passing
  # the old three arguments would otherwise land its status text in the
  # `exports` column and leave `status` empty, which summary_exit_code reads.
  [ $# -ge 6 ] || { log_err "summary_add needs 6 or 7 fields (tenant storage exports app billing-source status [detail]), got $#"; return 2; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}" >> "$SUMMARY_FILE"
}
SUMMARY_FMT='%-20s %-8s %-8s %-8s %-14s %-7s %s\n'
summary_print() {
  echo ""
  # shellcheck disable=SC2059  # SUMMARY_FMT is this file's own literal format
  printf "$SUMMARY_FMT" "TENANT" "STORAGE" "EXPORTS" "APP" "BILLING SOURCE" "STATUS" "DETAIL"
  # shellcheck disable=SC2059
  printf "$SUMMARY_FMT" "------" "-------" "-------" "---" "--------------" "------" "------"
  while IFS=$'\t' read -r t st ex ap bs stat d; do
    # shellcheck disable=SC2059
    printf "$SUMMARY_FMT" "$t" "$st" "$ex" "$ap" "$bs" "$stat" "$d"
  done < "$SUMMARY_FILE"
}
# Only the status column decides the exit code. A `warn` anywhere is
# deliberately exit 0: the tenant is onboarded, something needs a human.
summary_exit_code() { awk -F'\t' '$6 == "failed" { f = 1 } END { print (f ? 1 : 0) }' "$SUMMARY_FILE"; }
