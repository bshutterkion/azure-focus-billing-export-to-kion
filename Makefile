.PHONY: help onboard onboard-all exports kion-source status test

TENANTS_DIR ?= tenants
TENANT ?=
TENANT_FILE ?= $(if $(strip $(TENANT)),$(TENANTS_DIR)/$(TENANT).env,)

-include .env
export

# Shared TENANT=<name> presence check for onboard, exports and kion-source.
# Factored here rather than pasted three times.
define require_tenant
	@[ -n "$(strip $(TENANT))" ] || { echo "ERROR: TENANT=<name> is required"; exit 2; }
endef

help: ## Show available targets
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | sort

onboard: ## Onboard one tenant end to end: make onboard TENANT=<name>
	$(require_tenant)
	scripts/onboard-tenant.sh --tenant-file "$(TENANT_FILE)"

onboard-all: ## Onboard every tenant in tenants/, continuing past failures
	scripts/onboard-all.sh --dir "$(TENANTS_DIR)"

exports: ## Re-run only the FOCUS export creation for one tenant: make exports TENANT=<name>
	$(require_tenant)
	scripts/onboard-tenant.sh --tenant-file "$(TENANT_FILE)" --only exports

kion-source: ## Re-run only the Kion billing-source registration for one tenant: make kion-source TENANT=<name>
	$(require_tenant)
	scripts/onboard-tenant.sh --tenant-file "$(TENANT_FILE)" --only kion-source

status: ## Print each tenant's cloud, billing model and KION_PAYER_ID state. Read-only; makes no Azure or Kion calls.
	@found=0; \
	for f in $(TENANTS_DIR)/*.env; do \
	  [ -f "$$f" ] || continue; \
	  case "$$f" in *.example) continue ;; esac; \
	  found=1; \
	  name=$$(basename "$$f" .env); \
	  cloud=$$(sed -n 's/^[[:space:]]*AZURE_CLOUD=//p' "$$f" | tail -1); \
	  model=$$(sed -n 's/^[[:space:]]*BILLING_MODEL=//p' "$$f" | tail -1); \
	  payer=$$(sed -n 's/^[[:space:]]*KION_PAYER_ID=//p' "$$f" | tail -1); \
	  if [ -n "$$payer" ]; then payer_status="set ($$payer)"; else payer_status="unset"; fi; \
	  printf '%-24s cloud=%-20s model=%-6s KION_PAYER_ID=%s\n' \
	    "$$name" "$${cloud:-?}" "$${model:-?}" "$$payer_status"; \
	done; \
	[ "$$found" -eq 1 ] || echo "no tenant files in $(TENANTS_DIR)"

test: ## Run the test suite
	bash tests/run-tests.sh
