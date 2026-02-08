# Shared conda environment targets
# Manages the base conda environment for development
#
# Requires: Miniforge installed (via devcontainer/setup-base.sh)
# Variables:
#   CONDA_PREFIX        - path to conda installation (default: ~/miniforge3)
#   COMMON_DIR          - path to dev-common (default: common)
#   PROJECT_CONDA_PACKAGES - path to project-specific conda packages file (optional)

CONDA_PREFIX ?= $(HOME)/miniforge3
COMMON_DIR ?= common
PROJECT_CONDA_PACKAGES ?=

CONDA := $(CONDA_PREFIX)/bin/conda
BASE_PACKAGES := $(COMMON_DIR)/devcontainer/base-conda-packages.txt
DEV_TOOLS := ruff pytest pytest-cov ipykernel jupyterlab pipreqs

.PHONY: env env-info

env: ## install/refresh conda base dev environment
	@echo "==> Installing base conda packages..."
	$(CONDA) install -y --file $(BASE_PACKAGES)
	@if [ -n "$(PROJECT_CONDA_PACKAGES)" ] && [ -f "$(PROJECT_CONDA_PACKAGES)" ]; then \
		echo "==> Installing project conda packages from $(PROJECT_CONDA_PACKAGES)..."; \
		$(CONDA) install -y --file $(PROJECT_CONDA_PACKAGES); \
	fi
	@echo "==> Installing dev tools..."
	$(CONDA) install -y $(DEV_TOOLS)
	@echo "==> Dev environment ready"

env-info: ## show conda environment info
	$(CONDA) info
	@echo ""
	@echo "==> Installed packages:"
	$(CONDA) list
