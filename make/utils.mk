# Shared utility targets

.PHONY: help list ls claude-install common-update

help: ## Show available targets with descriptions
	@grep -hE '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

list ls: ## list all Makefile targets (including shared targets)
	@grep -h '^[^#[:space:]].*:' Makefile common/make/*.mk make/*.mk 2>/dev/null | grep -v '^\.PHONY' | sort -u

claude-install: ## install Claude Code CLI
	curl -fsSL https://claude.ai/install.sh | bash

common-update: ## update dev-common submodule to latest
	@cd common && git pull origin main && cd .. && \
	git add common && \
	(git diff --cached --quiet common || git commit -m "[CC] chore: update dev-common") && \
	echo "dev-common is up to date"
