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
################################################################################
#                               MAIN FUNCTION
################################################################################
promote_release() {
  local tag base_version major minor patch release_type release_version
  local release_branch_name pr_number pr_state merged

  log_info "Switching to temporary branch: $TEMPORARY_RELEASE_BRANCH"
  git fetch origin "$TEMPORARY_RELEASE_BRANCH" --quiet
  git checkout "$TEMPORARY_RELEASE_BRANCH" --quiet
  git pull origin "$TEMPORARY_RELEASE_BRANCH" --quiet

  ##############################################################################
  # Detect RC version and determine release type
  ##############################################################################
  log_info "Detecting current RC tag…"
  git log
  tag=$(git describe --tags --abbrev=0)
  release_type=${tag%%-*}

  log_success "Detected release type: $release_type"

  ##############################################################################
  # Bump version + update changelog
  ##############################################################################
  log_info "Bumping version $tag → stable ($release_type)"
  release_version=$(npm version "$release_type" --no-git-tag-version)

  log_info "Updating changelog for $release_version"
  extract_and_append_changelog "$release_version"

  git add package.json Changelog.md
  git commit -m "Bump to $release_version and update Changelog.md" --quiet

  ##############################################################################
  # Rename temp branch → release/X.Y.Z
  ##############################################################################
  release_branch_name="release/$release_version"

  log_info "Renaming $TEMPORARY_RELEASE_BRANCH → $release_branch_name"
  git branch -m "$release_branch_name"
  git push origin "$release_branch_name" --quiet
  git push origin --delete "$TEMPORARY_RELEASE_BRANCH" --quiet || log_warning "Temporary branch already deleted"

  ##############################################################################
  # Create PR via REST API
  ##############################################################################
  log_info "Creating PR $release_branch_name → $RELEASE_BRANCH"

  pr_response=$(github_api POST "$REPO_URL/pulls" \
    "$(jq -n \
      --arg title "Release $release_version" \
      --arg head "$release_branch_name" \
      --arg base "$RELEASE_BRANCH" \
      --arg body "Automated promotion of release candidate." \
      '{title: $title, head: $head, base: $base, body: $body}')")

  pr_number=$(echo "$pr_response" | jq -r '.number')
  pr_url=$(echo "$pr_response" | jq -r '.html_url')

  if [[ "$pr_number" == "null" ]]; then
    log_error "Failed to create PR: $pr_response"
    exit 1
  fi

  log_success "PR created: $pr_url"

  ##############################################################################
  # Enable auto-merge (merge commit)
  ##############################################################################
  log_info "Enabling auto-merge on PR #$pr_number"

  github_api PUT "$REPO_URL/pulls/$pr_number/merge" \
    '{"merge_method": "merge"}' >/dev/null || {
      log_error "Auto-merge failed."
      exit 1
    }

  log_success "Auto-merge enabled"

  ##############################################################################
  # Poll PR status until merged
  ##############################################################################
  log_info "Waiting for PR #$pr_number to merge…"

  for i in {1..60}; do
    pr_state=$(github_api GET "$REPO_URL/pulls/$pr_number" | jq -r '.state')
    merged=$(github_api GET "$REPO_URL/pulls/$pr_number" | jq -r '.merged')

    if [[ "$merged" == "true" ]]; then
      log_success "PR merged successfully."
      break
    fi

    sleep 5
  done

  if [[ "$merged" != "true" ]]; then
    log_error "Timeout: PR did not merge in time."
    exit 1
  fi

  ##############################################################################
  # Create annotated tag
  ##############################################################################
  log_info "Creating Git tag $release_version"

  # Create lightweight tag locally & push
  git tag -a "$release_version" -m "Release $release_version"
  git push origin "$release_version" --quiet

  ##############################################################################
  # Create GitHub Release
  ##############################################################################
  if [[ -z "${NOTES_FILE:-}" ]]; then
    log_warning "NOTES_FILE not set — skipping GitHub release"
  else
    log_info "Creating GitHub Release $release_version"

    # Confirm that the tag exists on GitHub before creating the release
    echo "Waiting GitHub to register tag $release_version..."
    
    for i in {1..10}; do
      STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/repos/$REPO_URL/git/ref/tags/$release_version)
    
      if [[ "$STATUS" == "200" ]]; then
        echo "Tag detected on GitHub ✔"
        break
      fi
    
      echo "Tag not visible yet... retry $i/10"
      sleep 4
    done

    github_api POST "$REPO_URL/releases" \
      "$(jq -n \
        --arg tag "$release_version" \
        --arg name "$release_version" \
        --arg target "$MAIN_BRANCH" \
        --arg notes "$(cat "$NOTES_FILE")" \
        '{tag_name: $tag, name: $name, target_commitish: $target, body: $notes, draft: true, prerelease: true}')"

    log_success "GitHub Release created."
  fi

  log_success "Release $release_version successfully promoted."
}

promote_release
