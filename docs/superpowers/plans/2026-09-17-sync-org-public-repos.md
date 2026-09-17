# Sync Org Public Repos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror allowlisted GitHub organization public repositories (starting with `ArkGravity`) to matching GitLab groups and Gitee orgs, without changing personal-repo sync.

**Architecture:** Keep the weekly hub workflow in this profile repo. `list_repos` emits `{owner,name,...}` for personal repos plus `SYNC_ORGS` public org repos. Clone/push use `matrix.repo.owner` as the path on GitHub/GitLab/Gitee (1:1). Gitee git HTTP auth stays on the personal username; only the create API switches to `/orgs/{org}/repos`.

**Tech Stack:** GitHub Actions, bash, curl, jq, GitLab REST v4, Gitee REST v5.

## Global Constraints

- Organization repos are **public-only**: list with `type: public` and skip `private`, `fork`, and `archived`.
- Personal repos keep current behavior, including private.
- Target mapping is 1:1: `github.com/{owner}/{name}` → `gitlab.com/{owner}/{name}` and `gitee.com/{owner}/{name}`.
- GitLab group `ArkGravity` and Gitee org `ArkGravity` already exist; do not auto-create groups/orgs. Fail with a clear error if the namespace is missing.
- Continue using the existing personal Fine-grained `GH_TOKEN`. Do not add `GH_ORG_TOKEN`.
- Gitee `GIT_ASKPASS` username is the personal Gitee login (`github.repository_owner`), never the org name.
- Reuse existing scripts; no new workflow file.
- Do not commit unless the user explicitly asks.

## File Structure

- Create: `.github/scripts/endpoints.sh` — pure helpers (Gitee create URL).
- Create: `.github/scripts/endpoints_test.sh` — unit tests for those helpers.
- Modify: `.github/scripts/sync-gitlab.sh` — resolve GitLab `namespace_id` on create.
- Modify: `.github/scripts/sync-gitee.sh` — org create endpoint + personal git user.
- Modify: `.github/workflows/sync-repos.yml` — list org public repos; pass `owner` and `GITEE_USERNAME`.
- Modify: `README.md` — document `SYNC_ORGS` and 1:1 org sync.
- Unchanged: `.github/scripts/mirror-clone-github.sh` (already clones `${OWNER}/${REPO}`).

---

### Task 1: Gitee create-endpoint helper

**Files:**
- Create: `.github/scripts/endpoints.sh`
- Create: `.github/scripts/endpoints_test.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `gitee_create_endpoint(owner, git_user)` prints the Gitee POST URL. Personal when `owner == git_user`; otherwise org.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# .github/scripts/endpoints_test.sh
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash .github/scripts/endpoints_test.sh`

Expected: FAIL because `endpoints.sh` / `gitee_create_endpoint` does not exist (`source: No such file or directory` or `command not found`).

- [ ] **Step 3: Write minimal implementation**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash .github/scripts/endpoints_test.sh`

Expected: `endpoints_test.sh: ok`

---

### Task 2: Create GitLab projects under the owner namespace

**Files:**
- Modify: `.github/scripts/sync-gitlab.sh`

**Interfaces:**
- Consumes: existing env `GITLAB_TOKEN`, `OWNER`, `REPO`, `PRIVATE`, `DEFAULT_BRANCH`, `DESC`
- Produces: on 404, `POST /api/v4/projects` with `namespace_id` from `GET /api/v4/namespaces/{OWNER}` so org repos land in group `ArkGravity` instead of the token user's personal namespace.

- [ ] **Step 1: Replace the 404-create block so it resolves namespace_id**

Current create payload (lines 24–35) has no `namespace_id`, so GitLab always creates under the token user.

Replace the `if [ "$status" = "404" ]; then` block with:

```bash
if [ "$status" = "404" ]; then
  visibility=$([ "$PRIVATE" = "true" ] && echo private || echo public)
  ns_file="$(mktemp)"
  ns_status=$(curl -s --retry 3 --retry-delay 5 -o "$ns_file" -w "%{http_code}" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "https://gitlab.com/api/v4/namespaces/${OWNER}")
  if [ "$ns_status" != "200" ]; then
    echo "::error::GitLab namespace ${OWNER} not found (HTTP ${ns_status}). Create the group first."
    rm -f "$ns_file"
    exit 1
  fi
  ns_id=$(jq -r '.id // empty' "$ns_file")
  rm -f "$ns_file"
  if [ -z "$ns_id" ]; then
    echo "::error::GitLab namespace ${OWNER} response had no id"
    exit 1
  fi
  payload=$(jq -n \
    --arg name "$REPO" --arg desc "$DESC" \
    --arg vis "$visibility" --arg branch "$DEFAULT_BRANCH" \
    --argjson ns "$ns_id" \
    '{name: $name, path: $name, description: $desc, visibility: $vis, default_branch: $branch, namespace_id: $ns}')
  curl -sSf -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://gitlab.com/api/v4/projects" > /dev/null
  echo "Created GitLab project ${OWNER}/${REPO}"
