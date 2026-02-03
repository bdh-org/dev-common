# Shared utility targets

.PHONY: list ls claude-install common-update

list ls: ## list all Makefile targets
	@grep '^[^#[:space:]].*:' Makefile

claude-install: ## install Claude Code CLI
	curl -fsSL https://claude.ai/install.sh | bash

common-update: ## update dev-common submodule to latest
	@cd common && git pull origin main && cd .. && \
	git add common && \
	git commit -m "[CC] chore: update dev-common" && \
	echo "Updated dev-common submodule"
