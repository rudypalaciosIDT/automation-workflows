#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract_changelog.sh"

API_URL="https://api.github.com"

log_info()    { echo "[INFO] $*"; }
log_warning() { echo "[WARN] $*"; }
log_success() { echo "[OK]   $*"; }
log_error()   { echo "[ERR]  $*" >&2; }

github_api() {
  local method=$1
  local endpoint=$2
  local data=${3:-}

  if [[ -n "$data" ]]; then
    curl -sS -X "$method" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      "$API_URL/repos/$endpoint" \
      -d "$data"
  else
    curl -sS -X "$method" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$API_URL/repos/$endpoint"
  fi
}

promote_release() {
  local owner repo
  owner="${REPO_URL%%/*}"
  repo="${REPO_URL##*/}"

  log_info "Switching to temporary branch: $TEMPORARY_RELEASE_BRANCH"

  # Ensure we have the branch and up-to-date refs
  git fetch origin "$TEMPORARY_RELEASE_BRANCH" --tags --force
  if ! git ls-remote --exit-code --heads origin "$TEMPORARY_RELEASE_BRANCH" >/dev/null 2>&1; then
    log_error "Temporary branch '$TEMPORARY_RELEASE_BRANCH' not found on remote origin."
    exit 1
  fi

  git checkout "$TEMPORARY_RELEASE_BRANCH"
  git pull origin "$TEMPORARY_RELEASE_BRANCH"

  ##############################################################################
  # Detect RC tag and release type
  ##############################################################################
  log_info "Detecting current RC tag…"
  # This will exit non-zero if there are no tags; handle that
  if ! tag=$(git describe --tags --abbrev=0); then
    log_error "No tags found on repository — cannot detect RC tag."
    exit 1
  fi

  release_type=${tag%%-*}
  log_success "Detected tag: $tag -> release_type: $release_type"

  ##############################################################################
  # Bump version to stable and update changelog
  ##############################################################################
  log_info "Bumping version $tag → stable ($release_type)"
  release_version=$(npm version "$release_type" --no-git-tag-version)
  log_success "Computed release_version: $release_version"

  log_info "Updating changelog for $release_version"
  extract_and_append_changelog "$release_version"

  # commit changes
  git add package.json Changelog.md || true
  if git diff --cached --quiet; then
    log_warning "Nothing staged to commit (package.json/Changelog.md unchanged)."
  else
    git commit -m "Bump to $release_version and update Changelog.md"
    log_success "Committed package.json and Changelog.md"
  fi

  ##############################################################################
  # Rename temp branch → release/X.Y.Z and push
  ##############################################################################
  release_branch_name="release/$release_version"
  log_info "Renaming branch $TEMPORARY_RELEASE_BRANCH → $release_branch_name"
  git branch -m "$release_branch_name"

  log_info "Pushing new release branch $release_branch_name to origin"
  git push origin "$release_branch_name"

  log_info "Attempting to delete remote temporary branch $TEMPORARY_RELEASE_BRANCH"
  if ! git push origin --delete "$TEMPORARY_RELEASE_BRANCH" >/dev/null 2>&1; then
    log_warning "Remote temporary branch deletion failed (may be already deleted)."
  fi

  ##############################################################################
  # Create PR via REST API
  ##############################################################################
  log_info "Creating PR $release_branch_name -> $RELEASE_BRANCH"
  pr_payload=$(jq -n \
    --arg title "Release $release_version" \
    --arg head "$release_branch_name" \
    --arg base "$RELEASE_BRANCH" \
    --arg body "Automated promotion of release candidate." \
    '{title: $title, head: $head, base: $base, body: $body, draft: false}')

  pr_response=$(github_api POST "$REPO_URL/pulls" "$pr_payload")
  pr_number=$(echo "$pr_response" | jq -r '.number // empty')
  pr_url=$(echo "$pr_response" | jq -r '.html_url // empty')

  if [[ -z "$pr_number" ]]; then
    log_error "Failed to create PR. Response: $pr_response"
    exit 1
  fi

  log_success "PR created: $pr_url (#$pr_number)"

  ##############################################################################
  # Try to merge immediately (merge commit). This mirrors tu script anterior.
  ##############################################################################
  log_info "Attempting to merge PR #$pr_number (merge commit)"
  merge_payload='{"merge_method":"merge"}'
  merge_resp=$(github_api PUT "$REPO_URL/pulls/$pr_number/merge" "$merge_payload" 2>&1) || {
    log_warning "Merge attempt failed or returned non-2xx: $merge_resp"
    # Do not exit here; we'll poll for PR to be merged by auto-merge or other actors.
  }

  ##############################################################################
  # Poll PR status until merged (timeout after a while)
  ##############################################################################
  log_info "Waiting for PR #$pr_number to merge…"
  local merged="false"
  for i in {1..60}; do
    sleep 5
    pr_state_json=$(github_api GET "$REPO_URL/pulls/$pr_number")
    merged=$(echo "$pr_state_json" | jq -r '.merged // false')
    if [[ "$merged" == "true" || "$merged" == "True" ]]; then
      log_success "PR merged successfully."
      break
    fi
  done

  if [[ "$merged" != "true" && "$merged" != "True" ]]; then
    log_error "Timeout: PR #$pr_number did not merge in time."
    exit 1
  fi

  ##############################################################################
  # Create annotated tag and push
  ##############################################################################
  log_info "Creating annotated tag $release_version"
  git tag -a "$release_version" -m "Release $release_version"
  git push origin "$release_version"

  ##############################################################################
  # NOTES_FILE already created by extract_and_append_changelog.sh
  # Export outputs for GitHub Actions if available
  ##############################################################################
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "release_version=$release_version" >> "$GITHUB_OUTPUT"
    # If NOTES_FILE variable set by extract_changelog.sh, export it; else export empty
    NOTES_FILE_PATH="${NOTES_FILE:-}"
    echo "NOTES_FILE=$NOTES_FILE_PATH" >> "$GITHUB_OUTPUT"
  fi

  log_success "Release $release_version successfully promoted (branch: $release_branch_name)."
  log_info "PR: $pr_url"
}

promote_release