```

Leave the existing `elif` / mirror-push unchanged. `encoded` and `url` already use `${OWNER}/${REPO}`.

- [ ] **Step 2: Syntax-check**

Run: `bash -n .github/scripts/sync-gitlab.sh`

Expected: exit 0, no output.

---

### Task 3: Gitee org create + personal git username

**Files:**
- Modify: `.github/scripts/sync-gitee.sh`

**Interfaces:**
- Consumes: `gitee_create_endpoint` from `.github/scripts/endpoints.sh`; new required env `GITEE_USERNAME` (personal Gitee login); existing `OWNER` (GitHub owner path, may be an org).
- Produces: create via `/user/repos` or `/orgs/{org}/repos`; ASKPASS username is always `GITEE_USERNAME`.

- [ ] **Step 1: Source helpers, require GITEE_USERNAME, stop using OWNER as git user**

After the existing `: "${DEFAULT_BRANCH:?...}"` block add:

```bash
: "${GITEE_USERNAME:?GITEE_USERNAME is required}"
# shellcheck source=endpoints.sh
source "$(cd "$(dirname "$0")" && pwd)/endpoints.sh"
```

Replace:

```bash
export GITEE_GIT_USER="$OWNER"
```

with:

```bash
export GITEE_GIT_USER="$GITEE_USERNAME"
```

Replace the create `curl` URL `"https://gitee.com/api/v5/user/repos"` with:

```bash
  create_url="$(gitee_create_endpoint "$OWNER" "$GITEE_USERNAME")"
  curl -sSf -X POST \
    -H "Authorization: token $GITEE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$create_url" > /dev/null
```

Keep GET/PATCH/push URLs as `https://gitee.com/${OWNER}/${REPO}` so org repos stay under the org path.

- [ ] **Step 2: Syntax-check and unit tests**

Run:

```bash
bash -n .github/scripts/sync-gitee.sh
bash .github/scripts/endpoints_test.sh
```

Expected: both exit 0; `endpoints_test.sh: ok`.

---

### Task 4: List org public repos and pass owner through the matrix

**Files:**
- Modify: `.github/workflows/sync-repos.yml`

**Interfaces:**
- Consumes: workflow env `SYNC_ORGS` (comma/space-separated GitHub org logins). First value: `ArkGravity`.
- Produces: matrix items `{owner, name, private, description, default_branch}`. Sync steps set `OWNER` from `matrix.repo.owner` and `GITEE_USERNAME` from `github.repository_owner`.

- [ ] **Step 1: Add SYNC_ORGS and rewrite list_repos**

Add at the workflow root (after `permissions:`):

```yaml
env:
  SYNC_ORGS: ArkGravity
```

Replace the `github-script` `script:` block with:

```javascript
            const toRepo = (r) => ({
              owner: r.owner.login,
              name: r.name,
              private: r.private,
              // 100 chars keeps the matrix outputs well under the 1MB job-output cap
              // even when the user has hundreds of repos.
              description: (r.description || '').slice(0, 100),
              default_branch: r.default_branch,
            });
            const personal = (
              await github.paginate(
                github.rest.repos.listForAuthenticatedUser,
                { per_page: 100, affiliation: 'owner', sort: 'full_name' }
              )
            )
              .filter((r) => !r.fork && !r.archived)
              .map(toRepo);

            const orgRepos = [];
            const orgs = (process.env.SYNC_ORGS || '')
              .split(/[\s,]+/)
              .filter(Boolean);
            for (const org of orgs) {
              const listed = await github.paginate(
                github.rest.repos.listForOrg,
                { org, per_page: 100, type: 'public' }
              );
              orgRepos.push(
                ...listed
                  .filter((r) => !r.fork && !r.archived && !r.private)
                  .map(toRepo)
              );
            }

            const repos = [...personal, ...orgRepos];
            core.setOutput('repos', JSON.stringify(repos));
            core.setOutput('count', String(repos.length));
            await core.summary
              .addHeading(`Syncing ${repos.length} repositories`)
              .addList(
                repos.map(
                  (r) =>
                    `${r.owner}/${r.name}${r.private ? ' (private)' : ''}`
                )
              )
              .write();
```

