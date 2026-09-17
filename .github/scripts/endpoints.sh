#!/usr/bin/env bash
# Shared URL helpers for mirror sync. Safe to source; defines functions only.
gitee_create_endpoint() {
  local owner="${1:?owner is required}"
  local git_user="${2:?git_user is required}"
  if [ "$owner" = "$git_user" ]; then
    printf '%s\n' 'https://gitee.com/api/v5/user/repos'
  else
    printf '%s\n' "https://gitee.com/api/v5/orgs/${owner}/repos"
  fi
}
