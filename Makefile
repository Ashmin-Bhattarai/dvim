# =============================================================================
# Makefile — dvim local development commands
#
# Usage:
#   make build        build Docker image locally
#   make test         run test suite against local image
#   make sync         sync install.sh + launcher/dvim → docs/
#   make release      sync docs, commit, push to GitHub
#   make tag v=1.0.0  create and push a git tag (triggers CD pipeline)
#   make push         push image to Docker Hub (manual override)
#   make clean        remove local dvim Docker image
# =============================================================================

IMAGE    := ashminbhattarai/dvim
TAG      := latest
FULL_TAG := $(IMAGE):$(TAG)

.PHONY: build test sync release tag push clean help

# -----------------------------------------------------------------------------
# build — build Docker image locally
# -----------------------------------------------------------------------------
build:
	@echo "==> Building $(FULL_TAG)..."
	docker build -t $(FULL_TAG) .
	@echo "==> Build complete."

# -----------------------------------------------------------------------------
# test — run integration test suite against local image
# Requires image to be built first: make build
# -----------------------------------------------------------------------------
test:
	@echo "==> Running test suite against $(FULL_TAG)..."
	bash test.sh $(FULL_TAG)

# -----------------------------------------------------------------------------
# sync — copy source files to docs/ for GitHub Pages hosting
# Always run this before committing changes to install.sh or launcher/dvim
# -----------------------------------------------------------------------------
sync:
	@echo "==> Syncing docs/..."
	@mkdir -p docs/launcher
	@cp install.sh docs/install.sh
	@cp launcher/dvim docs/launcher/dvim
	@echo "==> Synced:"
	@echo "    install.sh       → docs/install.sh"
	@echo "    launcher/dvim    → docs/launcher/dvim"

# -----------------------------------------------------------------------------
# release — sync docs, commit, and push to GitHub
# Does NOT push to Docker Hub — use 'make tag' to trigger the CD pipeline
# -----------------------------------------------------------------------------
release: sync
	@echo "==> Committing docs sync..."
	git add docs/install.sh docs/launcher/dvim
	git diff --cached --quiet || git commit -m "chore: sync docs"
	@echo "==> Pushing to GitHub..."
	git push
	@echo "==> Done. To trigger a Docker Hub release, run: make tag v=x.y.z"

# -----------------------------------------------------------------------------
# tag — create and push a semantic version tag
# This triggers the GitHub Actions release workflow which:
#   1. Builds and tests the image
#   2. Pushes to Docker Hub as both :vX.Y.Z and :latest
#   3. Creates a GitHub Release with auto-generated notes
#
# Usage: make tag v=1.0.0
# -----------------------------------------------------------------------------
tag:
ifndef v
	$(error Usage: make tag v=1.0.0)
endif
	@echo "==> Creating tag v$(v)..."
	git tag -a "v$(v)" -m "Release v$(v)"
	git push origin "v$(v)"
	@echo "==> Tag v$(v) pushed — GitHub Actions will build and release."
	@echo "==> Watch progress at: https://github.com/ashmin-bhattarai/dvim/actions"

# -----------------------------------------------------------------------------
# push — manually push image to Docker Hub (bypasses CI/CD)
# Use this only for hotfixes. Prefer 'make tag' for normal releases.
# -----------------------------------------------------------------------------
push:
	@echo "==> Pushing $(FULL_TAG) to Docker Hub..."
	docker push $(FULL_TAG)
	@echo "==> Pushed."

# -----------------------------------------------------------------------------
# clean — remove local Docker image
# -----------------------------------------------------------------------------
clean:
	@echo "==> Removing local image $(FULL_TAG)..."
	docker rmi $(FULL_TAG) 2>/dev/null || echo "Image not found, skipping."

# -----------------------------------------------------------------------------
# help — show available targets
# -----------------------------------------------------------------------------
help:
	@echo ""
	@echo "dvim Makefile targets:"
	@echo ""
	@echo "  make build           Build Docker image locally"
	@echo "  make test            Run test suite"
	@echo "  make sync            Sync install.sh + launcher → docs/"
	@echo "  make release         Sync + commit + push to GitHub"
	@echo "  make tag v=1.0.0     Tag release (triggers Docker Hub push via CI)"
	@echo "  make push            Manually push image to Docker Hub"
	@echo "  make clean           Remove local Docker image"
	@echo ""