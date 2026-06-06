# Shared version management targets
# Requires VERSION to be defined in the including Makefile

# Portable sed in-place: macOS requires -i '', GNU requires -i
SED_I := $(shell if sed --version 2>/dev/null | grep -q GNU; then echo 'sed -i'; else echo 'sed -i ""'; fi)

.PHONY: tag bump-patch bump-minor bump-major version-check

tag: ## create git tag for current VERSION
	git tag $(VERSION)
	git push origin $(VERSION)

# Fail if the Makefile VERSION disagrees with any other version string in the
# repo (Python __version__, package.json). The bump-* targets keep these in
# sync, but a manual sed/edit (or a partial bump) can drift them -- this
# target, run in CI, makes that drift a red build instead of a silent bug.
# No-op for repos that have neither file.
version-check: ## fail if VERSION disagrees with __version__ / package.json
	@fail=0; \
	if [ -n "$(PACKAGE_DIR)" ] && [ -f "$(PACKAGE_DIR)/__init__.py" ] && grep -q '__version__' "$(PACKAGE_DIR)/__init__.py"; then \
		pv=`grep -m1 '__version__' "$(PACKAGE_DIR)/__init__.py" | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/'`; \
		if [ "$$pv" != "$(VERSION)" ]; then echo "version drift: Makefile VERSION=$(VERSION) but $(PACKAGE_DIR)/__init__.py __version__=$$pv" >&2; fail=1; fi; \
	fi; \
	if [ -f package.json ] && grep -q '"version"' package.json; then \
		jv=`grep -m1 '"version"' package.json | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'`; \
		if [ "$$jv" != "$(VERSION)" ]; then echo "version drift: Makefile VERSION=$(VERSION) but package.json version=$$jv" >&2; fail=1; fi; \
	fi; \
	if [ "$$fail" = 0 ]; then echo "version-check OK ($(VERSION))"; \
	else echo "Fix so all version strings match (re-run 'make bump-patch', or edit by hand)." >&2; exit 1; fi

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
