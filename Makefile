VERSION=0.10.51

# Include our own shared targets
include make/version.mk
include make/utils.mk
include make/devcontainer.mk

# dev-common's own tests, over the shell it ships (dev-common#157). Deliberately
# defined HERE and not in a make/*.mk: consumers include those, and tests/ is
# this repo's, not theirs. Mirrors what .github/workflows/shell-tests.yml runs.
.PHONY: test
test: ## run dev-common's own shell tests
	@fail=0; \
	for t in tests/*.test.sh; do \
		echo "== $$t"; bash "$$t" || fail=1; \
	done; \
	exit $$fail
