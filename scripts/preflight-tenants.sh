#!/bin/bash
#
# preflight-tenants.sh — survey a list of tenants BEFORE onboarding any of
# them, and report per tenant what a run would need and whether it would get
# it. Read-only: it creates nothing, changes nothing, and never calls Kion.
#
# Why this exists. Onboarding is idempotent and continues past failures, so a
# bad tenant does not strand the rest -- but every tenant still costs an
# interactive sign-in, and the two things that most often block a first run
# (no Owner/User Access Administrator at the management group, and a billing
# scope the signed-in identity cannot see) are only discoverable *inside* the
# tenant. Discovering them one at a time, many sign-ins deep into a rollout,
# is the failure mode this script exists to prevent. It also emits the two values
# a tenant file cannot be written without -- BILLING_SCOPE_ID and the
# EXPORT_SCOPE that matches it -- so the survey doubles as the input to
# generating the tenant files.
#
# stdout is a data channel: one tab-separated row per tenant, a header first,
# and nothing else. Progress and diagnostics go to stderr. Pipe it to a file
# and read it with `column -t`, or feed it to whatever writes tenants/*.env.
#
# Usage:
#   ./preflight-tenants.sh --tenants-file <file>   # name,tenant-id per line
#   ./preflight-tenants.sh --dir tenants           # existing tenants/*.env
#   ./preflight-tenants.sh --tenant-id <id> [--no-login]
#
# --tenants-file accepts "name,tenant-id" or a bare tenant id (the id then
# doubles as the name). Blank lines and #-comments are skipped.
#
# --no-login surveys only the tenant the CLI is already pointed at. Like
# onboard-tenant.sh's --skip-login it skips the sign-in, not the verification:
# a tenant whose id does not match the active session is reported as such
# rather than surveyed against the wrong directory.
#
# Columns:
#   NAME              the tenant file this row would become
#   TENANT_ID
#   CLOUD             the CLI's *active* cloud while this row was gathered
#   SUBS              subscriptions visible in this tenant
#   MG_ROLE           the role held at the tenant root management group
#   BILLING_ACCOUNT   MCA/EA billing account the tenant's subscriptions bill to
#   BILLING_PROFILE   the single profile they all bill to, when there is one
#   EXPORT_SCOPE      the scope a tenant file should declare
#   VERDICT           ready | blocked | check
#   NOTE              why, when the verdict is not `ready`
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TENANTS_FILE=""; DIR=""; ONE_TENANT=""; NO_LOGIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tenants-file) TENANTS_FILE="$2"; shift 2 ;;
    --dir)          DIR="$2"; shift 2 ;;
    --tenant-id)    ONE_TENANT="$2"; shift 2 ;;
    --no-login)     NO_LOGIN=1; shift ;;
    -h|--help)      sed -n '3,45p' "$0" >&2; exit 0 ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done

sources=0
[ -n "$TENANTS_FILE" ] && sources=$((sources+1))
[ -n "$DIR" ] && sources=$((sources+1))
[ -n "$ONE_TENANT" ] && sources=$((sources+1))
if [ "$sources" -ne 1 ]; then
  log_err "give exactly one of --tenants-file, --dir or --tenant-id"
  exit 2
fi
if [ -n "$TENANTS_FILE" ] && [ ! -f "$TENANTS_FILE" ]; then
  log_err "no such file: $TENANTS_FILE"
  exit 2
fi
if [ -n "$DIR" ] && [ ! -d "$DIR" ]; then
  log_err "no such directory: $DIR"
  exit 2
fi

# Build the work list as "name<TAB>tenant-id" lines in a temp file rather than
# an array: this targets bash 3.2, which has no mapfile and no associative
# arrays, and a temp file also survives the subshell a `while read` loop would
# otherwise trap the results in.
WORK="$(mktemp)"
trap 'rm -f "$WORK"' EXIT

if [ -n "$ONE_TENANT" ]; then
  printf '%s\t%s\n' "$ONE_TENANT" "$ONE_TENANT" >> "$WORK"
elif [ -n "$TENANTS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Strip CRs: a tenant list exported from a spreadsheet on Windows would
    # otherwise carry \r into the tenant id, and every az call against it
    # fails with a message that does not mention the real cause.
    line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    case "$line" in
      *,*) name="${line%%,*}"; tid="${line#*,}" ;;
      *)   name="$line";       tid="$line" ;;
    esac
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    tid="$(printf '%s' "$tid" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$tid" ] || { log_warn "skipping line with no tenant id: $line"; continue; }
    printf '%s\t%s\n' "$name" "$tid" >> "$WORK"
  done < "$TENANTS_FILE"