Pass `SYNC_ORGS` into the script step (`github-script` does not inherit job `env` unless specified). Add under that step's `with:` sibling, i.e. on the step:

```yaml
        env:
          SYNC_ORGS: ${{ env.SYNC_ORGS }}
```

So the list step becomes:

```yaml
      - name: List owned and org repositories
        id: list
        # actions/github-script@v9
        uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3
        env:
          SYNC_ORGS: ${{ env.SYNC_ORGS }}
        with:
          github-token: ${{ secrets.GH_TOKEN }}
          script: |
            ...
```

- [ ] **Step 2: Point clone/sync OWNER at matrix.repo.owner**

Replace all three `OWNER: ${{ github.repository_owner }}` assignments in the `sync` job with:

```yaml
          OWNER: ${{ matrix.repo.owner }}
```

On the Gitee step only, add:

```yaml
          GITEE_USERNAME: ${{ github.repository_owner }}
```

Final Gitee step env:

```yaml
        env:
          GITEE_TOKEN: ${{ secrets.GITEE_TOKEN }}
          GITEE_USERNAME: ${{ github.repository_owner }}
          OWNER: ${{ matrix.repo.owner }}
          REPO: ${{ matrix.repo.name }}
          DESC: ${{ matrix.repo.description }}
          PRIVATE: ${{ matrix.repo.private }}
          DEFAULT_BRANCH: ${{ matrix.repo.default_branch }}
```

- [ ] **Step 3: Confirm mirror-clone needs no code change**

`.github/scripts/mirror-clone-github.sh` already clones `https://github.com/${OWNER}/${REPO}.git`. After Step 2, org repos clone from `github.com/ArkGravity/...`.

---

### Task 5: Document org public sync

**Files:**
- Modify: `README.md` (Required secrets table and a short note under Automation)

- [ ] **Step 1: Update GH_TOKEN / GitLab / Gitee rows and mention SYNC_ORGS**

Replace the Required secrets table and add one sentence after it:

```markdown
### Required secrets

| Secret | Used by | Minimum access |
|--------|---------|----------------|
| `GH_TOKEN` | Sync | Fine-grained or classic PAT: list/clone owned repos. Fine-grained tokens also have read-only access to public repos, including allowlisted orgs (`SYNC_ORGS`, currently `ArkGravity`). |
| `METRICS_TOKEN` | Metrics (optional) | **Classic** PAT only (`repo` scope). Metrics uses GitHub GraphQL, which rejects fine-grained tokens. If unset, falls back to `GITHUB_TOKEN` (current-repo stats only). |
| `GITLAB_TOKEN` | Sync | `api` scope (create/update projects + git push). Personal GitLab username should match the GitHub login. Org repos are created under the matching GitLab group (already created). |
| `GITEE_TOKEN` | Sync | Private token with repo create/push. Personal Gitee username should match the GitHub login. Org repos are created under the matching Gitee org (already created). |

Sync copies GitHub `owner/name` 1:1 to GitLab and Gitee. Personal private repos are included; organization repos in `SYNC_ORGS` are public-only.
```

---

### Task 6: Verify locally

**Files:** none new

- [ ] **Step 1: Syntax-check all sync scripts**

Run:

```bash
bash -n .github/scripts/endpoints.sh
bash -n .github/scripts/endpoints_test.sh
bash -n .github/scripts/mirror-clone-github.sh
bash -n .github/scripts/sync-gitlab.sh
bash -n .github/scripts/sync-gitee.sh
bash .github/scripts/endpoints_test.sh
```

Expected: all `bash -n` silent exit 0; last line `endpoints_test.sh: ok`.

- [ ] **Step 2: Confirm workflow YAML still has a single matrix owner field**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
text = Path('.github/workflows/sync-repos.yml').read_text()
assert 'SYNC_ORGS: ArkGravity' in text
assert 'matrix.repo.owner' in text
assert 'listForOrg' in text
assert 'GITEE_USERNAME' in text
assert 'github.repository_owner' in text  # still used for Gitee login
print('workflow markers: ok')
PY
```

Expected: `workflow markers: ok`

- [ ] **Step 3: Do not commit** unless the user asks. Working tree should show the files listed in File Structure.

---

## Self-review

1. Spec coverage: 1:1 owner mapping (Tasks 2–4), public-only org listing (Task 4), single personal `GH_TOKEN` (Task 4/5), Gitee personal git user (Task 3), GitLab group `namespace_id` (Task 2), README (Task 5), local verify (Task 6).
2. Placeholders: none.
3. Names: `gitee_create_endpoint`, `SYNC_ORGS`, `GITEE_USERNAME`, `matrix.repo.owner` are consistent across tasks.
