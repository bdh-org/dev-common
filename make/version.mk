# Shared version management targets
# Requires VERSION to be defined in the including Makefile

.PHONY: tag bump-patch bump-minor bump-major

tag: ## create git tag for current VERSION
	git tag $(VERSION)
	git push origin $(VERSION)

bump-patch: ## bump patch version (x.y.Z) and commit
	@NEW_VERSION=$$(echo $(VERSION) | awk -F. '{print $$1"."$$2"."$$3+1}') && \
	sed -i "s/VERSION=$(VERSION)/VERSION=$$NEW_VERSION/" Makefile && \
	git add Makefile && \
	git commit -m "[CC] chore: bump version to $$NEW_VERSION" && \
	echo "Bumped to $$NEW_VERSION"

bump-minor: ## bump minor version (x.Y.0) and commit
	@NEW_VERSION=$$(echo $(VERSION) | awk -F. '{print $$1"."$$2+1".0"}') && \
	sed -i "s/VERSION=$(VERSION)/VERSION=$$NEW_VERSION/" Makefile && \
	git add Makefile && \
	git commit -m "[CC] chore: bump version to $$NEW_VERSION" && \
	echo "Bumped to $$NEW_VERSION"

bump-major: ## bump major version (X.0.0) and commit
	@NEW_VERSION=$$(echo $(VERSION) | awk -F. '{print $$1+1".0.0"}') && \
	sed -i "s/VERSION=$(VERSION)/VERSION=$$NEW_VERSION/" Makefile && \
	git add Makefile && \
	git commit -m "[CC] chore: bump version to $$NEW_VERSION" && \
	echo "Bumped to $$NEW_VERSION"
