# Shared utility targets

# --- show: dry-run mode for inspecting targets ---
_SHOW_TARGETS := $(filter-out show,$(MAKECMDGOALS))

ifneq ($(filter show,$(MAKECMDGOALS)),)
ifneq ($(_SHOW_TARGETS),)
MAKEFLAGS += --just-print
endif
endif

show: ## Show the commands a target would run (usage: make show <target>)
	+@$(if $(_SHOW_TARGETS),true,echo "Usage: make show <target>")

.PHONY: help list ls show claude-install common-update

help: ## Show available targets with descriptions
	@for f in $(MAKEFILE_LIST); do \
		targets=$$(grep -E '^[a-zA-Z_-]+:.*##' "$$f" 2>/dev/null); \
		if [ -n "$$targets" ]; then \
			echo ""; \
			echo "$$f:"; \
			echo "$$targets" | awk -F ':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'; \
		fi; \
	done

list ls: ## List all targets
	@for f in $(MAKEFILE_LIST); do \
		targets=$$(grep -E '^[a-zA-Z_-]+[a-zA-Z_ -]*:' "$$f" 2>/dev/null | grep -v ':=' | grep -v '\.PHONY'); \
		if [ -n "$$targets" ]; then \
			echo ""; \
			echo "$$f:"; \
			echo "$$targets" | awk -F ':' '{printf "  %s\n", $$1}'; \
		fi; \
	done

claude-install: ## install Claude Code CLI
	curl -fsSL https://claude.ai/install.sh | bash

common-update: ## update dev-common submodule to latest
	@cd common && git pull origin main && cd .. && \
	git add common && \
	(git diff --cached --quiet common || git commit -m "[CC] chore: update dev-common") && \
	echo "dev-common is up to date"
