# Shared docker build targets.
#
# Requires CONTAINER_NAME and VERSION to be defined in the including
# Makefile. Both build targets tag the image as $(CONTAINER_NAME):latest
# and $(CONTAINER_NAME):$(VERSION).
#
# Override DOCKER_BUILD_ARGS to change build flags. Default includes
# --network=host (helps build-time pip/npm/apt installs in some
# environments). Set DOCKER_BUILD_ARGS= to drop it.
#
# Repos with pre-build steps (e.g., a frontend build) should override
# the build / build-clean targets locally; make's "overriding recipe"
# warning is expected.

DOCKER_BUILD_ARGS ?= --network=host

.PHONY: build build-clean

build: ## Build production image
	docker build $(DOCKER_BUILD_ARGS) -t $(CONTAINER_NAME):latest -t $(CONTAINER_NAME):$(VERSION) .

build-clean: ## Rebuild production image from scratch (no cache)
	docker build --no-cache $(DOCKER_BUILD_ARGS) -t $(CONTAINER_NAME):latest -t $(CONTAINER_NAME):$(VERSION) .
