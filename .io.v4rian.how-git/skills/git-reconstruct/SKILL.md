---
name: git-reconstruct
description: Consolidate many separate source projects (zips, prior repos, loose drops) into one new modularized repo, replaying real commits where history exists and mtime-deriving it where not, never touching the originals; mechanics run through bin/reconstruct.
---

# git-reconstruct - multi-source consolidation rebuild

Third case beside [`git-snapshots`](../git-snapshots/SKILL.md) (one repo's own bak-zip chronology) and [`git-shuttle`](../git-shuttle/SKILL.md) (loose working-tree folders into an existing repo): content from MANY unrelated source projects is consolidated, renamed and reorganized into ONE new repo with a fresh module layout. The result must read as disciplined development of a real library, never as an import or archaeology exercise.

The lessons below come from a reference run that folded about twenty standalone libraries and apps into one namespaced library of a dozen modules, compiled and tested at every merge, including a second full pass after the first shipped with a commit that skipped its branch and several content leaks.

## The tool

`.io.v4rian.how-git/bin/reconstruct <subcommand>` runs every mechanical step (written `reconstruct` below); `--help` is the argument reference. It runs by absolute path from any directory.

| Step | Subcommand | Kind |
|---|---|---|
| 1 catalog scaffold | `scaffold <manifest.json> <target-dir>` | deterministic |
| 2 identity discovery | `identity <source-repo>` | deterministic |
| 3 naming normalization | `infer-rename <old-symbol> <catalog.json>` | claude |
| 3 reusability filter | `check-reusability <file>` | claude |
| 6 gap report | `gaps <manifest.json> <target-dir>` | deterministic |
| 7 fast-forward to a throwaway | `fast-forward <org>/<name> [--dry-run]` | deterministic |
| 8 structural self-audit | `audit-structure [repo] [--clone <url>] [--require <path>]...` | deterministic |
| 9 remnant sweep | `scrub <path> <term...>` | deterministic |
| 9 ambiguous hit review | `review-scrub-hit <file> <term>` | claude |
| 10, 11, local fixes | `preflight <repo> [reason]` | deterministic |
| 11 relocate to a subdirectory | `relocate <repo> <subdir>` | deterministic |
| 13 per-artifact verification | `verify-artifacts <manifest.json> [--all]` | deterministic |

The tool enforces, so this skill does not restate:

- `identity` lists every author and committer on every branch, tag and remote-tracking ref and on HEAD, verbatim, never merged or normalized.
- `audit-structure` exits 1 unless every pool branch landed on dev (nN, kind and short slug; a reconcile candidate stands in for its original), every dev merge carries a tag, DEV tags sit on merges and run 1..N per series without holes or doubles (`.0` seals exempt), README.md, `.gitignore` and every `--require` path exist, and local dev and tags match origin.
- `scrub` sweeps the whole repo, ignoring case: tracked content by file:line, every path any ref ever carried, every commit message by real SHA, every commit whose diff adds or removes the term, every ref name and every author or committer identity; any hit exits 1.
- `preflight` runs the machine's how-preflight hook when installed, so its backups are the ones the machine's destructive-git guard checks, and adds a bundle of every ref; without the hook it takes the same `preflight-bak-<day>/NN` ref and `<repo>-bak-<stamp>` zip and bundle itself and says where. A backup ref origin refuses fails it.
- `relocate` refuses a path that is not the root of a repo with its own `.git` directory (inherited `GIT_DIR` and linked worktrees included), dirty tracked files and any branch behind or diverged from origin, keeps unpushed commits, runs `preflight` first, runs git-filter-repo only from the verified root and exits 1 unless every branch and tag was rewritten to hold `<subdir>/` alone.
- `fast-forward` pushes dev, main, pool, feature, safety, vault and every tag in one atomic push through gh's credential helper (no token in `.git/config`) and reads every ref back before reporting ok.
- `verify-artifacts` builds every manifest entry and prints the failing command's output.
- The three claude subcommands cite this file and `Git_Strategy.md` by path, keep claude's stdout only and exit 1 unless the last line matches the one line contract (`RENAME:|QUESTION:`, `REUSABLE|EXCLUDE:`, `LEAK:|NOT-A-LEAK:`). `LIFECYCLE_TEST_MODE=1` gives canned answers offline.

## When this is the right skill

| Situation | Skill |
|---|---|
| One project's own chain of bak zips | `git-snapshots` |
| Loose working-tree folders reconciled into an existing repo | `git-shuttle` |
| **N unrelated sources consolidated into ONE new repo with a reorganized module layout** | **`git-reconstruct`** |
| A specific commit or diff applied across diverged forks | `git-reconcile-intent` |

What is unique here is the consolidation layer: what a class becomes in the new repo, whose identity it carries and how the module tree is shaped. Commit, merge, strategy, preservation and rewrite mechanics come from the skills under "Composes with".

## Non-negotiables

1. Never touch the originals. Every source is read-only input; all output goes to a throwaway target repo.
2. Preflight every source before processing it (`git-snapshot-preflight` per source).
3. Replay real commits (author, dates, message) where a source has history.
4. Derive dates from file mtimes where it does not, as `git-snapshots` does.
5. Compile and test at every commit and every merge (Step 5).
6. how-git spec on latest dev, one topic branch per module or topic, landed with a direct `--no-ff` merge into dev (no PR).
7. Do not stop until done: the mandate is completeness, not speed.

## Step 1 - Catalog the target shape first

Build the target module map (modules and, when the user supplied one, the expected classes) before opening any source. It is the spec being filled in; entries with no real source are documented (Step 6), never invented. `scaffold` creates the layout from the manifest:

```
<module>/
  include/<namespace>/<module>/*.h            flat modules
  include/<namespace>/<module>/<subarea>/*.h  sub-namespaces for larger modules
  src/*.cpp, src/<subarea>/*.cpp
  third_party/<lib>/                          only deps no package manager supplies
  CMakeLists.txt                              independently findable and buildable
```

Introduce sub-namespaces once a module holds more than three or four unrelated concerns.

## Step 2 - Per-source identity discovery

Never assume one identity for the whole reconstruction. Run `identity` per source. The reference run found three: one person behind one family of sources and their loose drops, the same person under a different name and email shape inside one repo (do not normalize it away), and a second person behind another family plus every commit authored live during the reconstruction.

Rule: a replayed commit carries whoever the source's history says; a reconstruction-authored commit (infra, wiring, a fix found today) carries whoever does that work today. Never blend them.

## Step 3 - Naming and namespace normalization

Sources disagree on names: some classes already carry the target's prefixed name, others live under a plain or different name but are catalogued under the prefixed one. Port the REAL logic, dates and authorship; rename only the identifier; never invent logic to complete a rename.

`infer-rename` handles the ambiguous mapping. A `QUESTION:` answer that stays unanswered after a genuine attempt is resolved on the strongest evidence and flagged explicitly in the final report.

**Reusability filter.** Before porting a class, `check-reusability` asks whether it hardcodes a backend URL, a product's user-agent, a tenant's cookie name or another single-consumer detail. If so, exclude it and say why. The reference run excluded a network client that hardcoded a host, user-agent and cookie name, and kept its genuinely generic persistence sibling.

**Historical bug, separate fix.** A real bug in the source is replayed faithfully with its historical date and author, then fixed in a separate `[FIX]` commit dated today under today's identity. Never fix it silently while porting.

## Step 4 - Build-system consolidation gotchas

Each surfaced as a real compile or link error in the reference run; `git-compile-audit` is what surfaces them.

- Self-registering static-lib objects (only a static initializer, no called symbol) get dropped by the linker: force the archive in for consumers (`-Wl,-force_load,$<TARGET_FILE:t>` on Apple, `--whole-archive ... --no-whole-archive` on Linux) as `INTERFACE` link options.
- Objective-C++ `@interface`/`@implementation` cannot sit inside a C++ namespace: close it, bridge with `using namespace <ns>;`, reopen.
- `-fobjc-arc` is per file: copy it only to files the source project compiled with ARC.
- Widget-toolkit classes may need the widgets component added explicitly.
- A header-only class that inlines third-party calls needs `PUBLIC` include dirs and link libs, not `PRIVATE`.
- A recursive header glob on a base target can pull a sub-target's header into the base AUTOMOC pass: glob non-recursively per sub-target.
- Bare `__has_include(<Header.h>)` in generated registration code needs the header's own directory in that file's `PRIVATE` include dirs.

## Step 5 - MWE verification at every commit and merge

A minimal working example, not a stub: real construction, real calls, real I/O where safe. One scratch `CMakeLists.txt` per module under test with `add_subdirectory` and one `mwe` executable. Anything that can hang runs in the background with a kill timer (`(./mwe & PID=$!; sleep N; kill -0 $PID && kill $PID)`; macOS has no `timeout`). Never trigger modal system UI (file panels, character pickers, blocking permission prompts); do exercise non-modal native resources with explicit cleanup. After the full consolidation, one integration `CMakeLists.txt` that adds every module as siblings proves there are no namespace collisions, duplicate targets or circular deps.

## Step 6 - Document gaps, never fill them

`gaps` lists catalogued classes with no source on disk. Report each (which class, what was searched) and do not create a module or class to satisfy the catalogue.

## Step 7 - Re-scope onto a fresh throwaway without redoing work

When a fresh target repo is cleaner than editing history in place, `fast-forward <org>/<new-name>` copies the working clone's refs verbatim (nothing rewritten, so `git-history-preservation` is not implicated). Clone the new repo fresh and continue there.

## Step 8 - Structural self-audit (mandatory)

A green suite cannot see a missing branch or an untagged merge: a commit that landed straight on dev builds byte-identical trees to one that went through a branch and merge. The reference run shipped exactly that, caught only by counting branches against tags. Run `audit-structure --clone <url>` after every push, adding `--require` for the target's MANUAL, LICENSE and build entry point; a working copy can hide a push gap behind local refs, so the fresh clone is the verdict.

If the repo's own convention puts even single-commit wiring steps on their own `pool/nN` branch (check a real merge's parents with `git log -1 --format=%P <merge>`), every commit meets that bar.

