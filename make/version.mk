# Shared version management targets
# Requires VERSION to be defined in the including Makefile

# Portable sed in-place: macOS requires -i '', GNU requires -i
SED_I := $(shell if sed --version 2>/dev/null | grep -q GNU; then echo 'sed -i'; else echo 'sed -i ""'; fi)

.PHONY: tag bump-patch bump-minor bump-major

tag: ## create git tag for current VERSION
	git tag $(VERSION)
	git push origin $(VERSION)

# Implementation note: the bump-* targets all do the same rewrite work
# for the same set of files; only NEW_VERSION differs. We compute it,
# then call _bump_apply to do the substitutions.
#
# Files touched (each conditional on existence + relevant field):
#   - Makefile (VERSION= line)
#   - $(PACKAGE_DIR)/__init__.py (__version__ = "...") -- Python projects
#   - package.json ("version": "...") -- Node/Vite projects
#   - package-lock.json (top-level + packages[""] "version") -- if present

define _bump_apply
	$(SED_I) "s/VERSION=$(VERSION)/VERSION=$$NEW_VERSION/" Makefile && \
	git add Makefile && \
	if [ -f $(PACKAGE_DIR)/__init__.py ] && grep -q '__version__' $(PACKAGE_DIR)/__init__.py; then \
		$(SED_I) 's/__version__ = ".*"/__version__ = "'"$$NEW_VERSION"'"/' $(PACKAGE_DIR)/__init__.py && \
		git add $(PACKAGE_DIR)/__init__.py; \
	fi && \
	if [ -f package.json ] && grep -q '"version"' package.json; then \
		$(SED_I) 's/"version": *"[^"]*"/"version": "'"$$NEW_VERSION"'"/' package.json && \
		git add package.json; \
	fi && \
	if [ -f package-lock.json ] && grep -q '"version"' package-lock.json; then \
		$(SED_I) '1,12 s/"version": *"[^"]*"/"version": "'"$$NEW_VERSION"'"/' package-lock.json && \
		git add package-lock.json; \
	fi && \
	git commit -m "chore: bump version to $$NEW_VERSION" && \
	echo "Bumped to $$NEW_VERSION"
endef

bump-patch: ## bump patch version (x.y.Z) and commit
	@NEW_VERSION=$$(echo $(VERSION) | awk -F. '{print $$1"."$$2"."$$3+1}') && \
	$(call _bump_apply)

bump-minor: ## bump minor version (x.Y.0) and commit
	@NEW_VERSION=$$(echo $(VERSION) | awk -F. '{print $$1"."$$2+1".0"}') && \
	$(call _bump_apply)

bump-major: ## bump major version (X.0.0) and commit
	@NEW_VERSION=$$(echo $(VERSION) | awk -F. '{print $$1+1".0.0"}') && \
	$(call _bump_apply)
