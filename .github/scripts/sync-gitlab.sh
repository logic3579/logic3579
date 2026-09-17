#!/usr/bin/env bash
# Ensure a GitLab project exists, then mirror-push from ./repo.git.
set -euo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO:?REPO is required}"
: "${PRIVATE:?PRIVATE is required}"
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH is required}"
DESC="${DESC-}"

auth_header() {
  printf 'AUTHORIZATION: basic %s' "$(printf '%s:%s' "$1" "$2" | base64 | tr -d '\n')"
}

encoded="${OWNER}%2F${REPO}"
url="https://gitlab.com/${OWNER}/${REPO}.git"
gitlab_auth="$(auth_header oauth2 "$GITLAB_TOKEN")"

status=$(curl -s --retry 3 --retry-delay 5 -o /dev/null -w "%{http_code}" \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://gitlab.com/api/v4/projects/${encoded}")

if [ "$status" = "404" ]; then
  visibility=$([ "$PRIVATE" = "true" ] && echo private || echo public)
  payload=$(jq -n \
    --arg name "$REPO" --arg desc "$DESC" \
    --arg vis "$visibility" --arg branch "$DEFAULT_BRANCH" \
    '{name: $name, description: $desc, visibility: $vis, default_branch: $branch}')
  curl -sSf -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://gitlab.com/api/v4/projects" > /dev/null
  echo "Created GitLab project ${OWNER}/${REPO}"
elif [ "$status" != "200" ]; then
  echo "::error::GitLab API returned $status for ${REPO}"
  exit 1
fi

# GitLab is lenient about HEAD/default-branch reassignment during mirror
# push, so a single mirror push suffices.
git -C repo.git -c "http.https://gitlab.com/.extraheader=${gitlab_auth}" \
  push --mirror "$url"