## Step 9 - Deep remnant scrub

Sources carry their old context: codenames, personal paths, internal-system references. Compiling and testing never see them. Feed `scrub` these categories:

1. Every prior project or zip codename from the source manifest.
2. Personal absolute paths (`/Users/<name>`, `/home/<name>`) of every prior author, especially in commented-out debug code.
3. Internal-system self-references: a header describing a class through its original consumer instead of its own behaviour.
4. Hardcoded self-identity strings, such as code excluding "itself" from a window or process list by a literal app name, now wrong inside a library.
5. Leftover codename directories, a signal that the same source contributed other files nearby: check all of them.

`review-scrub-hit` classifies a hit whose disposition is not obvious; the rewording in category 3 and the dynamic lookup in category 4 are judgment calls made there. Fix every category at the commit that introduced the content (Step 10), never in a later patch commit; a directory leak is fixed in the same origin commit by moving the file to its module's convention and updating include depths and CMake globs.

## Step 10 - A defect in published history: fix at the source, replay, never patch on top

- Unpushed: fix in place (see "Fixing unpushed local history").
- Pushed, reviewed or already the destination: never add a `[FIX]` commit after the merge. Fix the original commit at its origin point, replay the whole branch, merge and tag structure into a brand new throwaway from an empty orphan dev root (Step 16 keeps the merges), and pass Steps 5, 8 and 9 from an independent clone before and after pushing.

