#!/usr/bin/env bash
# Mirror-clone a GitHub repo and drop GitHub-only refs/pull/*.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO:?REPO is required}"

auth_header() {
  printf 'AUTHORIZATION: basic %s' "$(printf '%s:%s' "$1" "$2" | base64 | tr -d '\n')"
}

git -c "http.https://github.com/.extraheader=$(auth_header x-access-token "$GH_TOKEN")" \
  clone --mirror "https://github.com/${OWNER}/${REPO}.git" repo.git

# refs/pull/* are GitHub-only PR refs that Gitee rejects as hidden refs.
git -C repo.git for-each-ref --format='delete %(refname)' refs/pull \
  | git -C repo.git update-ref --stdin
