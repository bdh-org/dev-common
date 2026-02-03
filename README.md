# dev-common

Shared development infrastructure: Makefile targets, GitHub Actions, devcontainer configs, and more.

## Usage

Add as a submodule to your repo:

```bash
git submodule add https://github.com/brianholland/dev-common.git common
```

Then include what you need in your Makefile:

```makefile
VERSION=1.0.0
IMAGE_NAME=myapp

include common/make/version.mk
include common/make/utils.mk

# Your project-specific targets...
build:
    docker build -t $(IMAGE_NAME):$(VERSION) .
```

## Contents

### make/

Shared Makefile targets. Requires `VERSION` variable in your Makefile.

| File | Targets | Description |
|------|---------|-------------|
| `version.mk` | `bump-patch`, `bump-minor`, `bump-major`, `tag` | Semantic version management |
| `utils.mk` | `list`, `ls`, `claude-install` | Common utilities |

### github/workflows/

Copy to your repo's `.github/workflows/` directory.

| File | Description |
|------|-------------|
| `tag-version.yml` | Auto-create git tags when Makefile VERSION changes on main |

### devcontainer/

*(Coming soon)* Shared devcontainer configurations.

### claude/

*(Coming soon)* Shared Claude Code settings and permissions.

### python/

*(Coming soon)* Shared Python environment configurations.

## Updating

To update the submodule to the latest version:

```bash
cd common
git pull origin main
cd ..
git add common
git commit -m "[CC] chore: update dev-common"
```
