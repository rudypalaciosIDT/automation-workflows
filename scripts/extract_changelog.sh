#!/usr/bin/env bash
set -euo pipefail

jira_linkify() {
    while IFS= read -r line; do
        echo "$line" | sed -E "s~([A-Za-z]+-[0-9]+)~[\1]($JIRA_URL/\1)~g"
    done
}

pr_linkify() {
    local GIT_PR_URL="https://github.com/${REPO_URL}/pull"
    while IFS= read -r line; do
        echo "$line" | sed -E "s~#([0-9]+)~[\#\1]($GIT_PR_URL/\1)~g"
    done
}

extract_and_append_changelog() {
    local CHANGELOG_FILE TEMP_FILE
    CHANGELOG_FILE="Changelog.md"
    TEMP_FILE=$(mktemp)

    echo "# Changelog" > "$TEMP_FILE"
    echo "## $VERSION" >> "$TEMP_FILE"

    git log ${RELEASE_BRANCH}..${TEMPORARY_RELEASE_BRANCH} \
        --merges \
        --grep="^Merge pull request" \
        --pretty=format:"%s" \
    | sed -E 's/^Merge pull request //; s/ from [^/]+\/?/ /' \
    | while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $line =~ ^#([0-9]+)[[:space:]]+([A-Z]+-[0-9]+)-?(.*)$ ]]; then
            pr_no="#${BASH_REMATCH[1]}"
            ticket_no="${BASH_REMATCH[2]}"
            description="${BASH_REMATCH[3]//-/ }"

            output="  - ${ticket_no}: ${description^} (${pr_no})"
        else
            output="  - $line"
        fi

        echo $output

    done | pr_linkify | jira_linkify >> "$TEMP_FILE"

    echo -e "\n**Full Changelog**: https://github.com/$REPO_URL/commits/$VERSION\n" >> "$TEMP_FILE"

    NOTES_FILE=$(mktemp)
    LAST_TAG=$(git tag --sort=-v:refname | head -n 1)
    TAG_DATE=$(git log -1 --format=%ad --date=short "$LAST_TAG" || echo "")

    echo "## Release date: $TAG_DATE" > "$NOTES_FILE"
    tail -n +3 "$TEMP_FILE" >> "$NOTES_FILE"

    echo "NOTES_FILE=$NOTES_FILE" >> "$GITHUB_OUTPUT"

    if [[ -f "$CHANGELOG_FILE" ]]; then
        tail -n +2 "$CHANGELOG_FILE" >> "$TEMP_FILE"
    fi

    mv "$TEMP_FILE" "$CHANGELOG_FILE"
    echo "[OK] Changelog updated for $VERSION"
}

extract_and_append_changelog