Fixing the original commit in isolation, in a scratch clone of the repo holding the real SHAs:

```bash
git checkout -q "$(git log -1 --format=%P <bad-sha>)"
git cherry-pick -n <bad-sha>                       # stage the change, do not commit
# apply the content fix, then git add <fixed-file>
GIT_AUTHOR_NAME="$(git log -1 --format=%an <bad-sha>)" GIT_AUTHOR_EMAIL="$(git log -1 --format=%ae <bad-sha>)" \
GIT_AUTHOR_DATE="$(git log -1 --format=%aI <bad-sha>)" GIT_COMMITTER_NAME="$(git log -1 --format=%cn <bad-sha>)" \
GIT_COMMITTER_EMAIL="$(git log -1 --format=%ce <bad-sha>)" GIT_COMMITTER_DATE="$(git log -1 --format=%cI <bad-sha>)" \
  git commit -m "$(git log -1 --format=%B <bad-sha>)"   # or the reworded message when the leak was in it
git branch fix-<n>-<short> HEAD                    # pin it for the replay plan
```

Carry any later commit that touched the same file forward onto the fix the same way, then point the replay plan at the new SHAs.

Publishing the verified throwaway over the destination rewrites published refs, so it goes through a preflight and a lease, never a bare force push:

```bash
reconstruct preflight <destination-clone> "replace <destination> with the verified rebuild"
expected=$(git -C <destination-clone> rev-parse origin/dev)    # what the destination holds now
git push --force-with-lease=refs/heads/dev:"$expected" <destination-url> refs/heads/dev:refs/heads/dev
```

