#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=endpoints.sh
source "$ROOT/endpoints.sh"

fail=0
assert_eq() {
  local got="$1" want="$2" label="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$label" "$got" "$want"
    fail=1
  fi
}

assert_eq "$(gitee_create_endpoint logic3579 logic3579)" \
  "https://gitee.com/api/v5/user/repos" \
  "personal namespace uses /user/repos"

assert_eq "$(gitee_create_endpoint ArkGravity logic3579)" \
  "https://gitee.com/api/v5/orgs/ArkGravity/repos" \
  "org namespace uses /orgs/{org}/repos"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "endpoints_test.sh: ok"
