#!/usr/bin/env bash
set -euo pipefail

VERSION_TYPE="${1:-patch}"

log() { echo "::group::[prepare_release_test] $*"; echo "$*"; echo "::endgroup::"; }
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# muestra el cwd y archivos
log_info "PWD: $(pwd)"
log_info "Listing files:"
ls -la

# muestra branch actual
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "no-git")
log_info "Current branch: $CURRENT_BRANCH"

# Simula crear branch temporal y tag localmente (no push)
TEMP_BRANCH="rc-temp-test-$(date +%s)"
log_info "Creating temporary branch: $TEMP_BRANCH"
git checkout -b "$TEMP_BRANCH"

# Simula npm version solo si package.json existe
if [[ -f package.json ]]; then
  log_info "Found package.json — running npm version pre${VERSION_TYPE} --preid=rc (dry-run)"
  # Nota: aquí no aplicamos cambios reales a package.json para no romper pruebas:
  npm --version || true
else
  log_info "No package.json found — skipping npm bump"
fi

log_info "Simulating tagging and pushing (no push in test). Done."
echo "TEST_RC_BRANCH=$TEMP_BRANCH" >> "$GITHUB_ENV"