Repeat the lease per rewritten ref the destination already holds (each pool branch and tag). `how-preflight` governs an authorised rewrite of published history and `git-history-rewrite` its mechanics.

## Step 11 - Relocate a finished history into a subdirectory

For a meta-repo destination (a `cpp/` subtree beside future `js/` and so on), run `relocate <repo> <subdir>` LAST, once Steps 8 to 10 pass on the standalone repo. git-filter-repo rewrites every branch and tag to nest content under `<subdir>/`, keeps every commit's identity, dates and merge topology, and removes `origin`. Rerun Step 8 afterwards.

## Step 12 - Distribution: consumers get binaries, never source

A private repo's Read permission cannot be split: whoever can download a Release asset can clone the source. So consumers are added to a separate private dist repo, never the source repo.

- One source repo (or the meta-repo subdirectory), maintainer-only.
- One dist repo; each release publishes one archive per module plus one combined archive on a single tag. Split into more dist repos only when different consumers must see different module subsets.
- `install(TARGETS ... EXPORT ...)` plus `install(EXPORT ...)` emits binaries, public headers and a relocatable `<Lib>Config.cmake` for `find_package(<Lib> CONFIG REQUIRED)`; check the shape against CMake's importing and exporting guide, not memory.
- Internal consumers with source access pull one module from the one source repo with `FetchContent_Declare(... GIT_TAG <tag> SOURCE_SUBDIR <module>)`, so per-module source repos are rarely worth it.
- A dev tag is an integration checkpoint, never a release. A release (build, `cmake --install`, package, publish) needs the user's explicit word and is verified by linking a throwaway consumer against the published archive.

## Step 13 - Verify every artifact, not a sample

The reference run's deploy script build-tested only the alphabetically first module per tag, so a broken later module never failed. `verify-artifacts` runs every manifest entry.

Inside the packaging, when B links A publicly, B's generated config must `find_dependency(A CONFIG)`; grep every `target_link_libraries(... PUBLIC ...)` for sibling targets and pass each through the install helper's dependency list.

## Step 14 - A build-tree linker trick breaks on export

A `$<TARGET_FILE:X>` inside `INTERFACE_LINK_OPTIONS` (the force-load from Step 4) is exported as literal text, so external consumers see a bare target name that does not exist. Split it with `$<BUILD_INTERFACE:...>` and `$<INSTALL_INTERFACE:-Wl,-force_load,$<INSTALL_PREFIX>/lib/lib<Target>.a>` (`$<INSTALL_PREFIX>` per `cmake --help-manual cmake-generator-expressions`). Prove it with an external consumer that depends on a static-initializer side effect and check its symbol table; a clean configure and link is not proof.

## Step 15 - Cherry-picks across layouts can land at the wrong path

