# Shared Python development targets
# Requires CONDA_PREFIX and PACKAGE_DIR to be defined (or uses defaults)

CONDA_PREFIX ?= /home/vscode/miniforge3
PACKAGE_DIR ?= $(PROJECT_NAME)

.PHONY: list-imports lint lint-fix format

list-imports: ## list imports for production requirements
	@$(CONDA_PREFIX)/bin/pipreqs $(PACKAGE_DIR) --print --mode no-pin 2>/dev/null | sort -u

lint: ## lint with ruff
	$(CONDA_PREFIX)/bin/ruff check .

lint-fix: ## lint with ruff and auto-fix
	$(CONDA_PREFIX)/bin/ruff check --fix .

format: ## format with ruff
	$(CONDA_PREFIX)/bin/ruff format .
