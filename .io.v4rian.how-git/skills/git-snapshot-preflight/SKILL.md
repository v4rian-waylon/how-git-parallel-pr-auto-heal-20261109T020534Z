---
name: git-snapshot-preflight
description: Build and push the offsite security backup of each zip's content per affected repo BEFORE any rebuild processing begins. One preflight per zip × repo. Branch name preflight-bak-YYYY-MM-DD/NN. Sensitive files excluded. Push to origin first. Never delete, never rewrite, never force-push against. Project-agnostic - operates on the scope established by git-snapshots Step 0.
---

# git-snapshot-preflight - pre-flight offsite security backup

`preflight-bak-YYYY-MM-DD/NN` branches are **offsite security backups** of each bak zip's content per affected repo. Pre-flight literally - these go up before any rebuild flight takes off.

## Invariants (ALL non-negotiable)

1. **One preflight branch per (zip × repo).** If a zip touches 5 repos, that's 5 preflight branches with the same date suffix.
2. **Branch name**: `preflight-bak-YYYY-MM-DD/NN` where date is the zip's mtime and NN a two-digit sequence from 01: `preflight-bak-2026-04-10/01`, `preflight-bak-2026-04-10/02`. NN is GLOBAL across zips on that date (not per-repo) so the same NN maps to the same zip across repos. It is the only backup shape `pre-push` accepts, the one `~/.claude/hooks/git-preflight.sh` writes.
3. **Commit title**: `[NEW] WIP snapshot YYYY-MM-DD`.
4. **Commit author + committer date**: the zip's mtime (`stat -f '%m' <zip>` on macOS; `stat -c '%Y' <zip>` on Linux) → ISO 8601 with the source's real offset (local zone at that instant); the branch and zip names stay UTC `Z`.
5. **Commit identity**: `eval "$(.io.v4rian.how-git/bin/identity --export)"` (the origin's org, per `docs/Git_Strategy.md`), or the user's own for rebuilds of the user's snapshots; never `git config user.*` or the global identity, never hardcoded.
6. **Tree content**: the repo's full content from the zip, with sensitive files excluded.
7. **Orphan commit**: no parent. Each preflight is a standalone snapshot.
8. **Push to origin FIRST**, before any rebuild commit on `main` or `dev`.
9. **Never delete** the branch on origin after push.
10. **Never rewrite** its SHA. Never force-push against it.
11. **Never `git filter-branch -- --all`** - it rewrites preflight too. Enumerate refs explicitly: `-- main dev pool/n3.feature.x pool/n4.fix.y`.

## Forbidden content (excluded from the preflight tree)

Sensitive material must never travel offsite via preflight:

- `.git/`, `__MACOSX/`, `.DS_Store`, `**/.DS_Store`
- `.auth/`, `keys/`, `*.p8`, `*.p12`, `*.cer`, `*.pem`, `*.provisionprofile`, `*.mobileprovision`
- `node_modules/`, `.env`, `build/`, `build-*/`, `exports/`, `*.zip`
- Anything project-specific the workspace's `CLAUDE.md` flags as forbidden

If a `.auth/` or credential file makes it into a preflight, the security backup becomes a credential leak. The exclusion list is non-negotiable.

## Parallel build pattern

NEVER build preflights inside the user's main working repo dir - risk of disturbing live state. Always work in a scratch dir.

### Path resolution (no defaults, no hardcoded paths)

- **`WORKSPACE`** - provided by `git-snapshots` Step 0 (inferred from conversation or asked once). The skill does not assume any directory.
- **`SCRATCH`** - a temp dir for the parallel build. Resolve via `tempfile.mkdtemp(prefix='preflights-')` (Python) or `mktemp -d -t preflights` (shell). Do not hardcode `/tmp/preflights`.
- **`REPOS`** - the in-scope repo list from `git-snapshots` Step 0.

```python
import os, time, zipfile, subprocess, shutil, tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed

# Scope provided by git-snapshots Step 0 - no defaults
WORKSPACE = ...             # inferred or asked
SCRATCH = tempfile.mkdtemp(prefix="preflights-")
REPOS = (...)               # tuple of in-scope repo names from Step 0

EXCLUDE_DIRS = {'.git', '__MACOSX', '.DS_Store', '.auth', 'keys',
                'node_modules', '.env', 'build', 'exports'}
EXCLUDE_GLOBS = ('.p8', '.p12', '.cer', '.pem', '.provisionprofile',
                 '.mobileprovision', '.zip')

def should_skip(in_repo_path):
    parts = in_repo_path.split('/')
    for p in parts:
        if p in EXCLUDE_DIRS: return True
        if p.startswith('build-'): return True
        if any(p.endswith(g) for g in EXCLUDE_GLOBS): return True
        if p == '.DS_Store': return True
    return False

def remote_url(repo):
    # Read from the working repo's existing remote
    return subprocess.run(['git', '-C', f'{WORKSPACE}/{repo}',
                           'remote', 'get-url', 'origin'],
                          capture_output=True, text=True).stdout.strip()

def author_identity(repo):
    # Exported by the caller through bin/identity --export (rule 5).
    return os.environ['GIT_AUTHOR_NAME'], os.environ['GIT_AUTHOR_EMAIL']

def build_preflight(zip_path, repo, branch):
    clone_dir = f"{SCRATCH}/{repo}-{branch}"
    if os.path.exists(clone_dir): shutil.rmtree(clone_dir)
    subprocess.run(['git', 'clone', '-q', '--no-local',
                    f'{WORKSPACE}/{repo}', clone_dir], check=True)
    subprocess.run(['git', '-C', clone_dir, 'remote', 'set-url', 'origin',
                    remote_url(repo)], check=True)
    subprocess.run(['git', '-C', clone_dir, 'checkout', '--orphan', branch],
                  check=True)
    subprocess.run(['git', '-C', clone_dir, 'rm', '-rf', '.'],
                  capture_output=True)
    for e in os.listdir(clone_dir):
        if e != '.git':
            full = os.path.join(clone_dir, e)
            shutil.rmtree(full) if os.path.isdir(full) else os.remove(full)
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.namelist():
            if member.startswith('__MACOSX'): continue
            parts = member.split('/')
            repo_idx = next((i for i, p in enumerate(parts[:2]) if p == repo), None)
            if repo_idx is None: continue
            in_repo = '/'.join(parts[repo_idx+1:])
            if not in_repo or member.endswith('/'): continue
            if should_skip(in_repo): continue
            target = os.path.join(clone_dir, in_repo)
            if '/' in in_repo:
                os.makedirs(os.path.dirname(target), exist_ok=True)
            with zf.open(member) as src, open(target, 'wb') as dst:
                dst.write(src.read())
            info = zf.getinfo(member)
            mt = time.mktime(info.date_time + (0, 0, -1))
            os.utime(target, (mt, mt))
    subprocess.run(['git', '-C', clone_dir, 'add', '-A'], check=True)
    epoch = os.path.getmtime(zip_path)
    iso = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(epoch))  # source offset
    date_only = time.strftime("%Y-%m-%d", time.localtime(epoch))
    name, email = author_identity(repo)
    env = dict(os.environ)
    env.update({
        'GIT_AUTHOR_DATE': iso, 'GIT_COMMITTER_DATE': iso,
        'GIT_AUTHOR_NAME': name, 'GIT_AUTHOR_EMAIL': email,
        'GIT_COMMITTER_NAME': name, 'GIT_COMMITTER_EMAIL': email,
    })
    subprocess.run(['git', '-C', clone_dir, 'commit', '-m',
                    f'[NEW] WIP snapshot {date_only}'], env=env, check=True)
    subprocess.run(['git', '-C', clone_dir, 'push', '-q', 'origin', branch],
                  check=True)
    shutil.rmtree(clone_dir)
```

Dispatch with `ThreadPoolExecutor(max_workers=10)`.

## Verification ritual

After all preflights for zip N are pushed, confirm on origin:

```bash
for repo in <affected repos>; do
  origin_sha=$(git -C "<workspace>/$repo" ls-remote --heads origin "preflight-bak-<date>/<NN>" | awk '{print $1}')
  [ -n "$origin_sha" ] || echo "MISSING: $repo/preflight-bak-<date>/<NN>"
done
```

Only proceed to rebuild commits after every affected repo's preflight is confirmed on origin.

## Forbidden mechanics

- `git filter-branch -- --all` - rewrites preflight refs.
- `git push origin --all` - sweeps preflight along; never needed.
- `git push --force-with-lease origin preflight-bak-*` after initial push - never amend.
- Building preflights inside the main working repo dir.

## Recovery if accidentally deleted/rewritten locally

```bash
git fetch origin
git branch -f preflight-bak-YYYY-MM-DD/NN origin/preflight-bak-YYYY-MM-DD/NN
```

Origin is canonical (it was pushed FIRST). If origin is also missing, the only fallback is rebuild from the source zip - proves the rule "push to origin FIRST" was non-negotiable.

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) - orchestrator; preflight is Step 1.
- [`git-coverage-audit`](../git-coverage-audit/SKILL.md) - preflight content must match zip extract byte-for-byte.
- [`git-history-preservation`](../git-history-preservation/SKILL.md) - preflight is read-only after push; same discipline.
- [`git-token-discovery`](../git-token-discovery/SKILL.md) - if origin push requires credential injection.
