#!/bin/bash
#
# create-kion-app.sh
#
# Creates (or extends) the Azure AD app registration Kion uses to MANAGE a
# customer tenant and READ that tenant's FOCUS billing data. Run by the
# customer, authenticated to THEIR OWN tenant.
#
# This is the identity that goes on the tenant's Kion billing source.
# Kion uses that single app for three jobs, so it needs all three sets of
# rights:
#
#   1. Resource management (azure-sync: policy sets, role assignments, resource
#      groups)          -> "Owner" on a management group
#   2. User / group linkage
#                       -> Microsoft Graph application + delegated permissions
#   3. Billing           -> "Storage Blob Data Reader" on the FOCUS container
#
# Optionally also grants the rights Kion needs to CREATE subscriptions and
# resource groups (--enable-subscription-creation), which adds a custom role
# carrying roleAssignments write/delete + subscriptions/write at the root
# management group.
#
# Prerequisites:
#   - Azure CLI (az) logged in to THIS (customer) tenant.
#     For US Gov: az cloud set --name AzureUSGovernment first, then az login.
#   - The signed-in identity must hold:
#       * "Application Administrator" / "Cloud Application Administrator"
#         (to create the app and grant admin consent -- consent may require
#         "Privileged Role Administrator" or "Global Administrator"), AND
#       * "Owner" or "User Access Administrator" on the management group /
#         subscription being granted.
#
# Output:
#   Progress and diagnostics go to stderr. On success, stdout carries exactly:
#     APP_ID=<app id>
#     TENANT_DOMAIN=<initial domain>
#     CREDENTIAL_FILE=<absolute path to the written credential file>
#
# Usage:
#   ./create-kion-app.sh [--app-id <existing-app-id>] \
#       [--resource-group <rg> --storage-account <sa> --container <name>] \
#       [--management-group <id>] [--kion-url https://kion.example.com]
#
# Optional flags:
#   --app-id <id>            Extend an EXISTING registration (e.g. the one already
#                            used for SAML with Kion) instead of creating one.
#                            Existing redirect URIs and secrets are preserved.
#   --app-name <name>        Display name when creating (default: "Kion App Registration")
#   --secret-years <n>       Client secret lifetime in years (default: 1)
#   --kion-url <url>         Kion base URL; adds the account-linking redirect URI
#                            <url>/api/v3/account/link-azure-callback
#   --management-group <id>  Management group to grant Owner on
#                            (default: the tenant root group, whose id is the tenant id)
#   --resource-group <rg>    Resource group holding the FOCUS storage account
#   --storage-account <sa>   FOCUS storage account
#   --container <name>       FOCUS container to grant Storage Blob Data Reader on
#   --prefix <path>          The FOCUS prefix to print in the billing-source summary,
#                            verbatim as Kion must receive it. There is deliberately
#                            no default: only create-focus-exports.sh knows the
#                            rootFolderPath AND the export name Azure inserts below
#                            it, and a guessed prefix (the bare rootFolderPath)
#                            points Kion at a path that holds no blobs at all.
#                            Omitted, the summary simply prints no prefix line.
#   --enable-subscription-creation
#                            Also create/assign the "Minimal subscription move"
#                            custom role so Kion can create subscriptions + RGs
#   --rotation-perms         Add Application.Read.All + Application.ReadWrite.OwnedBy
#                            and make the SP an owner of its own app, so Kion can
#                            rotate the client secret automatically
#   --no-graph               Skip the Microsoft Graph permissions entirely
#   --no-consent             Add Graph permissions but do not attempt admin consent

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

APP_ID=""
APP_NAME="Kion App Registration"
SECRET_YEARS=1
KION_URL=""
MANAGEMENT_GROUP=""
RG=""
STORAGE=""
CONTAINER=""
EXPORT_PREFIX=""
ENABLE_SUB_CREATION=0
ROTATION_PERMS=0
DO_GRAPH=1
DO_CONSENT=1

usage() { sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//; /^set -e/d'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id)             APP_ID="$2"; shift 2 ;;
    --app-name)           APP_NAME="$2"; shift 2 ;;
    --secret-years)       SECRET_YEARS="$2"; shift 2 ;;
    --kion-url)           KION_URL="$2"; shift 2 ;;
    --management-group)   MANAGEMENT_GROUP="$2"; shift 2 ;;
    --resource-group)     RG="$2"; shift 2 ;;
    --storage-account)    STORAGE="$2"; shift 2 ;;
    --container)          CONTAINER="$2"; shift 2 ;;
    --prefix)             EXPORT_PREFIX="$2"; shift 2 ;;
    --enable-subscription-creation) ENABLE_SUB_CREATION=1; shift ;;
    --rotation-perms)     ROTATION_PERMS=1; shift ;;
    --no-graph)           DO_GRAPH=0; shift ;;
    --no-consent)         DO_CONSENT=0; shift ;;
    -h|--help)            usage 0 ;;
    *) log_err "unknown argument: $1"; usage 2 ;;
  esac
