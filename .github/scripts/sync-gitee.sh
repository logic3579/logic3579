#!/usr/bin/env bash
# Ensure a Gitee repo exists, then push from ./repo.git via GIT_ASKPASS.
set -euo pipefail

: "${GITEE_TOKEN:?GITEE_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO:?REPO is required}"
: "${PRIVATE:?PRIVATE is required}"
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH is required}"
DESC="${DESC-}"

url="https://gitee.com/${OWNER}/${REPO}.git"

# Gitee's git HTTP ignores Authorization extraheaders and falls back to
# an interactive username prompt. GIT_ASKPASS keeps the token out of the
# remote URL and out of argv (reads from env instead).
askpass="$(mktemp)"
trap 'rm -f "$askpass"' EXIT
printf '%s\n' \
  '#!/bin/sh' \
  'case "$1" in' \
  '  *Username*) printf "%s\n" "$GITEE_GIT_USER" ;;' \
  '  *Password*) printf "%s\n" "$GITEE_TOKEN" ;;' \
  'esac' >"$askpass"
chmod 700 "$askpass"
export GITEE_GIT_USER="$OWNER"
export GIT_ASKPASS="$askpass"
export GIT_TERMINAL_PROMPT=0

git_gitee() {
  # Clear any inherited credential helpers so ASKPASS is used.
  git -C repo.git -c credential.helper= "$@"
}

status=$(curl -s --retry 3 --retry-delay 5 -o /dev/null -w "%{http_code}" \
  -H "Authorization: token $GITEE_TOKEN" \
  "https://gitee.com/api/v5/repos/${OWNER}/${REPO}")

if [ "$status" = "404" ]; then
  payload=$(jq -n \
    --arg name "$REPO" --arg desc "$DESC" --argjson private "$PRIVATE" \
    '{name: $name, description: $desc, private: $private}')
  curl -sSf -X POST \
    -H "Authorization: token $GITEE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://gitee.com/api/v5/user/repos" > /dev/null
  echo "Created Gitee repo ${OWNER}/${REPO}"
elif [ "$status" != "200" ]; then
  echo "::error::Gitee API returned $status for ${REPO}"
  exit 1
fi

# Push heads/tags first so the source's default branch exists on the target
# before we realign it — Gitee refuses to delete the current default branch
# during a mirror push.
git_gitee push "$url" --all
git_gitee push "$url" --tags
# PATCH requires `name`; enforce default_branch and visibility (Gitee's own
# account-level default is `private: true` regardless of the POST payload).
curl -sSf -X PATCH \
  -H "Authorization: token $GITEE_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
        --arg n "$REPO" --arg b "$DEFAULT_BRANCH" --argjson p "$PRIVATE" \
        '{name: $n, default_branch: $b, private: $p}')" \
  "https://gitee.com/api/v5/repos/${OWNER}/${REPO}" > /dev/null
# Final mirror push prunes refs that no longer exist on source.
git_gitee push --mirror "$url"
