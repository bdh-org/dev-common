# Shared utility targets

.PHONY: list ls claude-install

list ls: ## list all Makefile targets
	@grep '^[^#[:space:]].*:' Makefile

claude-install: ## install Claude Code CLI
	curl -fsSL https://claude.ai/install.sh | bash
