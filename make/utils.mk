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

.PHONY: help list ls show claude-install common-update incorporate-devtemplate prod-clean dev-clean recreate common-consumers

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

# Signpost only: incorporating devtemplate improvements needs human judgment
# (each repo has bespoke customizations), so there is no automated target. This
# points at the Claude Code skill that does the diff + files issues (P14).
incorporate-devtemplate: ## (signpost) run the /incorporate-devtemplate Claude Code skill
	@echo "Incorporating devtemplate improvements needs human judgment, so there"
	@echo "is no automated make target. In Claude Code, run:"
	@echo ""
	@echo "    /incorporate-devtemplate"
	@echo ""
	@echo "It diffs each repo against devtemplate and files issues for missing changes."

PROD_SERVER ?= min
DEV_SERVER ?= twix
IMAGE_NAME ?= $(PROJECT_NAME)

# Body shared by prod-clean and dev-clean: remove stopped containers built
# from $(IMAGE_NAME) and old non-:latest image tags that no running container
# is using. $(1) is the SSH target.
define _docker_clean
	ssh $(1) ' \
		docker ps -a --filter ancestor=$(IMAGE_NAME) --filter status=exited -q | xargs -r docker rm; \
		USED_IDS=$$(docker ps --format "{{.Image}}" | xargs -r -n1 docker inspect --format "{{.Id}}" 2>/dev/null | sort -u); \
		for TAG in $$(docker images $(IMAGE_NAME) --format "{{.Repository}}:{{.Tag}}" | grep -v ":latest"); do \
			TAG_ID=$$(docker inspect --format "{{.Id}}" "$$TAG" 2>/dev/null); \
			echo "$$USED_IDS" | grep -qF "$$TAG_ID" && echo "keep $$TAG" || \
			{ echo "remove $$TAG" && docker rmi "$$TAG"; }; \
		done'
endef

prod-clean: ## Remove old Docker images and stopped containers on production
	$(call _docker_clean,$(PROD_SERVER))

dev-clean: ## Remove old Docker images and stopped containers on dev
	$(call _docker_clean,$(DEV_SERVER))

recreate: ## Force-recreate a service container so it picks up env_file changes
ifndef SERVICE
	$(error SERVICE is required. Usage: make recreate SERVICE=<service-name>)
endif
	docker compose up -d --force-recreate $(SERVICE)

common-consumers: ## list repos that use the bdh-org/dev-common submodule across orgs you hold tokens for
	@cred=$$HOME/.config/ai/claude/credentials; \
	for tok in $$cred/gh-*.token; do \
	  [ -e "$$tok" ] || continue; \
	  o=$$(basename "$$tok" .token | sed 's/^gh-//'); \
	  GH_TOKEN=$$(cat "$$tok") gh repo list "$$o" --no-archived --limit 200 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null \
	  | while read -r r; do \
	      GH_TOKEN=$$(cat "$$tok") gh api "repos/$$r/contents/.gitmodules" -H "Accept: application/vnd.github.raw" 2>/dev/null | grep -q 'dev-common' && echo "$$r"; \
	    done; \
	done | sort -u
