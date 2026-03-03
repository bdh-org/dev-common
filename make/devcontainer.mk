.PHONY: dc-install dc-up dc-shell dc-exec dc-stop dc-rm dc-nuke

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