done

command -v az >/dev/null 2>&1 || { log_err "az CLI not found in PATH"; exit 1; }
command -v jq >/dev/null 2>&1 || { log_err "jq not found in PATH"; exit 1; }

resolve_cloud

TENANT_ID=$(az account show --query tenantId -o tsv)
SUB_ID=$(az account show --query id -o tsv)
# The tenant root management group always carries the tenant id as its name.
[[ -z "$MANAGEMENT_GROUP" ]] && MANAGEMENT_GROUP="$TENANT_ID"

log_info "Customer tenant:   $TENANT_ID"
log_info "Subscription:      $SUB_ID"
log_info "Management group:  $MANAGEMENT_GROUP"
[[ -n "$STORAGE" ]] && log_info "FOCUS storage:     $STORAGE / $CONTAINER (rg $RG)"
echo >&2

# ---------- 1) create or reuse the app registration ----------
if [[ -n "$APP_ID" ]]; then
  az ad app show --id "$APP_ID" >/dev/null 2>&1 || {
    log_err "app registration '$APP_ID' not found in this tenant."; exit 1; }
  APP_NAME=$(az ad app show --id "$APP_ID" --query displayName -o tsv)
  log_info "Extending existing app registration: $APP_NAME ($APP_ID)"
  echo "    Existing redirect URIs and client secrets are preserved." >&2
else
  EXISTING=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")
  if [[ -n "$EXISTING" ]]; then
    APP_ID="$EXISTING"
    log_info "App registration already exists, reusing: $APP_ID"
  else
    log_info "Creating app registration '$APP_NAME' (single tenant)..."
    APP_ID=$(az ad app create --display-name "$APP_NAME" \
      --sign-in-audience AzureADMyOrg --query appId -o tsv)
    echo "    App ID: $APP_ID" >&2
  fi
fi

# ---------- 2) ensure the service principal ----------
SP_OID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv 2>/dev/null || echo "")
if [[ -z "$SP_OID" ]]; then
  log_info "Creating service principal..."
  SP_OID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
else
  log_info "Service principal already exists."
fi
echo "    SP object id: $SP_OID" >&2

# ---------- 3) account-linking redirect URI ----------
# Read-modify-write: replacing the list outright would drop the SAML reply URLs
# on an existing registration and break sign-in.
if [[ -n "$KION_URL" ]]; then
  REDIRECT="${KION_URL%/}/api/v3/account/link-azure-callback"
  # Portable read of the current URIs: mapfile is bash 4+, and macOS ships 3.2.
  CUR_URIS=()
  while IFS= read -r _u; do
    [ -n "$_u" ] && CUR_URIS+=("$_u")
  done < <(az ad app show --id "$APP_ID" --query "web.redirectUris[]" -o tsv 2>/dev/null || true)

  _already=0
  for _u in ${CUR_URIS[@]+"${CUR_URIS[@]}"}; do
    [ "$_u" = "$REDIRECT" ] && _already=1
  done

  if [ "$_already" -eq 1 ]; then
    log_info "Redirect URI already present."
  elif [ "${#CUR_URIS[@]}" -gt 0 ]; then
    log_info "Adding redirect URI (keeping ${#CUR_URIS[@]} existing)"
    az ad app update --id "$APP_ID" --web-redirect-uris "${CUR_URIS[@]}" "$REDIRECT" --only-show-errors
  else
    log_info "Adding redirect URI $REDIRECT"
    az ad app update --id "$APP_ID" --web-redirect-uris "$REDIRECT" --only-show-errors
  fi
fi

# ---------- 4) client secret ----------
# --append: never invalidate secrets an existing registration is already using.
log_info "Generating a client secret (${SECRET_YEARS}y, appended)..."
CLIENT_SECRET=$(az ad app credential reset --id "$APP_ID" --append \
  --years "$SECRET_YEARS" --display-name "Kion Application" -o json | jq -r '.password')