else
  for f in "$DIR"/*.env; do
    [ -f "$f" ] || continue
    case "$f" in *.example) continue ;; esac
    tid="$(cfg_get "$f" TENANT_ID)"
    name="$(basename "$f" .env)"
    if [ -z "$tid" ]; then
      log_warn "$name: TENANT_ID is empty in $f; skipping"
      continue
    fi
    printf '%s\t%s\n' "$name" "$tid" >> "$WORK"
  done
fi

if [ ! -s "$WORK" ]; then
  log_err "no tenants to survey"
  exit 1
fi

# az calls below are individually tolerant of failure, which looks like it
# contradicts this project's "fail loudly" rule -- it does not. Nothing here
# feeds a create call; the output IS the report, so a tenant whose billing
# scope cannot be read must still produce a row saying exactly that. The
# loudness lives in the VERDICT/NOTE columns and the stderr warnings, and a
# survey that aborted on tenant 7 of 44 would defeat the point. Every
# unreadable value becomes an explicit marker, never a silent empty string.
UNKNOWN="unknown"
NONE="-"

emit() { # 10 fields, tab separated, in header order
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
}

emit NAME TENANT_ID CLOUD SUBS MG_ROLE BILLING_ACCOUNT BILLING_PROFILE \
  EXPORT_SCOPE VERDICT NOTE

ready=0; blocked=0; check=0
while IFS=$'\t' read -r name tid; do
  log_info "=== $name ($tid) ==="

  active="$(az account show --query tenantId -o tsv 2>/dev/null || echo "")"
  if [ "$active" != "$tid" ]; then
    if [ "$NO_LOGIN" -eq 1 ]; then
      # --no-login means "survey the session I already have". Surveying a
      # different tenant's directory under this tenant's name would produce a
      # confidently wrong row, so refuse this one and keep going.
      log_warn "$name: active tenant '$active' is not $tid; skipping (--no-login)"
      emit "$name" "$tid" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN" \
        "$UNKNOWN" blocked "not the active tenant and --no-login was given"
      blocked=$((blocked+1))
      continue
    fi
    log_info "signing in to $tid"
    if ! az login --tenant "$tid" --only-show-errors >/dev/null 2>&1; then
      log_warn "$name: sign-in failed"
      emit "$name" "$tid" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN" \
        "$UNKNOWN" blocked "sign-in failed"
      blocked=$((blocked+1))
      continue
    fi
    active="$(az account show --query tenantId -o tsv 2>/dev/null || echo "")"
    if [ "$active" != "$tid" ]; then
      log_warn "$name: signed in but active tenant is '$active'"
      emit "$name" "$tid" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN" \
        "$UNKNOWN" blocked "signed in but active tenant is '$active'"
      blocked=$((blocked+1))
      continue
    fi
  fi

  # Report the active cloud rather than checking it against anything: this
  # script has no tenant file to compare with, and Gov and Commercial tenants
  # are surveyed from one checkout. A row whose CLOUD is not the cloud that
  # tenant actually lives in was gathered against the wrong endpoints, and
  # showing the value is what makes that visible.
  cloud="$(az account show --query environmentName -o tsv 2>/dev/null || echo "")"
  [ -n "$cloud" ] || cloud="$UNKNOWN"

  # Subscriptions in THIS tenant only. `az account list` returns everything in
  # the CLI profile, which after several sign-ins holds earlier tenants'
  # subscriptions too, so the tenantId filter is what keeps the count honest.
  subs="$(az account list --query "[?tenantId=='$tid'].id" -o tsv 2>/dev/null | tr '\n' ' ' \
    | sed 's/[[:space:]]*$//')"
  sub_count=0
  for s in $subs; do sub_count=$((sub_count+1)); done

  # ---- role at the tenant root management group ----
  # The root management group's id IS the tenant id, which is also what
  # create-kion-app.sh falls back to when MANAGEMENT_GROUP is empty. So this
  # checks precisely the scope a default onboarding run would grant Owner at.
  mg_role="$NONE"
  oid="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")"
  if [ -z "$oid" ]; then
    # A service principal has no "signed-in user"; fall back to the id the CLI
    # reports for the session. Reported as unknown when neither resolves,
    # because "no role found" and "could not identify who I am" must not look
    # the same to whoever reads this report.
    oid="$(az account show --query user.name -o tsv 2>/dev/null || echo "")"
  fi
  if [ -z "$oid" ]; then
    mg_role="$UNKNOWN"
  else
    roles="$(az role assignment list \
      --scope "/providers/Microsoft.Management/managementGroups/$tid" \
      --assignee "$oid" --include-inherited \
      --query "[].roleDefinitionName" -o tsv 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$roles" ]; then
      mg_role="$roles"
    fi
  fi

  # ---- billing account and profile the tenant's subscriptions bill to ----
  # Derived from the subscriptions rather than from `az billing account list`
  # alone, because the question a tenant file needs answered is not "what
  # billing accounts can I see" but "which scope covers exactly this tenant".
  # One MCA billing account can span many tenants: a billingAccount-scoped
  # export there carries every tenant's costs, so 44 tenants each given
  # billingAccount scope would register 44 Kion billing sources all ingesting
  # the same full account -- the same class of silently-multiplied cost data
  # the subscription-scope guard in create-focus-exports.sh exists to stop.
  # Mapping subscriptions to their billing profile is what distinguishes
  # "one account per tenant" (billingAccount is right) from "one shared
  # account" (billingProfile is right) from "profiles span tenants" (no
  # per-tenant scope exists at all, and a human has to decide).
  acct="$NONE"; profile="$NONE"; scope="$UNKNOWN"; note=""
  accounts="$(az billing account list --query "[].name" -o tsv 2>/dev/null | tr '\n' ' ' \
    | sed 's/[[:space:]]*$//')"
  acct_count=0
  for a in $accounts; do acct_count=$((acct_count+1)); done

  if [ "$acct_count" -eq 0 ]; then
    acct="$UNKNOWN"
    note="no billing account visible; needs an MCA/EA billing role on the scope"
  else
    # Collect the distinct billing profiles this tenant's subscriptions belong
    # to, across every visible account. One `billing subscription list` per
    # account, matched locally: bash 3.2 has no associative arrays, and one
    # call per subscription would be 44x worse over a rollout.
    seen_profiles=""; seen_accounts=""
    for a in $accounts; do
      map="$(az billing subscription list --account-name "$a" \
        --query "[].[subscriptionId,billingProfileId]" -o tsv 2>/dev/null || echo "")"
      [ -n "$map" ] || continue
      for s in $subs; do
        row="$(printf '%s\n' "$map" | grep -F "$s" | head -1)"
        [ -n "$row" ] || continue
        p="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
        [ -n "$p" ] || continue
        case ",$seen_profiles," in *",$p,"*) ;; *) seen_profiles="${seen_profiles:+$seen_profiles,}$p" ;; esac
        case ",$seen_accounts," in *",$a,"*) ;; *) seen_accounts="${seen_accounts:+$seen_accounts,}$a" ;; esac
      done
    done

    prof_count=0
    old_ifs="$IFS"; IFS=','
    for p in $seen_profiles; do [ -n "$p" ] && prof_count=$((prof_count+1)); done
    IFS="$old_ifs"

    if [ -n "$seen_accounts" ]; then
      acct="$seen_accounts"
    else
      acct="$accounts"
      note="billing account visible but no subscription mapped to it"
    fi

    if [ "$prof_count" -eq 1 ]; then
      profile="$seen_profiles"
    elif [ "$prof_count" -gt 1 ]; then
      profile="$seen_profiles"
      note="subscriptions span $prof_count billing profiles; no single per-tenant export scope exists"
    fi
  fi

  # ---- the scope a tenant file should declare ----
  # Prefer the narrower billingProfile scope whenever a single profile covers
  # this tenant, and fall back to billingAccount only when the profiles cannot
  # be read at all. That asymmetry is deliberate: signed in to one tenant it is
  # impossible to see whether some *other* tenant also bills to this account,
  # so billingAccount can never be confirmed safe from here, while a profile
  # that covers exactly this tenant's subscriptions is never broader than the
  # tenant. When neither is determinable, say so rather than guess -- a wrong
  # EXPORT_SCOPE here is a wrong number in Kion later, with no error anywhere.
  if [ "$acct" != "$UNKNOWN" ] && [ "$acct" != "$NONE" ]; then
    case "$acct" in
      *,*) scope="$UNKNOWN" ;;   # more than one account for one tenant: a human decides
      *)
        if [ "$profile" != "$NONE" ] && [ "$profile" != "$UNKNOWN" ]; then
          case "$profile" in
            *,*) scope="$UNKNOWN" ;;
            *)   scope="billingProfile" ;;
          esac
        else
          scope="billingAccount"
        fi
        ;;
    esac
  fi

  # ---- verdict ----
  # `blocked` means a run would fail; `check` means it would probably succeed
  # but produce something a human should look at first. Only the absence of
  # both makes a tenant ready, and the two are deliberately distinct: a
  # rollout can start on the ready ones while the check rows get answered.
  verdict="ready"
  case "$mg_role" in
    *Owner*|*"User Access Administrator"*) ;;
    "$UNKNOWN")
      verdict="check"
      note="${note:+$note; }could not resolve the signed-in identity to check the management group role"
      ;;
    *)
      verdict="blocked"
      note="${note:+$note; }no Owner or User Access Administrator at the tenant root management group"
      ;;
  esac
  if [ "$acct" = "$UNKNOWN" ]; then
    verdict="blocked"
  elif [ "$scope" = "$UNKNOWN" ] && [ "$verdict" = "ready" ]; then
    verdict="check"
    note="${note:+$note; }could not determine a single export scope for this tenant"
  fi
  if [ "$sub_count" -eq 0 ]; then
    verdict="blocked"
    note="${note:+$note; }no subscriptions visible in this tenant"
  fi

  case "$verdict" in
    ready)   ready=$((ready+1)) ;;
    blocked) blocked=$((blocked+1)) ;;
    *)       check=$((check+1)) ;;
  esac

  emit "$name" "$tid" "$cloud" "$sub_count" "$mg_role" "$acct" "$profile" \
    "$scope" "$verdict" "${note:-$NONE}"
done < "$WORK"

echo >&2
log_info "surveyed: $ready ready, $check need a look, $blocked blocked"
if [ "$blocked" -gt 0 ]; then
  log_info "fix the blocked tenants before running 'make onboard-all'"
fi
# Exit 0 even with blocked tenants: the survey succeeded: reporting a blocker
# is this script doing its job, not failing at it. A caller that wants to gate
# on the result reads the VERDICT column.
exit 0
