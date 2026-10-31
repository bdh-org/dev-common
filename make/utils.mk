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

# The 0-9 in both character classes below is load-bearing, and its absence was
# silent: a target whose name holds a digit still RUNS, it just never appears in
# either listing, so the only symptom is a target nobody can discover
# (bdh-org/dev-common#229, found in bdh-site where `vm20-map`, `vm20-map-check`
# and `vm20-viewer-test` were all invisible). Digits in target names are
# ordinary -- `py311-*`, `s3-*`, `vm20-*` -- so this is the general fix, not a
# rename-around.
#
# The `( <name>)*` group is the sibling of that fix and the same shape of bug:
# help used to anchor its colon to the end of the FIRST name, so a target
# declared with a sibling on one line (`list ls:` -- this repo's own) never
# appeared, however it was spelled, while `make list` showed it and both ran
# (bdh-org/dev-common#323). It lists such a line as ONE row naming both targets,
# `list ls`, which is what the makefile says; splitting it into a row per name
# would repeat the description and claim two declarations where there is one.
# The group, rather than adding a space to the class, is deliberate: a bare
# `[a-zA-Z0-9_ -]+` also accepts ` :` and would start listing `FOO := bar ## x`
# assignments as targets across every consumer's makefiles.
help: ## Show available targets with descriptions
	@for f in $(MAKEFILE_LIST); do \
		targets=$$(grep -E '^[a-zA-Z0-9_-]+( [a-zA-Z0-9_-]+)*:.*##' "$$f" 2>/dev/null); \
		if [ -n "$$targets" ]; then \
			echo ""; \
			echo "$$f:"; \
			echo "$$targets" | awk -F ':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'; \
		fi; \
	done

list ls: ## List all targets
	@for f in $(MAKEFILE_LIST); do \
		targets=$$(grep -E '^[a-zA-Z0-9_-]+[a-zA-Z0-9_ -]*:' "$$f" 2>/dev/null | grep -v ':=' | grep -v '\.PHONY'); \
		if [ -n "$$targets" ]; then \
			echo ""; \
			echo "$$f:"; \
			echo "$$targets" | awk -F ':' '{printf "  %s\n", $$1}'; \
		fi; \
	done

claude-install: ## install Claude Code CLI
	curl -fsSL https://claude.ai/install.sh | bash

# Commit wording matches the fleet sweep (home-infra bump-submodule-pins.sh):
# "chore: bump common to <sha8> (<N> commits)". No [CC] prefix -- dropped from
# every other automated commit on 2026-03-15 (dev-common#293).
common-update: ## update dev-common submodule to latest
	@old=$$(git -C common rev-parse HEAD) && \
	(cd common && git pull origin main) && \
	git add common && \
	if git diff --cached --quiet common; then \
		echo "dev-common is up to date"; \
	else \
		new=$$(git -C common rev-parse --short=8 HEAD) && \
		n=$$(git -C common rev-list --count "$$old..HEAD") && \
		git commit -m "chore: bump common to $$new ($$n commits)" && \
		echo "dev-common bumped to $$new ($$n commits)"; \
	fi

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

# Mints a bdh-org-headful App token per org: the gh-<org>.token PAT files this
# used to read were revoked on 2026-09-25, and with none on disk the glob matched
# nothing and the target printed an empty list with exit 0 (dev-common#322).
# Fails loudly, naming the org, when a token cannot be minted or a listing is
# empty -- three orgs in the stack and zero consumers is a read failure, not an
# answer.
COMMON_CONSUMER_ORGS ?= bdh-org finzeug finriskanalytics
common-consumers: ## list repos that use the bdh-org/dev-common submodule across the three orgs (gh-app-token per org)
	@found=$$(mktemp); trap 'rm -f "$$found"' EXIT; \
	for o in $(COMMON_CONSUMER_ORGS); do \
	  tok=$$(gh-app-token "$$o") && [ -n "$$tok" ] || { \
	    echo "common-consumers: could not mint a token for $$o (gh-app-token $$o)" >&2; exit 2; }; \
	  repos=$$(GH_TOKEN="$$tok" gh repo list "$$o" --no-archived --limit 200 --json nameWithOwner --jq '.[].nameWithOwner') || { \
	    echo "common-consumers: gh repo list $$o failed" >&2; exit 2; }; \
	  [ -n "$$repos" ] || { echo "common-consumers: $$o listed ZERO repos" >&2; exit 2; }; \
	  for r in $$repos; do \
	    if GH_TOKEN="$$tok" gh api "repos/$$r/contents/.gitmodules" -H "Accept: application/vnd.github.raw" 2>/dev/null | grep -q 'dev-common'; then \
	      echo "$$r" >> "$$found"; \
	    fi; \
	  done; \
	done; \
	[ -s "$$found" ] || { \
	  echo "common-consumers: ZERO consumers across $(COMMON_CONSUMER_ORGS) -- a read failure, not an answer" >&2; exit 1; }; \
	sort -u "$$found"