# ---------- 5) Microsoft Graph permissions ----------
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
if [[ "$DO_GRAPH" -eq 1 ]]; then
  log_info "Adding Microsoft Graph permissions..."
  GRAPH_SP=$(az ad sp show --id "$GRAPH_APP_ID" -o json)
  add_perm() { # name, Role|Scope
    local name="$1" kind="$2" id
    if [[ "$kind" == "Role" ]]; then
      id=$(echo "$GRAPH_SP" | jq -r --arg v "$name" '.appRoles[]? | select(.value==$v) | .id' | head -1)
    else
      id=$(echo "$GRAPH_SP" | jq -r --arg v "$name" '.oauth2PermissionScopes[]? | select(.value==$v) | .id' | head -1)
    fi
    [[ -n "$id" ]] || { log_warn "could not resolve Graph permission $name ($kind)"; return 0; }
    az ad app permission add --id "$APP_ID" --api "$GRAPH_APP_ID" \
      --api-permissions "${id}=${kind}" --only-show-errors >/dev/null 2>&1 || true
    echo "    + $name ($kind)" >&2
  }
  add_perm User.Read            Scope
  add_perm Directory.Read.All   Scope
  add_perm User.Read.All        Role
  add_perm Group.Read.All       Role
  if [[ "$ROTATION_PERMS" -eq 1 ]]; then
    add_perm Application.Read.All          Role
    add_perm Application.ReadWrite.OwnedBy Role
    # Kion can only rotate a secret on an app it owns.
    az ad app owner add --id "$APP_ID" --owner-object-id "$SP_OID" --only-show-errors >/dev/null 2>&1 \
      || echo "    (could not add the SP as an owner of its own app)" >&2
  fi

  if [[ "$DO_CONSENT" -eq 1 ]]; then
    log_info "Granting admin consent..."
    if ! az ad app permission admin-consent --id "$APP_ID" --only-show-errors 2>/dev/null; then
      log_warn "admin consent failed. Application permissions do NOT work"
      echo "             until consented. A Global Administrator / Privileged Role" >&2
      echo "             Administrator must run:" >&2
      echo "               az ad app permission admin-consent --id $APP_ID" >&2
    fi
  fi
fi

# ---------- 6) Owner on the management group ----------
MG_SCOPE="/providers/Microsoft.Management/managementGroups/${MANAGEMENT_GROUP}"
log_info "Granting Owner on $MG_SCOPE ..."
if ! ra_err=$(az role assignment create --assignee-object-id "$SP_OID" \
      --assignee-principal-type ServicePrincipal --role "Owner" \
      --scope "$MG_SCOPE" --only-show-errors 2>&1); then
  if printf '%s' "$ra_err" | grep -qiE 'already exist|RoleAssignmentExists'; then
    echo "    (already assigned)" >&2
  else
    printf '%s\n' "$ra_err" >&2
    log_err "could not grant Owner on the management group. Kion cannot manage"
    echo "       this tenant's subscriptions without it. Confirm the management" >&2
    echo "       group id and that you hold Owner / User Access Administrator." >&2
    exit 1
  fi
fi

# ---------- 7) subscription + resource group creation (optional) ----------
if [[ "$ENABLE_SUB_CREATION" -eq 1 ]]; then
  ROLE_NAME="Minimal subscription move"
  log_info "Enabling subscription/resource-group creation ('$ROLE_NAME')..."
  if [[ -z "$(az role definition list --name "$ROLE_NAME" --scope "$MG_SCOPE" --query "[0].roleName" -o tsv 2>/dev/null || echo "")" ]]; then
    ROLE_JSON=$(jq -nc --arg n "$ROLE_NAME" --arg s "$MG_SCOPE" \
      '{Name:$n,
        Description:"Allows Kion to move created subscriptions under an owned management group",
        Actions:["Microsoft.Authorization/roleAssignments/write",
                 "Microsoft.Authorization/roleAssignments/delete",
                 "subscriptions/write"],
        AssignableScopes:[$s]}')
    echo "$ROLE_JSON" | az role definition create --role-definition @- --only-show-errors >/dev/null \
      || log_warn "could not create the custom role definition"
  else
    echo "    (custom role already defined)" >&2
  fi
  az role assignment create --assignee-object-id "$SP_OID" \
    --assignee-principal-type ServicePrincipal --role "$ROLE_NAME" \
    --scope "$MG_SCOPE" --only-show-errors >/dev/null 2>&1 \
    || echo "    (role assignment already exists, or the definition is still propagating)" >&2
fi

