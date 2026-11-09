---
name: git-compile-audit
description: Compile-only verification per (zip × repo). Node services run npm install + node --check; Qt libs run cmake build of static lib target; Qt apps run cmake build of app target, with adjacent lib clones resolved to the latest preflight whose date is ≤ the zip's date for historical accuracy. Invoke from git-snapshots steps 4 and 5; complements git-runtime-audit.
---

# git-compile-audit - compile-only verification

**Runs in CI:** `ci/audits/push/required.compile.sh`; `ci-dispatch.yml` runs it on every push (on demand: `.github/workflows/audit-pushed-branch.yml`; off-grid: `bin/ci-local --workflow audit-pushed-branch`). The recipes below are the reference for that script and for local diagnostic runs.

Coverage proves the source content matches the zip. Compile proves the source parses + links. Runtime extends that with boot/launch. This skill is the compile layer specifically - no runtime side effects, no process launches.

## Repo type → compile recipe

### Node services (cmna, cloud-site, website)

```bash
cd <repo>
npm install --silent --no-audit --no-fund
# Walk every JS outside node_modules/build, run node --check
find . -name '*.js' -not -path './node_modules/*' -not -path './build*' -print0 \
  | xargs -0 -I{} node --check {}
```

Pass criterion: every staged JS parses; `npm install` resolves the dependency tree.

### Qt static libs (native-base, native-auth, native-ui)

```bash
cd <repo>
rm -rf build
cmake -S . -B build -G Ninja
cmake --build build --parallel
ls build/lib<Name>.a       # static lib linked
ls build/<Name>/lib<Name>plugin.a    # QML module plugin linked
```

Pass criterion: cmake configure succeeds; ninja build emits the static lib + QML plugin lib.

### Qt apps (native-app, native-admin, native-guest)

Qt apps' CMakeLists uses `add_subdirectory(../native-base ...)` etc. - relative paths to adjacent lib repos. This means the app's compile environment needs all 3 lib repos at adjacent paths.

**Historical accuracy rule**: when compiling the app at zip N's preflight, use the LATEST preflight of each lib repo whose date is ≤ zip N's date. This reproduces the lib surface at zip N's moment.

```python
# Pseudocode for adjacent-path setup
def setup_qt_app_workspace(app_repo, app_branch, zip_date):
    ws = tempfile.mkdtemp(prefix=f"compile-{app_repo}-{app_branch}-")  # under $TMPDIR
    # Clone the app at its preflight
    git_clone(f"--branch {app_branch} --single-branch",
              f"https://github.com/sessionpass/{app_repo}.git",
              f"{ws}/{app_repo}")
    # Clone each lib at its latest preflight ≤ zip_date
    for lib in ("native-base", "native-auth", "native-ui"):
        lib_branches = git_ls_remote_pf(lib)  # all preflight-bak-* on origin
        eligible = [b for b in lib_branches if branch_date(b) <= zip_date]
        latest = max(eligible)  # latest ≤ zip date
        git_clone(f"--branch {latest} --single-branch",
                  f"https://github.com/sessionpass/{lib}.git",
                  f"{ws}/{lib}")
    return ws
```

Then compile the app:

```bash
cd <ws>/<app_repo>
cmake -S . -B build -G Ninja
cmake --build build --parallel
ls build/*.app
```

Pass criterion: `<app>.app` bundle is emitted at `build/<Name>.app`.

## Per-zip-per-repo coverage

`git-snapshots` invokes compile-audit at:

- **Step 4** (after each `[MERGE] <working-branch> into dev`): compile the dev tip.
- **Step 5** (after `[MERGE] dev into main` at zip close): compile main tip.

Save build logs to `$WORK/<repo>-<zip-date>.log`, where `WORK=$(mktemp -d "${TMPDIR:-/tmp}/compile.XXXXXX")` is made once per run. The log is the audit trail.

## Failure handling

- `cmake -S . -B build` failure: usually a CMakeLists path issue or a missing lib at adjacent path. Verify the lib preflight clones are correctly placed.
- `node --check` failure: syntax error in the staged file. Investigate which atomic commit introduced it; amend.
- `npm install` failure: missing dep in `package.json`, or a corrupted `package-lock.json`. Compare with the zip's `package-lock.json`.
- Qt app `cmake --build` failure: usually an API drift between the app and its lib deps. Confirm you picked the right preflight date for each lib.

## Parallelism

Compile checks can run 4-way parallel via `ThreadPoolExecutor`. Each Qt build is ~1-3 min; each Node check is ~30-60 sec. With 4 workers and 119 (zip × repo) pairs, a full chain compile sweep is ~90-120 min.

```python
from concurrent.futures import ThreadPoolExecutor, as_completed

def compile_one(repo, branch, zip_date):
    if repo in NODE_SERVICES:
        return check_node(repo, branch)
    elif repo in QT_LIBS:
        return check_qt_lib(repo, branch)
    elif repo in QT_APPS:
        ws = setup_qt_app_workspace(repo, branch, zip_date)
        return check_qt_app(ws, repo)

with ThreadPoolExecutor(max_workers=4) as ex:
    futures = {ex.submit(compile_one, r, b, d): (r, b)
               for (r, b, d) in inventory}
    for fut in as_completed(futures):
        ...
```

## Banned shortcuts

- Compiling Qt apps without adjacent lib repos at the matching-date preflight - produces inaccurate "what did this look like at this zip" data.
- Skipping `npm install` because `node_modules` happens to be on disk - the install step verifies `package-lock.json` is consistent.
- Treating cmake warnings as failures (or vice versa) - only `cmake --build` returncode matters.

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) - invokes compile-audit in steps 4 and 5.
- [`git-runtime-audit`](../git-runtime-audit/SKILL.md) - runtime extends compile with boot/launch.
- [`git-coverage-audit`](../git-coverage-audit/SKILL.md) - coverage proves content; compile proves it parses.
- [`git-snapshot-preflight`](../git-snapshot-preflight/SKILL.md) - Qt apps' adjacent-path resolution depends on lib preflight branches being present on origin.
