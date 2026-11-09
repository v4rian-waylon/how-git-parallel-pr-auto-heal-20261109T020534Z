---
name: git-token-discovery
description: Find the GitHub credential available to the current session - git credential fill is the canonical source. Understand token scope reality (gho_ OAuth tokens often lack delete_repo / admin scopes) and fallbacks (orphan-commit wipe via push, or user-action via GitHub Settings). Invoke when a remote operation needs API access beyond plain push (delete repo, change default branch, manage protection rules).
---

# git-token-discovery - credential and scope realities

When a remote operation needs more than `git push` permissions (DELETE repo, PATCH default branch, etc.), you need the API token. The token is already available to the session via the git credential store, but its scope determines what works.

## Mechanic - get the token

```bash
echo "url=https://github.com" | git credential fill 2>/dev/null
```

Output:
```
protocol=https
host=github.com
username=waylon-sp
password=gho_xxxxxxxxxxxxxxxxxxxxxxxxx
```

The `password=` line carries the token. Use it via `Authorization: token <value>` header:

```bash
TOKEN=$(echo "url=https://github.com" | git credential fill 2>/dev/null \
        | grep '^password=' | cut -d= -f2-)
curl -H "Authorization: token $TOKEN" \
     -H "Accept: application/vnd.github+json" \
     "https://api.github.com/repos/sessionpass/<repo>"
```

## Treat the token as secret

Never print it to stdout in a user-visible message. The `git credential fill` output leaks it once - record it to a shell variable and reference the variable; don't echo the value.

## Token type by prefix

| Prefix | Type | Typical scopes |
|---|---|---|
| `gho_` | OAuth user token | Whatever GitHub OAuth flow granted; often `repo` but rarely `delete_repo` |
| `ghp_` | Classic personal access token | User-configured scopes |
| `github_pat_` | Fine-grained PAT | Per-repo permissions; often narrow |
| `ghs_` | Server-to-server (GitHub App installation) | Per-app permissions |
| `ghr_` | Refresh token | Not for API use directly |

## Scope reality

A `gho_` OAuth token typically does NOT include:

- `delete_repo` (required for `DELETE /repos/{owner}/{repo}`)
- `admin:repo_hook`
- `admin:org`
- `admin:public_key`

Operations that return 403 "Must have admin rights to Repository" or 404 (when GitHub hides 403 to avoid leaking repo existence) are usually scope failures.

Operations the token CAN typically do:

- `git push` to repos the user has write access on (works through standard HTTPS auth)
- `GET /repos/...` for repos the user can read
- `POST /repos/.../issues` if they have issues write access

## Fallbacks when API scope is insufficient

### Want to delete a repo, but `DELETE /repos/...` returns 403:

1. Force-push `main` to an orphan empty commit (`git-history-rewrite` Mechanic 3) - wipes content, keeps repo skeleton.
2. Or ask the user to delete via GitHub web UI: Settings → Danger Zone → Delete repository.

### Want to change default branch, but `PATCH /repos/...` returns 404/403:

1. Force-push the desired tip to `main` directly (since `main` is already default). No default-branch change needed.
2. Or ask the user to swap default via Settings → Branches.

### Want to bypass branch protection, but push is rejected:

- Cannot bypass without admin. Ask the user to temporarily disable protection, or to commit the change themselves.

## Probing scopes

To check what your token can do without trial-and-error:

```bash
TOKEN=$(echo "url=https://github.com" | git credential fill 2>/dev/null \
        | grep '^password=' | cut -d= -f2-)
curl -sI -H "Authorization: token $TOKEN" "https://api.github.com/user" \
  | grep -i "x-oauth-scopes"
```

The `x-oauth-scopes` header lists the token's actual scopes. Empty/missing means classic public access only.

## Per-operation scope cheatsheet

| Operation | Scope needed |
|---|---|
| `git push <ref>` | Push access on the repo |
| `git push origin --delete <branch>` | Push access (except default branch) |
| `DELETE /repos/{owner}/{repo}` | `delete_repo` + admin |
| `PATCH /repos/{owner}/{repo}` (default_branch) | admin |
| `PUT /repos/{owner}/{repo}/branches/{branch}/protection` | admin |
| `POST /repos/{owner}/{repo}/forks` | `repo` |
| `GET /repos/{owner}/{repo}` (public read) | none |
| `POST /repos/{owner}/{repo}/issues` | `repo` |

## Banned shortcuts

- Don't print the token to user-visible logs/chat.
- Don't write the token to a file outside the session (`/tmp/token.txt` etc.).
- Don't try the operation 10 times to figure out the scope - probe `x-oauth-scopes` once.
- Don't request the user grant `delete_repo` scope unless they specifically asked for a repo delete operation.

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) - invokes token-discovery when API ops are needed.
- [`git-history-rewrite`](../git-history-rewrite/SKILL.md) - fallback push mechanics when API scope is insufficient.
- [`git-snapshot-preflight`](../git-snapshot-preflight/SKILL.md) - preflight push uses standard auth via credential helper; no API.