# ---------- 8) read access to the FOCUS container ----------
if [[ -n "$STORAGE" && -n "$CONTAINER" ]]; then
  log_info "Granting Storage Blob Data Reader on $CONTAINER ..."
  STORAGE_ID=$(az storage account show --name "$STORAGE" --resource-group "$RG" --query id -o tsv)
  az role assignment create --assignee-object-id "$SP_OID" \
    --assignee-principal-type ServicePrincipal --role "Storage Blob Data Reader" \
    --scope "${STORAGE_ID}/blobServices/default/containers/${CONTAINER}" \
    --only-show-errors >/dev/null 2>&1 || echo "    (already assigned)" >&2
  BLOB_ENDPOINT=$(az storage account show --name "$STORAGE" --resource-group "$RG" --query "primaryEndpoints.blob" -o tsv)
else
  BLOB_ENDPOINT=""
fi

# ---------- resolve the tenant domain ----------
TENANT_DOMAIN=$(az rest --method GET --url "${GRAPH_ENDPOINT}/v1.0/domains" 2>/dev/null \
  | jq -r '.value[] | select(.isInitial==true) | .id' 2>/dev/null | head -1 || true)
if [[ -z "$TENANT_DOMAIN" ]]; then
  log_warn "could not resolve the tenant domain from Microsoft Graph. A guessed domain is being used; verify it before using it for a Kion billing source."
  case "$GRAPH_ENDPOINT" in
    *microsoft.us*) TENANT_DOMAIN="${TENANT_ID}.onmicrosoft.us" ;;
    *)              TENANT_DOMAIN="${TENANT_ID}.onmicrosoft.com" ;;
  esac
fi

# ---------- credential file ----------
SECRET_FILE="./kion-app-${APP_ID}-credential.env"
cat > "$SECRET_FILE" <<SECRET
# Kion app registration credential
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ") by create-kion-app.sh
# App: $APP_NAME ($APP_ID) in tenant $TENANT_DOMAIN
AZURE_CLIENT_ID=$APP_ID
AZURE_CLIENT_SECRET=$CLIENT_SECRET
AZURE_TENANT_ID=$TENANT_ID
SECRET
chmod 600 "$SECRET_FILE"
# Report an absolute path: a caller running this script from a different
# working directory (e.g. a controller invoking it via an absolute path)
# would otherwise resolve "./kion-app-...-credential.env" against its own
# cwd instead of the directory this script actually wrote into.
CREDENTIAL_FILE_ABS="$(cd "$(dirname "$SECRET_FILE")" && pwd)/$(basename "$SECRET_FILE")"

echo >&2
log_info "NOTE: role assignments can take ~5-10 minutes to propagate (longer on"
echo "    US Gov) before Kion's credential tests pass." >&2

cat <<EOF >&2

============================================================
  KION BILLING SOURCE (FOCUS reports)
============================================================

Display Name:     $APP_NAME
Domain:           $TENANT_DOMAIN
App (Client) ID:  $APP_ID
Client Secret:    (written to $SECRET_FILE, mode 0600)
Tenant ID:        $TENANT_ID
EOF
if [[ -n "$BLOB_ENDPOINT" ]]; then
  cat <<EOF >&2
FOCUS endpoint:   $BLOB_ENDPOINT
FOCUS container:  $CONTAINER
EOF
  # No --prefix, no prefix line. Printing a plausible-looking default here is
  # worse than printing nothing: this framed block is what an operator copies
  # into the Kion UI, and the bare rootFolderPath (the only value that could be
  # guessed from here) lists zero blobs, because Azure inserts the export name
  # as a folder below it.
  if [[ -n "$EXPORT_PREFIX" ]]; then
    cat <<EOF >&2
FOCUS prefix:     $EXPORT_PREFIX
                  (paste verbatim; it already includes the export-name folder
                   Azure inserts. Azure writes
                   <prefix>/<YYYYMMDD-YYYYMMDD>/<runstamp>/<run-guid>/manifest.json)
EOF
  else
    cat <<EOF >&2
FOCUS prefix:     (not available here -- run without --prefix. Take it verbatim
                  from the KION_PREFIX= line the export step prints.)
EOF
  fi
fi
cat <<EOF >&2

Record the billing source id Kion assigns, and put it in this customer's env
file as KION_PAYER_ID so later runs skip re-creating the source.

============================================================
EOF

echo "APP_ID=$APP_ID"
echo "TENANT_DOMAIN=$TENANT_DOMAIN"
echo "CREDENTIAL_FILE=$CREDENTIAL_FILE_ABS"
