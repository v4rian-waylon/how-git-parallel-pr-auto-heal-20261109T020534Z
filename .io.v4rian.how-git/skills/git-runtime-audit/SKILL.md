---
name: git-runtime-audit
description: Boot/launch verification after every feature merge into dev and after dev merge into main, per repo. Confirms the build actually loads and initializes its runtime stack; catches the EADDRINUSE / missing-module / ungitignored-file / drift-from-package-lock / unsigned-binary class of issues that compile-only checks miss. Also runs from a fresh clone of origin/main to confirm deployability. Project-agnostic - repo type and init markers inferred from the workspace's CLAUDE.md or from a file probe. Invoke from git-snapshots Steps 4 and 5; can run standalone against any branch tip.
---

# git-runtime-audit - boot and launch verification

**Runs in CI:** `ci/audits/push/required.runtime.sh`; `ci-dispatch.yml` runs it on every push (on demand: `.github/workflows/audit-pushed-branch.yml`; off-grid: `bin/ci-local --workflow audit-pushed-branch`). The boot lens below is the reference for that script and for local diagnostic runs.

Compile passing is necessary but not sufficient. A binary or service can compile and still:

- Fail to bind its port (`EADDRINUSE`, missing port config).
- Fail to resolve runtime imports (missing module not in `node_modules`; broken `package-lock.json` drift).
- Crash on first method call due to type or signature drift between adjacent libs.
- Refuse to run because the binary isn't signed or codesign attributes are wrong (macOS/iOS).
- Hit a missing env var or config file the build didn't surface.
- Hang indefinitely waiting on a downstream service.
- Print no init markers because the underlying entrypoint was renamed.

The runtime audit catches these classes. It is invoked per (zip × repo) after every feature merge into `dev` AND after `dev` merge into `main`, AND from a fresh clone of origin/main to verify deployability.

## Repo type detection (in order)

For each repo, determine its type:

1. **Workspace CLAUDE.md hint**: if `<workspace>/CLAUDE.md` or `<workspace>/<repo>/CLAUDE.md` declares a type, an entry-point command, a build command, or expected init markers, use those verbatim. The workspace's CLAUDE.md is authoritative.
2. **Heuristic by file presence**, in this order:
   - `package.json` present → Node project. If `"bin"` field exists → CLI. If main starts a server (look for `listen`, `createServer`, `WebSocketServer`, etc. via grep of the entry file) → service.
   - `CMakeLists.txt` present → C/C++ via CMake. If the file contains `qt_add_executable` or builds an `.app` bundle target → Qt app. Else if it builds a `STATIC` library target → static lib. Else → C/C++ executable.
   - `Cargo.toml` → Rust. Inspect `[[bin]]` / `[lib]` to decide binary vs lib.
   - `go.mod` → Go. `cmd/<name>/main.go` indicates a binary entry.
   - `pyproject.toml` or `requirements.txt` → Python. Look for an entry under `[project.scripts]` or a `__main__.py`.
   - `Makefile` only → generic; read `make help` if present.
   - Otherwise → ask the workspace CLAUDE.md to declare, or fail loudly if unclear.
3. **Single explicit ask** via `AskUserQuestion` only if both 1 and 2 fail and the workspace has multiple unknown-type repos. Otherwise default to "compile-only verification" (no runtime probe).

The detection result, once established for a repo, is remembered for the rest of the session.

## Check matrix

| Type | Build step | Runtime step | Pass criterion |
|---|---|---|---|
| Node service | `npm install --silent` + `node --check` per JS file outside `node_modules/build` | `node <entry> & sleep <N> && kill -KILL $PID` | process stayed alive for N seconds; init markers present; no fatal error lines |
| Node CLI | `npm install` + `node --check` | `node <bin> --help` or `npm run <cmd>` with `--dry-run` | exit code 0; usage printed |
| Qt static lib | `cmake -S . -B build -G Ninja && cmake --build build --parallel` | (none - lib has no runtime) | `lib<Name>.a` and any QML plugin lib emitted |
| Qt app (macOS) | cmake build | `open build/<X>.app && sleep 3 && pgrep -f <X> && pkill -KILL -f <X>` | PID surfaced after `open`; killed cleanly |
| Qt app (Linux) | cmake build | `./build/<X> & sleep 3 && kill -KILL $!` | process stayed alive; window appeared (if X11 available) |
| Rust binary | `cargo build --release` | `./target/release/<bin> --help` or `cargo run -- <args>` brief | exit code 0; expected stdout |
| Rust lib | `cargo build` | (no runtime) | `target/.../lib<name>.rlib` emitted |
| Go service | `go build ./...` | `./<binary> & sleep 4 && kill` | process stayed alive; bound expected port |
| Go CLI | `go build ./...` | `./<binary> --help` | exit code 0 |
| Python service | `pip install -r requirements.txt` (in venv) + `python -m py_compile <files>` | `python <entry> & sleep 4 && kill` | listen lines |
| Generic | per workspace CLAUDE.md hint | per workspace CLAUDE.md hint | per workspace CLAUDE.md hint |

