# Shared version management targets
# Requires VERSION to be defined in the including Makefile

# Portable sed in-place: macOS requires -i '', GNU requires -i
SED_I := $(shell if sed --version 2>/dev/null | grep -q GNU; then echo 'sed -i'; else echo 'sed -i ""'; fi)

.PHONY: tag bump-patch bump-minor bump-major

tag: ## create git tag for current VERSION
	git tag $(VERSION)
	git push origin $(VERSION)

bump-patch: ## bump patch version (x.y.Z) and commit
	@NEW_VERSION=$$(echo $(VERSION) | awk -F. '{print $$1"."$$2"."$$3+1}') && \
	$(SED_I) "s/VERSION=$(VERSION)/VERSION=$$NEW_VERSION/" Makefile && \
	[ -f $(PACKAGE_DIR)/__init__.py ] && grep -q '__version__' $(PACKAGE_DIR)/__init__.py && \
		$(SED_I) "s/__version__ = \"$(VERSION)\"/__version__ = \"$$NEW_VERSION\"/" $(PACKAGE_DIR)/__init__.py && \
		git add $(PACKAGE_DIR)/__init__.py || true && \
	git add Makefile && \
	git commit -m "[CC] chore: bump version to $$NEW_VERSION" && \
	echo "Bumped to $$NEW_VERSION"

bump-minor: ## bump minor version (x.Y.0) and commit
	@NEW_VERSION=$$(echo $(VERSION) | awk -F. '{print $$1"."$$2+1".0"}') && \
	$(SED_I) "s/VERSION=$(VERSION)/VERSION=$$NEW_VERSION/" Makefile && \
	[ -f $(PACKAGE_DIR)/__init__.py ] && grep -q '__version__' $(PACKAGE_DIR)/__init__.py && \
		$(SED_I) "s/__version__ = \"$(VERSION)\"/__version__ = \"$$NEW_VERSION\"/" $(PACKAGE_DIR)/__init__.py && \
		git add $(PACKAGE_DIR)/__init__.py || true && \
	git add Makefile && \
	git commit -m "[CC] chore: bump version to $$NEW_VERSION" && \
	echo "Bumped to $$NEW_VERSION"

bump-major: ## bump major version (X.0.0) and commit
	@NEW_VERSION=$$(echo $(VERSION) | awk -F. '{print $$1+1".0.0"}') && \
	$(SED_I) "s/VERSION=$(VERSION)/VERSION=$$NEW_VERSION/" Makefile && \
	[ -f $(PACKAGE_DIR)/__init__.py ] && grep -q '__version__' $(PACKAGE_DIR)/__init__.py && \
		$(SED_I) "s/__version__ = \"$(VERSION)\"/__version__ = \"$$NEW_VERSION\"/" $(PACKAGE_DIR)/__init__.py && \
		git add $(PACKAGE_DIR)/__init__.py || true && \
	git add Makefile && \
	git commit -m "[CC] chore: bump version to $$NEW_VERSION" && \
	echo "Bumped to $$NEW_VERSION"
