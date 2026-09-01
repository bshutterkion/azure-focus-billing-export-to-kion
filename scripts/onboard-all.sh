#!/bin/bash
#
# onboard-all.sh — run every tenant in tenants/, continuing past failures, and
# print a summary. Exits non-zero if any tenant failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

DIR="$HERE/../tenants"
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
ONBOARD_TENANT_BIN="${ONBOARD_TENANT_BIN:-$HERE/onboard-tenant.sh}"

summary_reset
found=0
for f in "$DIR"/*.env; do
  [ -f "$f" ] || continue
  # example.env.example never matches *.env, but keep this guard for the day
  # someone copies the template to tenants/example.env.
  case "$f" in *.example) continue ;; esac
  found=1
  name="$(basename "$f" .env)"

  tenant_id="$(cfg_get "$f" TENANT_ID)"
  if [ -z "$tenant_id" ]; then
    log_info "=== $name === skipped: TENANT_ID is empty in $f"
    summary_add "$name" skipped "TENANT_ID is empty"
    continue
  fi

  log_info "=== $name ==="
  # onboard-tenant.sh runs as its own process, so it cannot leak variables
  # into the next iteration regardless of how it's invoked here; what keeps
  # one tenant's failure from ending the loop is the `if` below, not a
  # subshell.
  if "$ONBOARD_TENANT_BIN" --tenant-file "$f"; then
    summary_add "$name" ok "onboarded"
  else
    summary_add "$name" failed "see output above"
  fi
done

[ "$found" -eq 1 ] || { log_err "no tenant files in $DIR"; exit 2; }
summary_print
exit "$(summary_exit_code)"