## Init markers

The runtime check looks for evidence that the service entered its steady-state init. "Init markers" are short stdout/stderr strings that indicate readiness - typically the line printed right after binding a port or finishing service registration.

### How to determine init markers

The workspace's `CLAUDE.md` should declare them. Example declaration:

```
## Init markers
- cmna: `HTTP on 0.0.0.0:<PORT>`, `WS on 0.0.0.0:<PORT>`, `BookingService initialized`
- website: `Server listening on <PORT>`
- cli-tool: `usage: cli-tool [options]`
```

If the workspace doesn't declare them:

- **Default pass**: the process stays alive for the timeout window AND no `Error`, `EADDRINUSE`, `ENOMODULE`, `ImportError`, `Traceback`, `panic:`, `Segmentation fault`, `Killed` lines appear in captured output.
- **Default fail**: the process exits with non-zero before the timeout, OR any of the fatal markers above appear.

### Tolerable error markers (don't fail on these)

Some "errors" are environmental and don't represent a true regression:

- `Could not load Application Default Credentials` / missing OAuth tokens (expected in non-prod env).
- `Connection refused` / `getaddrinfo ENOTFOUND` for downstream services not present in the check env (e.g., the local cmna isn't running when website tries to connect; flagged as `PENDING`, not `FAIL`).
- `invalid_grant`, `invalid_rapt` and similar GCP auth errors when running outside a service account context.

Declare these tolerances in the workspace's `CLAUDE.md` so the runtime audit knows to ignore them.

## Detailed procedures

### Node service

```bash
cd "<workspace>/<repo>"
npm install --silent --no-audit --no-fund

# Syntax check every JS file outside node_modules + build
find . -name '*.js' \
     -not -path './node_modules/*' \
     -not -path './build*' \
     -print0 \
  | xargs -0 -I{} node --check {}

# Boot test
ENTRY=$(node -e "console.log(require('./package.json').main || 'index.js')" 2>/dev/null)
[ -z "$ENTRY" ] && ENTRY="main.js"
[ ! -f "$ENTRY" ] && ENTRY="src/server.js"
[ ! -f "$ENTRY" ] && { echo "no entry found"; exit 1; }

LOG=$(mktemp)
node "$ENTRY" > "$LOG" 2>&1 &
PID=$!
sleep 5
if ! kill -0 "$PID" 2>/dev/null; then
  echo "FAIL: process exited before timeout"
  cat "$LOG" | tail -20
  exit 1
fi
kill -KILL "$PID"

# Verify init markers (substitute the workspace's declared markers)
if grep -qE 'HTTP|Server|WebSocket|Listening|Initialized|Connected|listening' "$LOG"; then
  echo "PASS"
else
  echo "FAIL: no init markers"
  tail -20 "$LOG"
  exit 1
fi
```

### Qt static lib

```bash
cd "<workspace>/<repo>"
rm -rf build
cmake -S . -B build -G Ninja || { echo "configure FAIL"; exit 1; }
cmake --build build --parallel || { echo "build FAIL"; exit 1; }

# Verify a static lib was emitted
LIB=$(find build -name 'lib*.a' | head -1)
[ -n "$LIB" ] && echo "PASS: $LIB" || { echo "FAIL: no lib emitted"; exit 1; }
```

For libs with adjacent-path deps (`add_subdirectory(../<other-lib>)`): the adjacent libs must be present at the workspace tree's expected layout. See `git-compile-audit` § Qt apps for matching-date preflight resolution.

### Qt app (macOS)

```bash
cd "<workspace>/<repo>"
rm -rf build
cmake -S . -B build -G Ninja || { echo "configure FAIL"; exit 1; }
cmake --build build --parallel || { echo "build FAIL"; exit 1; }

APP=$(ls -d build/*.app 2>/dev/null | head -1)
[ -z "$APP" ] && { echo "FAIL: no .app bundle"; exit 1; }
NAME=$(basename "$APP" .app)

# Codesign sanity (catches unsigned binary issues)
codesign -dvv "$APP" 2>&1 | grep -E '^Identifier=|^Signature=' | head -3

# Launch and confirm process surface
open "$APP"
sleep 3
if pgrep -f "$NAME" > /dev/null; then
  pkill -KILL -f "$NAME"
  echo "PASS: $NAME launched (PID surfaced)"
else
  echo "FAIL: $NAME did not surface a process"
  # macOS often suppresses launch errors; check Console.app for the LSApplicationLaunchProhibitedError
  exit 1
fi
```

### Qt app (Linux)

```bash
cd "<workspace>/<repo>"
rm -rf build
cmake -S . -B build -G Ninja
cmake --build build --parallel
BIN=$(find build -maxdepth 2 -type f -perm +111 ! -path '*/CMakeFiles/*' | head -1)
[ -z "$BIN" ] && { echo "FAIL: no executable"; exit 1; }
# Headless test (DISPLAY may be absent in CI)
QT_QPA_PLATFORM=offscreen "$BIN" &
PID=$!
sleep 3
if kill -0 "$PID" 2>/dev/null; then
  kill -KILL "$PID"
  echo "PASS: $BIN launched"
else
  echo "FAIL: process exited"
  exit 1
fi
```

### Rust / Go / Python / generic

Patterns above adapted to the tool. Always:
1. Build with the tool's release-equivalent.
2. Run with a brief timeout window.
3. Check exit code AND init markers AND fatal-error markers.

## Fresh-clone deployability check

After `[MERGE] dev into main` lands on origin, verify origin/main builds + runs from a clean clone:

```bash
SCRATCH=$(mktemp -d -t deploy-check)
cd "$SCRATCH"
git clone --depth 1 --branch main --single-branch <origin-url> "<repo>"
cd "<repo>"
# Run the type-specific check above
```

This catches:
- Files not staged but used at runtime (gitignored by accident, present locally but missing from origin).
- Stale `package-lock.json` that doesn't match the current dep tree.
- Absolute paths the build script depends on (won't exist in `$SCRATCH`).
- Missing submodules (`git clone` doesn't fetch them by default).
- Missing LFS objects.

The fresh-clone check is NOT optional - it's the final gate before declaring the merge "done".

## Per (zip × repo) ritual

After every feature merge into dev AND after dev merge into main:

1. Run the check appropriate to the repo type.
2. Capture init markers / build success / launch evidence as a log.
3. Save logs to a temp dir under `runtime/<repo>-<zip-date>.log`.
4. **Failure blocks pushing the merge** - invoke `git-snapshots` § Reversibility to roll back from safety snapshots; fix or split; re-attempt.

Log entries persist until the user confirms the rebuild result is acceptable, then ship via `deliver` if requested.

## Reproducibility considerations

### macOS-specific gotchas

- `open` returns immediately even if the .app failed to launch. Always confirm via `pgrep`.
- `pkill -KILL -f <name>` may match unintended processes; use the full app binary path when uncertain.
- Codesigned binaries may launch fine locally but fail on a fresh clone if the signing identity isn't reproduced.
- Notarization is not part of runtime audit - flag separately if the user needs it.

### Network-isolated checks

When the workspace is air-gapped or downstream services aren't reachable:

- Boot tests still verify the binary loads and binds local ports.
- Downstream `Connection refused` is tolerable.
- Document which markers are tolerable in workspace CLAUDE.md.

### Resource concurrency

When running multiple runtime checks in parallel:

- Each test must use a distinct port (or skip the bind step if testing only init).
- Each must use a distinct temp dir for logs.
- The `pgrep`/`pkill` patterns must distinguish the test's process from neighboring tests.

## Banned shortcuts

- Skipping the runtime check because "compile passed" - misses the entire class of issues this audit exists to catch.
- Skipping the fresh-clone check because "local build worked" - fails to catch `.gitignore` mistakes and absolute-path leaks.
- Running checks AFTER push instead of before - origin can move; check is meaningless.
- Suppressing `Error` markers as tolerable without declaring them in workspace CLAUDE.md.
- Running runtime checks against the working tree when fresh-clone is what's required (specifically for the post-merge gate).

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) - runtime-audit invoked in Steps 4 and 5.
- [`git-compile-audit`](../git-compile-audit/SKILL.md) - compile-only; runtime extends with boot/launch.
- [`git-coverage-audit`](../git-coverage-audit/SKILL.md) - coverage proves content; runtime proves behavior.
- [`deliver`](../deliver/SKILL.md) - for shipping runtime logs to the user as audit ledgers.
