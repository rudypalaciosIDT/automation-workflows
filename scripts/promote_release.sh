#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# Rename temp branch → release/X.Y.Z and push
  release_branch_name="release/$VERSION"
  log_info "Renaming branch $TEMPORARY_RELEASE_BRANCH → $release_branch_name"
  if git branch -m "$release_branch_name"; then
      log_success "Branch renamed to '$release_branch_name'."
  else
      log_error "Failed to rename branch to '$release_branch_name'. Aborting."
      exit 1
  fi

  # Push renamed branch
  if git push origin "$release_branch_name"; then
      log_success "Successfully pushed '$release_branch_name' to origin."

      if git push origin --delete "$TEMPORARY_RELEASE_BRANCH" --quiet; then
          log_success "Temporary branch '$TEMPORARY_RELEASE_BRANCH' deleted from origin."
      else
          log_warning "Could not delete temporary branch '$TEMPORARY_RELEASE_BRANCH'. It may not exist."
      fi
  else
      log_error "Failed to push '$release_branch_name' to origin. Temporary branch will NOT be deleted."
      exit 1
  fi

# Create PR via REST API
  log_info "Creating PR $release_branch_name -> $RELEASE_BRANCH"
  pr_payload=$(jq -n \
    --arg title "Release $VERSION" \
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

# Try to merge immediately (merge commit).
  log_info "Attempting to merge PR #$pr_number (merge commit)"
  merge_payload='{"merge_method":"merge"}'
  merge_resp=$(github_api PUT "$REPO_URL/pulls/$pr_number/merge" "$merge_payload" 2>&1) || {
    log_warning "Merge attempt failed or returned non-2xx: $merge_resp"
  }

# Poll PR status until merged (timeout after a while)
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
}

promote_release