Replaying a commit written against a prefixed layout (`cpp/...`) onto a throwaway without the prefix creates NEW files at the literal prefixed path with no conflict. After each cherry-pick that adds files, run `find . -path "*/<source-prefix>/*" -not -path "*/build/*" -not -path "*/.git/*"`; a clean status is not proof.

## Step 16 - Replays onto a fresh root must keep merge topology

`git rebase --onto <newroot> --root <branch>`, the replay Step 10 uses, linearizes and drops every content-free `--no-ff` merge, leaving `bin/version` nothing to count. Use `git rebase --rebase-merges --onto <newroot> --root <branch>`. A merge left empty after a path filter means its topic does not belong in this replay: cut before it.

`bin/version` with no flag previews the NEXT tag; `--seal` gives the tag an existing merge holds. It resolves `dev` and `main` (then `origin/dev`, `origin/main`) by name, so in a repurposed scratch clone check `git remote -v` first or it computes against the wrong repo.

## Anti-patterns

- One blended commit for a class with history in two sources: replay the deeper history; note the other source only for a real, verifiable difference.
- Naming a branch after its source (`pool/n4.feature.from-source-zip`) instead of the feature (`pool/n4.feature.audio-engine`).
- Treating "it compiles" or a green suite as proof: MWE must exercise the class and Step 8 must pass separately.
- Skipping the branch for a one-commit step when the repo's convention does not.
- Grepping file content only: the reference run found one leak duplicated in dead code and in that file's commit message.
- Describing a ported class through its original consumer instead of its own behaviour.
- `git fetch` with a custom refspec still auto-follows tags: use `--no-tags` when fetching a source only for its objects.
- `while IFS='|' read ...` scopes the custom IFS to the whole loop body: read the plan into an array first and iterate it outside that scope.
- Chaining flag combinations that "should" work without running them once against the real git binary.
- Replaying a topic the source later removed (added, then split out to its own repo): cut the replay before the removal merge.

## Composes with

- [`git-snapshots`](../git-snapshots/SKILL.md): its per-zip apply, verify and merge sequence runs per source once this skill has decided what the source becomes.
- [`git-snapshot-preflight`](../git-snapshot-preflight/SKILL.md): one preflight per source before processing.
- [`git-commit-audit`](../git-commit-audit/SKILL.md): every replayed or new commit; `[NEW]` only for genuinely new files or subsystems, not old code new to this repo.
- [`git-strategy-audit`](../git-strategy-audit/SKILL.md) and [`git-merge-audit`](../git-merge-audit/SKILL.md): one branch per module or topic, `--no-ff` merges into dev, no main for a dev-only reconstruction.
- [`git-compile-audit`](../git-compile-audit/SKILL.md), [`git-runtime-audit`](../git-runtime-audit/SKILL.md), [`git-coverage-audit`](../git-coverage-audit/SKILL.md): after every module merge.
- [`git-history-preservation`](../git-history-preservation/SKILL.md) and [`git-history-rewrite`](../git-history-rewrite/SKILL.md): in-place fixes only ever touch this reconstruction's own unpushed commits, never a source's replayed history.
- [`git-shuttle`](../git-shuttle/SKILL.md): a source that turns out to be a loose folder goes through its classification step.

## Fixing unpushed local history

A compile error found several commits after the commit that caused it is fixed in place, so the fix lands in the right topic. Only for this reconstruction's own commits that are not pushed or merged; once pushed, Step 10 applies.

```bash
reconstruct preflight . "fix <bad-sha> in place"   # prints preflight-bak-<day>/NN; its parent is the old tip
old_tip=$(git rev-parse "preflight-bak-<day>/NN^")
git reset --hard <bad-sha>
# apply the fix
git commit --amend --no-edit
git cherry-pick <bad-sha>.."$old_tip"           # replay every later commit in order
```

The preflight ref, bundle and zip stay until Steps 5, 8 and 9 pass on the result; retire them with the delivery's other backups, never in the same step as the fix.
