.PHONY: dc-install dc-up dc-shell dc-exec dc-stop dc-rm dc-nuke dc-prune

# Dry-run guard for dc-prune; set DRY=0 to apply.
DRY ?= 1

dc-install: ## Install devcontainer CLI globally
	npm install -g @devcontainers/cli

dc-up: ## Build and start the devcontainer
	devcontainer up --workspace-folder .

dc-shell: ## Shell into the devcontainer as remoteUser
	devcontainer exec --workspace-folder . bash -l

dc-exec: ## Run a command in the devcontainer (usage: make dc-exec CMD="your command")
	devcontainer exec --workspace-folder . $(CMD)

dc-stop: ## Stop the devcontainer
	@ID=$$(docker ps -q --filter "label=devcontainer.local_folder=$$(pwd)"); \
	if [ -n "$$ID" ]; then docker stop $$ID; else echo "No running devcontainer found"; fi

dc-rm: dc-stop ## Remove the devcontainer
	@ID=$$(docker ps -aq --filter "label=devcontainer.local_folder=$$(pwd)"); \
	if [ -n "$$ID" ]; then docker rm $$ID; else echo "No devcontainer to remove"; fi

dc-nuke: ## Force stop and remove the devcontainer
	@ID=$$(docker ps -aq --filter "label=devcontainer.local_folder=$$(pwd)"); \
	if [ -n "$$ID" ]; then docker rm -f $$ID; else echo "No devcontainer to remove"; fi

dc-prune: ## Remove devcontainer (vsc-*) images not used by any container, + dangling/cache (dry-run; DRY=0 to apply)
	@used=$$(docker ps -aq --no-trunc | xargs -r docker inspect -f '{{.Image}}' | tr '\n' ' '); \
	unused=$$(docker images --no-trunc --format '{{.ID}} {{.Repository}}' | awk '$$2 ~ /^vsc-/{print $$1}' | sort -u | while read -r id; do case " $$used " in *" $$id "*) : ;; *) echo "$$id" ;; esac; done); \
	if [ -z "$$unused" ]; then echo "No unused vsc-* images."; else echo "Unused vsc-* images:"; echo "$$unused"; fi; \
	if [ "$(DRY)" = "0" ]; then \
	  [ -n "$$unused" ] && echo "$$unused" | while read -r id; do docker rmi $$id >/dev/null 2>&1 && echo "removed $$id" || echo "skipped $$id (in use)"; done; \
	  docker image prune -f; docker builder prune -f; \
	else echo "(dry-run -- run 'make dc-prune DRY=0' to remove the above + dangling images/build cache)"; fi
