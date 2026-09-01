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

# onboard-tenant.sh reports each step it finishes as a STEP=<name>:<state> line
# on stdout (and at most one free-text STEP_DETAIL= line). Reading them back is
# what lets a row say "billing-source warn" instead of a flat "ok" for a tenant
# that is onboarded but still needs a human in the Kion UI. A step that never
# reported is "-": the run died before reaching it.
step_state() { # FILE NAME
  local v
  v="$(sed -n "s/^STEP=$2://p" "$1" | tail -n1)"
  printf '%s' "${v:--}"
}

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
    summary_add "$name" - - - - skipped "TENANT_ID is empty"
    continue
  fi

  log_info "=== $name ==="
  # onboard-tenant.sh runs as its own process, so it cannot leak variables
  # into the next iteration regardless of how it's invoked here; what keeps
  # one tenant's failure from ending the loop is the `if` below, not a
  # subshell.
  #
  # `| tee` keeps the step lines on screen while capturing them; pipefail (set
  # at the top of this script) is what makes the pipeline still report
  # onboard-tenant.sh's own failure rather than tee's success.
  steps="$(mktemp)"
  if "$ONBOARD_TENANT_BIN" --tenant-file "$f" | tee "$steps"; then
    ok=1
  else
    ok=0
  fi
  st="$(step_state "$steps" storage)"
  ex="$(step_state "$steps" exports)"
  ap="$(step_state "$steps" app)"
  bs="$(step_state "$steps" billing-source)"
  detail="$(sed -n 's/^STEP_DETAIL=//p' "$steps" | tail -n1)"
  rm -f "$steps"

  if [ "$ok" -eq 1 ]; then
    # A tenant whose billing source came back `warn` is onboarded, so the run
    # is not a failure -- but the overall status must not read `ok` either, or
    # the one row an operator actually reads hides the outstanding manual step.
    if [ "$bs" = warn ]; then
      summary_add "$name" "$st" "$ex" "$ap" "$bs" warn "${detail:-needs attention in the Kion UI}"
    else
      summary_add "$name" "$st" "$ex" "$ap" "$bs" ok "${detail:-onboarded}"
    fi
  else
    summary_add "$name" "$st" "$ex" "$ap" "$bs" failed "${detail:-see output above}"
  fi
done

[ "$found" -eq 1 ] || { log_err "no tenant files in $DIR"; exit 2; }
summary_print
exit "$(summary_exit_code)"
