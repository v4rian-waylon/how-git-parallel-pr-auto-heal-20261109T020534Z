#!/usr/bin/env bash
# reconstruct.sh - deterministic mechanics behind the git-reconstruct skill.
#
# Every subcommand here is pure git/file/build mechanics, no judgment. The
# three subcommands that DO require judgment (infer-rename, check-reusability,
# review-scrub-hit) shell out to a `claude -p` subprocess with the
# git-reconstruct skill + Git_Strategy.md referenced by path as guardrail
# context, and are the ONLY subcommands that do so - every other verb below
# never invokes claude. Each keeps claude's stdout only and accepts the
# answer only when its last line matches the documented one line contract
# (exit 1 otherwise). All three honor LIFECYCLE_TEST_MODE=1 (canned,
# deterministic output derived from the real input shape) so the framework's
# offline lifecycle suite can exercise them, mirroring smart-commit's
# test-mode contract.
#
# Sourced by bin/reconstruct, which does argument dispatch. Each function
# here is self-contained and can also be sourced directly by tests.

set -uo pipefail

# An inherited GIT_DIR (git exports it to every hook) makes any cwd look like
# a work tree root and points every command at another repository. Each
# subcommand names its repo explicitly, so drop the whole family.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The namespace this library ships in; the claude subcommands cite its skill
# and spec, never whatever repo the caller's cwd happens to be.
RECONSTRUCT_NS_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# ---------------------------------------------------------------------------
# Step 2 - identity discovery. Pure git, reports only, never blends/normalizes.
# Every ref counts (an author present only on an unmerged branch is still a
# real identity the replay must attribute), and committers count too, since
# a replay preserves both halves of each commit's identity. The stash and
# other private refs are not source history, so only branches, tags,
# remote-tracking refs and HEAD (a detached checkout shipped as a zip) count.
# ---------------------------------------------------------------------------
reconstruct_identity() {
  local source_repo="${1:?usage: reconstruct identity <source-repo>}"
  if [ ! -d "$source_repo/.git" ] && ! git -C "$source_repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "X reconstruct identity: $source_repo is not a git repo" >&2
    return 2
  fi
  local head=""
  git -C "$source_repo" rev-parse -q --verify HEAD >/dev/null && head=HEAD
  git -C "$source_repo" log $head --branches --tags --remotes --format='%an <%ae>%n%cn <%ce>' | sort -u
}

# ---------------------------------------------------------------------------
# Step 1 - catalog scaffold. Reads a manifest, creates the directory
# convention mechanically. Never writes source content, only structure.
#
# Manifest shape:
#   {
#     "namespace": "acme",
#     "modules": [
#       {"name": "audio", "subareas": ["host", "analysis"]},
#       {"name": "ui", "subareas": []}
#     ]
#   }
# ---------------------------------------------------------------------------
reconstruct_scaffold() {
  local manifest="${1:?usage: reconstruct scaffold <manifest.json> <target-dir>}"
  local target="${2:?usage: reconstruct scaffold <manifest.json> <target-dir>}"
  [ -f "$manifest" ] || { echo "X reconstruct scaffold: manifest not found: $manifest" >&2; return 2; }
  mkdir -p "$target"
  python3 - "$manifest" "$target" <<'PY'
import json, os, sys
manifest_path, target = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    spec = json.load(f)
ns = spec["namespace"]
created = []
for mod in spec.get("modules", []):
    name = mod["name"]
    subareas = mod.get("subareas", []) or [""]
    mod_root = os.path.join(target, name)
    for sub in subareas:
        inc = os.path.join(mod_root, "include", ns, name, sub) if sub else os.path.join(mod_root, "include", ns, name)
        src = os.path.join(mod_root, "src", sub) if sub else os.path.join(mod_root, "src")
        os.makedirs(inc, exist_ok=True)
        os.makedirs(src, exist_ok=True)
        created.append(inc)
        created.append(src)
    cml = os.path.join(mod_root, "CMakeLists.txt")
    if not os.path.exists(cml):
        with open(cml, "w") as f:
            f.write(f"# {name} - independently findable/buildable module.\n")
        created.append(cml)
for c in created:
    print(c)
PY
}

# ---------------------------------------------------------------------------
# Step 6 - gap report. Diffs the manifest's expected headers against what
# actually exists under the target dir. Deterministic, no invention.
# ---------------------------------------------------------------------------
reconstruct_gaps() {
  local manifest="${1:?usage: reconstruct gaps <manifest.json> <target-dir>}"
  local target="${2:?usage: reconstruct gaps <manifest.json> <target-dir>}"
  [ -f "$manifest" ] || { echo "X reconstruct gaps: manifest not found: $manifest" >&2; return 2; }
  python3 - "$manifest" "$target" <<'PY'
import json, os, sys
manifest_path, target = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    spec = json.load(f)
ns = spec["namespace"]
missing = []
for mod in spec.get("modules", []):
    name = mod["name"]
    for cls in mod.get("classes", []):
        candidates = [
            os.path.join(target, name, "include", ns, name, cls + ".h"),
        ]
        for sub in mod.get("subareas", []) or []:
            candidates.append(os.path.join(target, name, "include", ns, name, sub, cls + ".h"))
        if not any(os.path.exists(c) for c in candidates):
            missing.append(f"{name}::{cls}")
if missing:
    print("gaps (no source found):")
    for m in missing:
        print(f"  - {m}")
    sys.exit(1)
print("no gaps: every catalogued class has a header on disk")
PY
}

# ---------------------------------------------------------------------------
# Step 8 - structural self-audit. THE mandatory, deterministic check that a
# green test suite cannot substitute for. Checks, in order:
#   1. every pool/* branch (local and origin) landed on dev's first-parent
#      line, matched by nN, kind and short slug, where a reconcile candidate
#      stands in for its original of any kind the way claim-dev-merge.sh
#      pairs them, through a "[MERGE] <ref>
#      into dev", "Merge pull request #N from <owner>/<ref>" or
#      "Merge branch '<ref>'" subject (a legacy reconcile -<k> retry suffix
#      on the slug is ignored)
#   2. every merge on dev's first-parent line carries a tag
#   3. every vYEAR.SERIES.DEV tag with DEV >= 1 points at a merge commit;
#      DEV 0 is the cycle seal and may sit on any commit; tags outside the
#      version scheme (milestone/*, ...) are listed as notes
#   4. each vYEAR.SERIES runs DEV 1..N without holes, and no commit
#      carries two DEV tags; --allow-gaps-before <vY.S.D> turns holes older
#      than that tag into notes (a repo whose early holes are permanent)
#   5. required docs exist (README.md and .gitignore unless
#      --no-default-docs, plus every --require)
#   6. local dev and every local tag match origin (no push gap either way)
# Run against --clone for a trustworthy result. Exit 0 clean, 1 on any
# failure (never the raw count: exit status wraps at 256), 2 usage error.
# ---------------------------------------------------------------------------

# Landing key of a pool ref: "<major-prefix>|<N>|<kind>|<short>", or
# "ref||ref|<name>" when the ref does not follow the pool naming scheme.
_reconstruct_pool_key() {
  local ref="$1"
  if [[ "$ref" =~ ^pool/(v[0-9]+\.[0-9]+)/n([0-9]+)\.([a-z\&]+)\.(.+)$ ]]; then
    printf '%s|%s|%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
  elif [[ "$ref" =~ ^pool/n([0-9]+)\.([a-z\&]+)\.(.+)$ ]]; then
    printf '|%s|%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  else
    printf 'ref||ref|%s\n' "$ref"
  fi
}

# True when branch key $1 is among the landed keys in $2: same prefix, nN
# and slug, and the same kind unless either side is a reconcile candidate.
_reconstruct_key_landed() {
  printf '%s' "$2" | awk -F'|' -v key="$1" '
    BEGIN { split(key, k, "|") }
    $1 == k[1] && $2 == k[2] && $4 == k[4] && ($3 == k[3] || $3 == "reconcile" || k[3] == "reconcile") { found = 1 }
    END { exit !found }'
}

# Source ref named by a dev merge subject, empty when the subject names none.
_reconstruct_merge_source() {
  local subj="$1"
  if [[ "$subj" =~ ^\[MERGE\]\ ([^ ]+)\ into\ dev ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$subj" =~ ^Merge\ pull\ request\ \#[0-9]+\ from\ [^/]+/([^ ]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$subj" =~ ^Merge\ branch\ \'([^\']+)\' ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

reconstruct_audit_structure() {
  local repo="." clone_url="" required_docs="" default_docs="README.md .gitignore" gaps_before=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-default-docs) default_docs=""; shift ;;
      --allow-gaps-before)
        [ $# -ge 2 ] && [[ "$2" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
          || { echo "X reconstruct audit-structure: --allow-gaps-before needs a vYEAR.SERIES.DEV tag name" >&2; return 2; }
        gaps_before="$2"; shift 2 ;;
      --clone)
        [ $# -ge 2 ] || { echo "X reconstruct audit-structure: --clone needs a url" >&2; return 2; }
        clone_url="$2"; shift 2 ;;
      --require)
        [ $# -ge 2 ] || { echo "X reconstruct audit-structure: --require needs a path" >&2; return 2; }
        required_docs="$required_docs $2"; shift 2 ;;
      -*) echo "X reconstruct audit-structure: unknown flag: $1" >&2; return 2 ;;
      *) repo="$1"; shift ;;
    esac
  done

  local work_dir="$repo" scratch=""
  if [ -n "$clone_url" ]; then
    scratch=$(mktemp -d -t reconstruct-audit-XXXXXX) || return 2
    git clone -q "$clone_url" "$scratch/clone" || { echo "X audit-structure: clone failed: $clone_url" >&2; rm -rf "$scratch"; return 2; }
    work_dir="$scratch/clone"
  fi

  ( cd "$work_dir" 2>/dev/null || { echo "X reconstruct audit-structure: no such directory: $work_dir" >&2; exit 2; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "X reconstruct audit-structure: not a git repo: $work_dir" >&2; exit 2; }
    failures=0
    fail() { echo "FAIL: $*"; failures=$((failures+1)); }

    has_origin=false
    if git remote get-url origin >/dev/null 2>&1; then
      has_origin=true
      git fetch -q origin >/dev/null 2>&1 || fail "could not fetch origin"
    fi
    dev_ref=""
    if git rev-parse --verify -q refs/heads/dev >/dev/null; then dev_ref=dev
    elif git rev-parse --verify -q refs/remotes/origin/dev >/dev/null; then dev_ref=origin/dev
    fi
    [ -n "$dev_ref" ] || fail "no dev branch (local or origin)"

    # 1) every pool branch landed on dev
    landed=""
    if [ -n "$dev_ref" ]; then
      while IFS= read -r subj; do
        src=$(_reconstruct_merge_source "$subj")
        [ -n "$src" ] || continue
        landed="$landed$(_reconstruct_pool_key "$src")"$'\n'
        # Legacy reconcile candidates carried a -<k> retry suffix on the slug.
        if [[ "$src" =~ ^(.*\.reconcile\..+)-[0-9]+$ ]]; then
          landed="$landed$(_reconstruct_pool_key "${BASH_REMATCH[1]}")"$'\n'
        fi
      done < <(git log "$dev_ref" --first-parent --merges --format='%s')
    fi
    while IFS= read -r b; do
      [ -z "$b" ] && continue
      _reconstruct_key_landed "$(_reconstruct_pool_key "$b")" "$landed" \
        || fail "pool branch '$b' has no matching [MERGE] into dev commit on dev (nN + short slug)"
    done < <(git for-each-ref --format='%(refname)' refs/heads/pool refs/remotes/origin/pool \
               | sed -e 's#^refs/heads/##' -e 's#^refs/remotes/origin/##' | sort -u)

    # 2) every first-parent merge on dev has a tag
    merge_count=0
    if [ -n "$dev_ref" ]; then
      while IFS= read -r sha; do
        [ -z "$sha" ] && continue
        merge_count=$((merge_count+1))
        [ -n "$(git tag --points-at "$sha")" ] || fail "merge commit $sha has no tag pointing at it"
      done < <(git log "$dev_ref" --first-parent --merges --format='%H')
    fi

    # 3) version tags with DEV >= 1 sit on merges; seals and named tags are free
    version_rows=""
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      sha=$(git rev-parse -q --verify "refs/tags/$t^{commit}" 2>/dev/null) || continue
      if [[ "$t" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        series="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
        [ "$d" -eq 0 ] && continue
        version_rows="$version_rows$series $d $sha $t"$'\n'
        parents=$(git rev-list --parents -n 1 "$sha" | wc -w | tr -d ' ')
        [ "$parents" -ge 3 ] || fail "tag '$t' points at a non-merge commit ($sha)"
      else
        echo "note: tag '$t' is outside the vYEAR.SERIES.DEV sequence"
      fi
    done < <(git tag)

    # 4) DEV runs 1..N per series without holes; one DEV tag per commit
    if [ -n "$version_rows" ]; then
      while IFS= read -r line; do
        case "$line" in note:*) echo "$line" ;; *) fail "$line" ;; esac
      done < <(printf '%s' "$version_rows" | sort -k1,1 -k2,2n | awk -v before="${gaps_before#v}" '
        BEGIN { nb = split(before, b, ".") }
        function older(series, d,   s) {
          if (nb != 3) return 0
          split(series, s, ".")
          if (s[1] + 0 != b[1] + 0) return s[1] + 0 < b[1] + 0
          if (s[2] + 0 != b[2] + 0) return s[2] + 0 < b[2] + 0
          return d + 0 < b[3] + 0 }
        { if ($1 != s) { s = $1; want = 1 }
          while (want < $2) {
            printf "%stag sequence gap: v%s.%d missing\n", (older(s, want) ? "note: " : ""), s, want; want++ }
          if ($2 == want) want++ }')
      while IFS= read -r line; do fail "$line"; done < <(printf '%s' "$version_rows" | sort -k3,3 | awk '
        { if ($3 == c) { l = l " " $4; n++ } else { if (n > 1) print "commit " c " carries several DEV tags:" l; c = $3; l = " " $4; n = 1 } }
        END { if (n > 1) print "commit " c " carries several DEV tags:" l }')
    fi

    # 5) required docs
    for doc in $default_docs $required_docs; do
      [ -e "$doc" ] || fail "required doc missing: $doc"
    done

    # 6) local dev and tags match origin
    if $has_origin; then
      if git rev-parse --verify -q refs/heads/dev >/dev/null && git rev-parse --verify -q refs/remotes/origin/dev >/dev/null; then
        [ "$(git rev-parse dev)" = "$(git rev-parse origin/dev)" ] \
          || fail "local dev ($(git rev-parse dev)) does not match origin/dev ($(git rev-parse origin/dev))"
      fi
      if remote_tags=$(git ls-remote --tags origin 2>/dev/null); then
        remote_tags=$(printf '%s\n' "$remote_tags" | awk '$2 !~ /\^\{\}$/ { sub("refs/tags/", "", $2); print $2, $1 }' | sort)
        local_tags=$(git for-each-ref --format='%(refname:strip=2) %(objectname)' refs/tags | sort)
        while IFS= read -r line; do fail "$line"; done < <(join -a1 -a2 -e MISSING -o 0,1.2,2.2 \
          <(printf '%s\n' "$local_tags" | sed '/^$/d') <(printf '%s\n' "$remote_tags" | sed '/^$/d') | awk '
            $2 == "MISSING" { print "tag " $1 " is on origin but not local"; next }
            $3 == "MISSING" { print "tag " $1 " is local but not on origin (push gap)"; next }
            $2 != $3 { print "tag " $1 " differs: local " $2 ", origin " $3 }')
      else
        fail "could not list origin tags"
      fi
    fi

    if [ "$failures" -eq 0 ]; then
      echo "PASS: structural audit clean ($merge_count merge(s) on dev)"
      exit 0
    fi
    echo "FAIL: $failures structural problem(s)"
    exit 1
  )
  local rc=$?
  [ -n "$scratch" ] && rm -rf "$scratch"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Step 9 (mechanical half) - remnant scrub. For each supplied term, sweeps:
#   file     tracked working-tree content, file:line
#   path     every path any commit on any ref ever carried (directory-name
#            leaks included)
#   commit   every commit message on every ref, by real SHA
#   history  every commit on any ref whose diff adds or removes the term,
#            so content later deleted is still caught at its origin commit
#   ref      every ref name (fast-forward ships branch and tag names as is)
#   identity every commit whose author or committer name or email holds it
# <path> may be any directory inside the repo: the sweep always covers the
# whole repository. Matching ignores case (ZULU leaks as much as zulu).
# Empty or blank terms are refused (they match everything).
# Never judges a hit - review-scrub-hit (claude) does that. Prints the hit
# count; exit 0 clean, 1 on any hit (never the raw count: exit status wraps
# at 256), 2 usage error.
# ---------------------------------------------------------------------------
reconstruct_scrub() {
  local path="${1:-}"
  [ -n "$path" ] || { echo "usage: reconstruct scrub <path> <term...>" >&2; return 2; }
  shift
  [ $# -ge 1 ] || { echo "X reconstruct scrub: at least one term required" >&2; return 2; }
  local term
  for term in "$@"; do
    [ -n "$(printf '%s' "$term" | tr -d '[:space:]')" ] || { echo "X reconstruct scrub: empty or blank term" >&2; return 2; }
  done
  ( cd "$path" 2>/dev/null || { echo "X reconstruct scrub: no such directory: $path" >&2; exit 2; }
    top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "X reconstruct scrub: not a git repo: $path" >&2; exit 2; }
    cd "$top" || exit 2
    hits=0
    # core.quotePath=false: by default git prints non-ASCII paths as quoted
    # octal escapes, which no term would ever match.
    paths=$( { git -c core.quotePath=false ls-files; git -c core.quotePath=false log --all --format= --name-only; } | sed '/^$/d' | sort -u)
    for term in "$@"; do
      while IFS= read -r row; do
        [ -z "$row" ] && continue
        case "$row" in
          "Binary file "*" matches") row="${row#Binary file }"; echo "HIT (file): ${row% matches} (binary): $term" ;;
          *) file="${row%%:*}"; rest="${row#*:}"; echo "HIT (file): $file:${rest%%:*}: $term" ;;
        esac
        hits=$((hits+1))
      done < <(git grep -n -i -F -e "$term" 2>/dev/null)
      while IFS= read -r p; do
        [ -z "$p" ] && continue
        echo "HIT (path): $p: $term"
        hits=$((hits+1))
      done < <(printf '%s\n' "$paths" | grep -i -F -- "$term")
      while IFS= read -r sha; do
        [ -z "$sha" ] && continue
        echo "HIT (commit): $sha: $term"
        hits=$((hits+1))
      done < <(git log --all -i -F --grep="$term" --format=%H)
      while IFS= read -r sha; do
        [ -z "$sha" ] && continue
        echo "HIT (history): $sha: $term"
        hits=$((hits+1))
      done < <(git log --all -i -S"$term" --format=%H)
      while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        echo "HIT (ref): $ref: $term"
        hits=$((hits+1))
      done < <(git for-each-ref --format='%(refname)' | grep -i -F -- "$term")
      while IFS= read -r row; do
        [ -z "$row" ] && continue
        echo "HIT (identity): ${row%% *}: $term"
        hits=$((hits+1))
      done < <(git log --all --format='%H %an <%ae> %cn <%ce>' | awk -v t="$term" 'index(tolower(substr($0, 42)), tolower(t))')
    done
    echo "hits: $hits"
    if [ "$hits" -eq 0 ]; then
      echo "clean: no hits for any supplied term"
      exit 0
    fi
    exit 1
  )
}

# ---------------------------------------------------------------------------
# Preflight before any destructive step (relocate, a rewrite push, a reset):
# three independent backups taken without touching the current branch or
# index. Names and places follow the how-preflight convention
# (git-preflight.sh), so a destructive-git guard that looks for a fresh
# preflight-bak-* ref on origin plus a <name>-bak-*.zip accepts this one.
#   ref     preflight-bak-<local day>/NN: the full working tree (tracked and
#           untracked, secrets excluded) committed on top of HEAD through a
#           temporary index, pushed to origin when one is configured; a
#           refused push fails the preflight (nothing off the machine would
#           hold the old history) unless allow_unpushed is 1
#   bundle  <bak-dir>/<repo>-bak-<UTC stamp>.bundle holding every ref, so the
#           whole history survives even a rewrite of the repo's own refs
#   zip     <bak-dir>/<repo>-bak-<UTC stamp>.zip of the working tree
#           (tar.gz when zip is not installed), copied to BAKS_MIRROR when
#           that directory exists
# <bak-dir> is RECONSTRUCT_BAK_DIR, else BAKS_DIR, else <repo parent>/baks.
#
# When the machine has the how-preflight hook (RECONSTRUCT_PREFLIGHT_HOOK,
# default ~/.claude/hooks/git-preflight.sh; empty disables it) the tool runs
# that hook instead, so the ref and zip land exactly where the machine's
# destructive-git guard looks, and adds its bundle beside the hook's zip.
# Without it the built-in backups above are taken and the tool says where.
# ---------------------------------------------------------------------------
_reconstruct_preflight() {
  local repo_abs="$1" reason="$2" allow_unpushed="${3:-0}"
  local hook="${RECONSTRUCT_PREFLIGHT_HOOK-${HOME:+$HOME/.claude/hooks/git-preflight.sh}}"
  if [ -n "$hook" ] && [ -x "$hook" ]; then
    _reconstruct_preflight_via_hook "$hook" "$repo_abs" "$reason" "$allow_unpushed"
    return
  fi
  ( cd "$repo_abs" 2>/dev/null || { echo "X reconstruct preflight: no such directory: $repo_abs" >&2; exit 2; }
    name=$(basename "$repo_abs"); day=$(date +%Y-%m-%d); stamp=$(date -u +%Y%m%dT%H%M%SZ)
    bak_dir="${RECONSTRUCT_BAK_DIR:-${BAKS_DIR:-$(dirname "$repo_abs")/baks}}"
    mkdir -p "$bak_dir" || { echo "X reconstruct preflight: cannot create $bak_dir" >&2; exit 1; }
    n=1
    while git show-ref --verify -q "refs/heads/preflight-bak-$day/$(printf %02d "$n")" \
       || git show-ref --verify -q "refs/remotes/origin/preflight-bak-$day/$(printf %02d "$n")"; do
      n=$((n+1))
    done
    br="preflight-bak-$day/$(printf %02d "$n")"
    tmpidx=$(mktemp -t reconstruct-idx.XXXXXX) || exit 1
    trap 'rm -f "$tmpidx"' EXIT
    # An empty temp file is a corrupt index to git: drop it when there is no
    # index to seed from.
    cp "$(git rev-parse --git-path index)" "$tmpidx" 2>/dev/null || rm -f "$tmpidx"
    # Staged by name: ls-files names every tracked and untracked, not
    # ignored path minus the secret patterns, and update-index records
    # exactly those (a deleted tracked path is removed), so nothing is
    # staged by a blanket add (friction ledger FP-15).
    git ls-files -z --cached --others --exclude-standard -- . ':(exclude,glob)**/.env' ':(exclude,glob)**/.env.*' \
      ':(exclude).auth' ':(exclude)keys' ':(exclude,glob)**/*.p8' ':(exclude,glob)**/*.p12' \
      ':(exclude,glob)**/*.pem' ':(exclude,glob)**/*.cer' ':(exclude,glob)**/*.provisionprofile' \
      ':(exclude,glob)**/*.mobileprovision' ':(exclude,glob)**/.DS_Store' ':(exclude,glob)**/.frac' \
      | GIT_INDEX_FILE="$tmpidx" git update-index -z --add --remove --stdin \
      || { echo "X reconstruct preflight: could not stage the working tree" >&2; exit 1; }
    tree=$(GIT_INDEX_FILE="$tmpidx" git write-tree) || { echo "X reconstruct preflight: write-tree failed" >&2; exit 1; }
    parent=$(git rev-parse -q --verify HEAD || true)
    commit=$(printf 'preflight backup before %s\n\nFull working tree (tracked and untracked, secrets excluded) as of %s.\n' "$reason" "$stamp" \
      | git -c user.name="$(git config user.name || echo reconstruct)" -c user.email="$(git config user.email || echo reconstruct@localhost)" \
          commit-tree "$tree" ${parent:+-p "$parent"}) \
      || { echo "X reconstruct preflight: commit-tree failed" >&2; exit 1; }
    git update-ref "refs/heads/$br" "$commit" || exit 1
    pushed="local only (no origin)"
    git remote get-url origin >/dev/null 2>&1 \
      || echo "! reconstruct preflight: $repo_abs has no origin; no remote backup was made" >&2
    if git remote get-url origin >/dev/null 2>&1; then
      # A backup ref, not a developer branch: the pre-push branch-name gate
      # judges HEAD's name and has nothing to say about it.
      if git push -q --no-verify origin "refs/heads/$br:refs/heads/$br"; then
        pushed="pushed to origin"
      elif [ "$allow_unpushed" = 1 ]; then
        pushed="PUSH FAILED, local only (--allow-unpushed)"
        echo "! reconstruct preflight: no off-machine copy of $repo_abs; the backup ref exists locally only" >&2
      else
        echo "X reconstruct preflight: origin refused $br; without an off-machine copy nothing destructive may run (pass --allow-unpushed to accept a local only backup)" >&2
        exit 1
      fi
    fi
    bundle="$bak_dir/$name-bak-$stamp.bundle"
    git bundle create -q "$bundle" --all 2>/dev/null || { echo "X reconstruct preflight: bundle failed: $bundle" >&2; exit 1; }
    parent_dir=$(dirname "$repo_abs")
    if command -v zip >/dev/null 2>&1; then
      archive="$bak_dir/$name-bak-$stamp.zip"
      ( cd "$parent_dir" && zip -rq "$archive" "$name" -x "$name/.git" "$name/.git/*" "$name/build/*" "$name/build-*/*" \
          "*/node_modules/*" "*.env" "*/.auth/*" "*/keys/*" "*.p8" "*.p12" "*.pem" "*/.DS_Store" ) \
        || { echo "X reconstruct preflight: zip failed: $archive" >&2; exit 1; }
    else
      archive="$bak_dir/$name-bak-$stamp.tar.gz"
      tar -C "$parent_dir" -czf "$archive" --exclude "$name/.git" --exclude "$name/build" --exclude 'node_modules' \
          --exclude '*.env' --exclude '.auth' --exclude 'keys' --exclude '*.p8' --exclude '*.p12' --exclude '*.pem' "$name" \
        || { echo "X reconstruct preflight: tar failed: $archive" >&2; exit 1; }
    fi
    mirrored=""
    if [ -n "${BAKS_MIRROR:-}" ] && [ -d "$BAKS_MIRROR" ]; then
      cp -p "$archive" "$bundle" "$BAKS_MIRROR/" || { echo "X reconstruct preflight: mirror copy to $BAKS_MIRROR failed" >&2; exit 1; }
      mirrored="; mirrored to $BAKS_MIRROR"
    fi
    echo "preflight: $br ($commit, $pushed); bundle $bundle; archive $archive$mirrored"
    echo "note: no how-preflight hook${hook:+ at $hook}; backups are under $bak_dir, which a destructive-git guard accepts only when it reads the same directory (BAKS_DIR)" >&2
  )
}

# The hook path: run it, hold it to the same push contract, add the bundle.
_reconstruct_preflight_via_hook() {
  local hook="$1" repo_abs="$2" reason="$3" allow_unpushed="$4"
  ( cd "$repo_abs" 2>/dev/null || { echo "X reconstruct preflight: no such directory: $repo_abs" >&2; exit 2; }
    out=$("$hook" "$repo_abs" "$reason") || { printf '%s\n' "$out"; echo "X reconstruct preflight: $hook failed" >&2; exit 1; }
    printf '%s\n' "$out"
    line=$(printf '%s\n' "$out" | grep '^preflight: ' | tail -n 1)
    zipf=$(printf '%s\n' "$line" | sed -n 's/.*; zip \(.*\) ([^)]*)$/\1/p')
    [ -n "$zipf" ] && [ -f "$zipf" ] || { echo "X reconstruct preflight: could not find the zip $hook reported" >&2; exit 1; }
    case "$line" in
      *"no origin"*)
        echo "! reconstruct preflight: $repo_abs has no origin; no remote backup was made" >&2 ;;
      *"PUSH FAILED"*)
        if [ "$allow_unpushed" = 1 ]; then
          echo "! reconstruct preflight: no off-machine copy of $repo_abs; the backup ref exists locally only" >&2
        else
          echo "X reconstruct preflight: origin refused the backup ref; without an off-machine copy nothing destructive may run (pass --allow-unpushed to accept a local only backup)" >&2
          exit 1
        fi ;;
    esac
    bundle="${zipf%.zip}.bundle"
    git bundle create -q "$bundle" --all 2>/dev/null || { echo "X reconstruct preflight: bundle failed: $bundle" >&2; exit 1; }
    # The hook mirrors its zip to BAKS_MIRROR or its own MIRROR default; the
    # bundle goes wherever the zip went.
    mirror="${BAKS_MIRROR:-$(sed -n 's/^MIRROR="\${BAKS_MIRROR:-\(.*\)}"$/\1/p' "$hook" | head -n 1)}"
    mirrored=""
    if [ -n "$mirror" ] && [ -f "$mirror/$(basename "$zipf")" ]; then
      cp -p "$bundle" "$mirror/" || { echo "X reconstruct preflight: mirror copy to $mirror failed" >&2; exit 1; }
      mirrored="; mirrored to $mirror"
    fi
    echo "preflight bundle: $bundle (via $hook)$mirrored"
  )
}

reconstruct_preflight() {
  local repo="" reason="destructive op" allow_unpushed=0 repo_abs top positional=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --allow-unpushed) allow_unpushed=1 ;;
      -*) echo "X reconstruct preflight: unknown flag: $1" >&2; return 2 ;;
      *) positional=$((positional+1))
         if [ "$positional" -eq 1 ]; then repo="$1"; else reason="$1"; fi ;;
    esac
    shift
  done
  [ -n "$repo" ] || { echo "usage: reconstruct preflight <repo> [reason] [--allow-unpushed]" >&2; return 2; }
  repo_abs=$(cd "$repo" 2>/dev/null && pwd -P) || { echo "X reconstruct preflight: no such directory: $repo" >&2; return 2; }
  top=$(cd "$repo_abs" && git rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" && pwd -P) || top=""
  [ "$top" = "$repo_abs" ] && [ -e "$repo_abs/.git" ] \
    || { echo "X reconstruct preflight: not the root of a git repo: $repo_abs" >&2; return 2; }
  _reconstruct_preflight "$repo_abs" "$reason" "$allow_unpushed"
}

# ---------------------------------------------------------------------------
# Step 11 - relocate a fully-built history into a subdirectory via
# git-filter-repo. Order of guards, each fatal:
#   1. <repo> must resolve to the root of a git repo with its own .git
#      directory (a path inside another repo, one that does not exist, an
#      inherited GIT_DIR and a linked worktree sharing another repo's object
#      store are all refused), and <subdir> must be a plain relative path
#   2. no tracked file may carry uncommitted changes (filter-repo ends with
#      a hard reset)
#   3. no local branch may be behind or diverged from origin (filter-repo
#      drops origin-only commits); branches only ahead keep their unpushed
#      commits and are relocated as they are; missing ones are created
#      from origin, never reset
#   4. preflight (ref on origin, bundle, archive) must succeed
#   5. filter-repo runs only from inside the verified repo root
# Afterwards every branch and tag on a commit that existed before must still
# exist (tags on trees or blobs are noted and left alone), have
# a new SHA (unless its tree was empty) and a tree holding <subdir>/ alone;
# anything else exits 1 as "history not relocated".
# git-filter-repo comes from PATH, else a pinned release verified by sha256.
# ---------------------------------------------------------------------------
RECONSTRUCT_FILTER_REPO_URL="https://raw.githubusercontent.com/newren/git-filter-repo/v2.47.0/git-filter-repo"
RECONSTRUCT_FILTER_REPO_SHA256="67447413e273fc76809289111748870b6f6072f08b17efe94863a92d810b7d94"

reconstruct_relocate() {
  local repo="${1:-}" subdir="${2:-}"
  if [ $# -ne 2 ] || [ -z "$repo" ] || [ -z "$subdir" ]; then
    echo "usage: reconstruct relocate <repo> <subdir>" >&2; return 2
  fi
  case "$subdir" in
    /*|-*|..|../*|*/..|*/../*|.) echo "X reconstruct relocate: subdir must be a relative path inside the repo: $subdir" >&2; return 2 ;;
  esac
  local repo_abs top
  repo_abs=$(cd "$repo" 2>/dev/null && pwd -P) || { echo "X reconstruct relocate: no such directory: $repo" >&2; return 2; }
  top=$(cd "$repo_abs" && git rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" && pwd -P) || top=""
  [ "$top" = "$repo_abs" ] || { echo "X reconstruct relocate: not the root of a git repo: $repo_abs" >&2; return 2; }
  local git_dir common_dir
  git_dir=$(cd "$repo_abs" && cd "$(git rev-parse --git-dir)" && pwd -P)
  common_dir=$(cd "$repo_abs" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
  if [ ! -d "$repo_abs/.git" ] || [ "$git_dir" != "$common_dir" ]; then
    echo "X reconstruct relocate: $repo_abs is a linked worktree; its history lives in $common_dir. Relocate a clone instead" >&2
    return 2
  fi
  if [ -n "$(git -C "$repo_abs" status --porcelain --untracked-files=no)" ]; then
    echo "X reconstruct relocate: uncommitted changes to tracked files in $repo_abs; commit or stash them first:" >&2
    git -C "$repo_abs" status --short --untracked-files=no >&2
    return 1
  fi

  local b l r missing="" refuse=""
  while IFS= read -r b; do
    [ -z "$b" ] || [ "$b" = "HEAD" ] && continue
    r=$(git -C "$repo_abs" rev-parse "refs/remotes/origin/$b")
    if ! l=$(git -C "$repo_abs" rev-parse -q --verify "refs/heads/$b"); then
      missing="$missing$b"$'\n'
    elif [ "$l" = "$r" ]; then
      :
    elif git -C "$repo_abs" merge-base --is-ancestor "$r" "$l"; then
      echo "  · kept: $b carries $(git -C "$repo_abs" rev-list --count "$r..$l") unpushed commit(s); relocated as they are"
    else
      refuse="$refuse  $b (local $l, origin $r)"$'\n'
    fi
  done < <(git -C "$repo_abs" for-each-ref --format='%(refname:strip=3)' refs/remotes/origin)
  if [ -n "$refuse" ]; then
    echo "X reconstruct relocate: local branches behind or diverged from origin; filter-repo would drop the origin-only commits. Integrate them first:" >&2
    printf '%s' "$refuse" >&2
    return 1
  fi

  local filter_repo_bin fetched=""
  filter_repo_bin=$(command -v git-filter-repo 2>/dev/null || true)
  if [ -z "$filter_repo_bin" ]; then
    if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
      echo "  · [test-mode] git-filter-repo not on PATH; would fetch it and proceed" >&2
      return 0
    fi
    echo "  → git-filter-repo not on PATH; fetching the pinned release" >&2
    fetched=$(mktemp -t git-filter-repo.XXXXXX) || return 1
    if ! curl -fsSL -o "$fetched" "$RECONSTRUCT_FILTER_REPO_URL"; then
      echo "X reconstruct relocate: could not fetch git-filter-repo" >&2
      rm -f "$fetched"; return 1
    fi
    local got
    got=$( (shasum -a 256 "$fetched" 2>/dev/null || sha256sum "$fetched") | awk '{print $1}')
    if [ "$got" != "$RECONSTRUCT_FILTER_REPO_SHA256" ]; then
      echo "X reconstruct relocate: git-filter-repo checksum mismatch ($got)" >&2
      rm -f "$fetched"; return 1
    fi
  fi

  if ! _reconstruct_preflight "$repo_abs" "relocate into $subdir/"; then
    echo "X reconstruct relocate: preflight failed; nothing was rewritten" >&2
    [ -n "$fetched" ] && rm -f "$fetched"
    return 1
  fi

  ( cd "$repo_abs" || exit 2
    [ "$(pwd -P)" = "$repo_abs" ] && [ "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" = "$repo_abs" ] \
      || { echo "X reconstruct relocate: cwd is not the verified target $repo_abs; refusing" >&2; exit 2; }
    while IFS= read -r b; do
      [ -z "$b" ] && continue
      git branch --no-track "$b" "refs/remotes/origin/$b" >/dev/null \
        || { echo "X reconstruct relocate: could not create $b from origin" >&2; exit 1; }
    done <<< "$missing"

    before_branches=$(git for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')
    before_tags=$(git tag | wc -l | tr -d ' ')
    # Classify every ref now: filter-repo repacks and prunes the old objects,
    # so after it runs their type and tree can no longer be read.
    before_refs=$(git for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags | while read -r ref old; do
      kind=$(git cat-file -t "$old^{}" 2>/dev/null || echo missing)
      empty=0
      [ "$kind" = commit ] && [ -z "$(git ls-tree "$old^{commit}")" ] && empty=1
      echo "$ref $old $kind $empty"
    done)
    echo "→ git-filter-repo --to-subdirectory-filter=$subdir in $repo_abs"
    if [ -n "$fetched" ]; then
      python3 "$fetched" --to-subdirectory-filter="$subdir" --force
    else
      "$filter_repo_bin" --to-subdirectory-filter="$subdir" --force
    fi || { echo "X reconstruct relocate: git-filter-repo failed" >&2; exit 1; }

    top_entry="${subdir%%/*}"
    not_moved=""
    while read -r ref old kind empty; do
      [ -z "$ref" ] && continue
      if [ "$kind" != commit ]; then
        echo "note: $ref points at a $kind, not a commit; filter-repo leaves it as it is"
        continue
      fi
      commit=$(git rev-parse -q --verify "$ref^{commit}" 2>/dev/null) || { not_moved="$not_moved $ref(gone)"; continue; }
      [ "$empty" = 1 ] && continue
      if [ "$(git rev-parse "$ref")" = "$old" ] \
         || [ "$(git ls-tree --name-only "$commit")" != "$top_entry" ] \
         || ! git rev-parse -q --verify "$commit:$subdir" >/dev/null; then
        not_moved="$not_moved $ref"
      fi
    done <<< "$before_refs"

    after_branches=$(git for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')
    after_tags=$(git tag | wc -l | tr -d ' ')
    echo "branches: $before_branches -> $after_branches"
    echo "tags: $before_tags -> $after_tags"
    if [ "$before_branches" != "$after_branches" ] || [ "$before_tags" != "$after_tags" ]; then
      echo "X reconstruct relocate: branch/tag count changed across relocation" >&2
      exit 1
    fi
    if [ -n "$not_moved" ]; then
      echo "X reconstruct relocate: history not relocated under $subdir/ for:$not_moved" >&2
      exit 1
    fi
  )
  local rc=$?
  [ -n "$fetched" ] && rm -f "$fetched"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Step 7 - fast-forward the current working clone to a fresh throwaway,
# verbatim (no rewrite): dev, main when present, and every pool/*,
# feature/* (legacy), safety/* and vault/* branch plus every tag, in one
# atomic push of explicit ref:ref refspecs. Authentication goes through
# gh's credential helper for that one command, so no token is ever written
# to .git/config or passed on a command line. Every step's exit status is
# checked and the pushed refs are read back from the new repo before "ok:".
# --dry-run and LIFECYCLE_TEST_MODE=1 print the plan without the network.
# RECONSTRUCT_FF_REMOTE_BASE (default https://github.com) exists for tests.
# ---------------------------------------------------------------------------
reconstruct_fast_forward() {
  local org_repo="${1:-}"
  [ -n "$org_repo" ] || { echo "usage: reconstruct fast-forward <org>/<new-throwaway-name> [--dry-run]" >&2; return 2; }
  shift
  [[ "$org_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "X reconstruct fast-forward: expected <org>/<name>: $org_repo" >&2; return 2; }
  local dry_run=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=true; shift ;;
      *) echo "X reconstruct fast-forward: unknown flag: $1" >&2; return 2 ;;
    esac
  done
  [ "${LIFECYCLE_TEST_MODE:-}" = "1" ] && dry_run=true
  git rev-parse --git-dir >/dev/null 2>&1 || { echo "X reconstruct fast-forward: run from inside the working clone" >&2; return 2; }
  git show-ref --verify -q refs/heads/dev || { echo "X reconstruct fast-forward: no local dev branch" >&2; return 2; }

  local refs
  refs=$(git for-each-ref --format='%(refname)' refs/heads/dev refs/heads/main refs/heads/pool \
           refs/heads/feature refs/heads/safety refs/heads/vault refs/tags)

  if $dry_run; then
    echo "  · [dry-run] would create $org_repo (private, THROWAWAY-labeled)"
    local ref
    while IFS= read -r ref; do
      case "$ref" in
        refs/tags/*) echo "  · [dry-run] would push: tag ${ref#refs/tags/}" ;;
        *) echo "  · [dry-run] would push: ${ref#refs/heads/}" ;;
      esac
    done <<< "$refs"
    return 0
  fi

  command -v gh >/dev/null 2>&1 || { echo "X reconstruct fast-forward: gh CLI required" >&2; return 2; }
  gh repo create "$org_repo" --private --description "THROWAWAY - reconstruction fast-forward target" >&2 \
    || { echo "X reconstruct fast-forward: gh repo create $org_repo failed" >&2; return 1; }

  local url="${RECONSTRUCT_FF_REMOTE_BASE:-https://github.com}/$org_repo.git"
  local -a refspecs=()
  while IFS= read -r ref; do refspecs+=("$ref:$ref"); done <<< "$refs"
  if ! git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
         push --atomic "$url" ${refspecs[@]+"${refspecs[@]}"}; then
    echo "X reconstruct fast-forward: push to $url failed; nothing was pushed (atomic)" >&2
    return 1
  fi

  local remote missing=0 sha
  remote=$(git -c credential.helper= -c 'credential.helper=!gh auth git-credential' ls-remote "$url") \
    || { echo "X reconstruct fast-forward: could not read back $url" >&2; return 1; }
  while IFS= read -r ref; do
    sha=$(git rev-parse "$ref")
    printf '%s\n' "$remote" | grep -qxF "$sha"$'\t'"$ref" \
      || { echo "X reconstruct fast-forward: $ref did not arrive as $sha" >&2; missing=$((missing+1)); }
  done <<< "$refs"
  [ "$missing" -eq 0 ] || return 1
  echo "ok: fast-forwarded $(printf '%s\n' "$refs" | sed '/^$/d' | wc -l | tr -d ' ') ref(s) to $org_repo, read back verbatim"
}

# ---------------------------------------------------------------------------
# Step 13 - exhaustive per-artifact verification. Manifest lists every
# artifact and its build/link command; loops over every entry in order,
# never spot-checks. Default is fail-fast (matches the documented step);
# --all collects every failure instead of stopping at the first. A failing
# command's last 40 output lines are printed; an unreadable or empty
# manifest is a usage error (exit 2), never a pass.
#
# Manifest shape:
#   [{"name": "moduleA", "build_cmd": "cmake --build build --target moduleA"}, ...]
# ---------------------------------------------------------------------------
reconstruct_verify_artifacts() {
  local manifest="" collect_all=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) collect_all=true; shift ;;
      -*) echo "X reconstruct verify-artifacts: unknown flag: $1" >&2; return 2 ;;
      *) manifest="$1"; shift ;;
    esac
  done
  [ -n "$manifest" ] || { echo "usage: reconstruct verify-artifacts <manifest.json> [--all]" >&2; return 2; }
  [ -f "$manifest" ] || { echo "X reconstruct verify-artifacts: manifest not found: $manifest" >&2; return 2; }

  local work entries
  work=$(mktemp -d -t reconstruct-verify-XXXXXX) || return 1
  entries="$work/entries"
  # NUL separated name/command pairs, so a command may hold any character.
  if ! python3 - "$manifest" > "$entries" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if not isinstance(data, list) or not data:
    sys.exit("manifest must be a non-empty JSON array")
for i, a in enumerate(data):
    if not isinstance(a, dict) or not isinstance(a.get("name"), str) or not isinstance(a.get("build_cmd"), str):
        sys.exit(f"entry {i} needs string name and build_cmd")
    sys.stdout.write(a["name"] + "\0" + a["build_cmd"] + "\0")
PY
  then
    echo "X reconstruct verify-artifacts: unreadable manifest: $manifest" >&2
    rm -rf "$work"; return 2
  fi

  local total i=0 failed=0 name cmd log
  total=$(tr -cd '\0' < "$entries" | wc -c | tr -d ' '); total=$((total / 2))
  while IFS= read -r -d '' name && IFS= read -r -d '' cmd; do
    i=$((i+1))
    echo "[$i/$total] $name: $cmd"
    log="$work/$i.log"
    if bash -c "$cmd" >"$log" 2>&1; then
      echo "  ✓ $name"
    else
      echo "  ✗ $name FAILED; last 40 lines of its output:"
      tail -n 40 "$log" | sed 's/^/    | /'
      failed=$((failed+1))
      if ! $collect_all; then
        echo "X reconstruct verify-artifacts: stopping at first failure ($name); pass --all to collect every failure"
        rm -rf "$work"; return 1
      fi
    fi
  done < "$entries"
  rm -rf "$work"
  [ "$failed" -eq 0 ] || { echo "X reconstruct verify-artifacts: $failed of $total artifact(s) failed"; return 1; }
}

# ---------------------------------------------------------------------------
# Shared by the three [claude] subcommands below.
# ---------------------------------------------------------------------------

# Skill the prompts cite: the per-user override tree first (the rule
# resolve_skill applies), else the copy in this tool's own namespace.
_reconstruct_skill_path() {
  local user_path
  user_path="$(user_skills_dir)/git-reconstruct/SKILL.md"
  if [ -f "$user_path" ]; then
    printf '%s\n' "$user_path"
  else
    printf '%s\n' "$RECONSTRUCT_NS_DIR/skills/git-reconstruct/SKILL.md"
  fi
}

# Run claude and enforce the one line contract: the prompt goes on stdin (a
# file of any size never meets the argv limit), stdout only is read
# (claude's stderr stays on stderr), and the last non-empty line must match
# <pattern>. Any other answer goes to stderr whole and the call fails with 1.
_reconstruct_claude_answer() {
  local pattern="$1" prompt="$2" raw line
  if ! raw=$(printf '%s\n' "$prompt" | claude -p); then
    echo "X reconstruct: claude exited non-zero" >&2
    printf '%s\n' "$raw" >&2
    return 1
  fi
  line=$(printf '%s\n' "$raw" | sed '/^[[:space:]]*$/d' | tail -n 1)
  if printf '%s\n' "$line" | grep -qE "$pattern"; then
    printf '%s\n' "$line"
    return 0
  fi
  echo "X reconstruct: claude answered outside the contract ($pattern):" >&2
  printf '%s\n' "$raw" >&2
  return 1
}

# ---------------------------------------------------------------------------
# [claude] Step 3 - naming/namespace normalization. Rename-only, never
# invents logic. Contract: prints exactly one line, either
#   RENAME: <NewName>
# or
#   QUESTION: <what is ambiguous>
# ---------------------------------------------------------------------------
reconstruct_infer_rename() {
  local old_symbol="${1:?usage: reconstruct infer-rename <old-symbol> <catalog.json>}"
  local catalog="${2:?usage: reconstruct infer-rename <old-symbol> <catalog.json>}"
  [ -f "$catalog" ] || { echo "X reconstruct infer-rename: catalog not found: $catalog" >&2; return 2; }

  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    # Canned, deterministic: case-insensitive substring match against every
    # catalogued class name. Exact confident match -> RENAME; otherwise
    # -> QUESTION. Mirrors the real prompt's own decision rule.
    python3 - "$old_symbol" "$catalog" <<'PY'
import json, sys
old, catalog_path = sys.argv[1], sys.argv[2]
with open(catalog_path) as f:
    spec = json.load(f)
classes = [c for m in spec.get("modules", []) for c in m.get("classes", [])]
match = next((c for c in classes if c.lower() == old.lower()), None)
if match is None:
    match = next((c for c in classes if old.lower() in c.lower() or c.lower() in old.lower()), None)
if match:
    print(f"RENAME: {match}")
else:
    print(f"QUESTION: no confident catalog match for {old}")
PY
    return 0
  fi

  ensure_claude_ready || true
  command -v claude >/dev/null 2>&1 || { echo "X reconstruct infer-rename: claude CLI not installed" >&2; return 3; }
  local skill_path
  skill_path=$(_reconstruct_skill_path)
  local spec_path="$RECONSTRUCT_NS_DIR/docs/Git_Strategy.md"
  local catalog_content
  catalog_content=$(cat "$catalog")
  local prompt
  prompt="Read $skill_path (Step 3) and $spec_path before answering. Old symbol name: $old_symbol. Catalog (JSON): $catalog_content. Task: is this symbol's rename to a catalogued name derivable with reasonable confidence? Rename ONLY - never invent logic to justify a mapping. Reply with EXACTLY one line: either 'RENAME: <NewName>' or 'QUESTION: <what is ambiguous>'. No other output."
  _reconstruct_claude_answer '^(RENAME|QUESTION): .+' "$prompt"
}

# ---------------------------------------------------------------------------
# [claude] Step 3 - genuine-reusability filter. Contract: prints exactly
# one line, either REUSABLE or EXCLUDE: <reason>.
# ---------------------------------------------------------------------------
reconstruct_check_reusability() {
  local file="${1:?usage: reconstruct check-reusability <file>}"
  [ -f "$file" ] || { echo "X reconstruct check-reusability: file not found: $file" >&2; return 2; }

  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    # Canned, deterministic: a literal URL/host-shaped string next to a
    # single-consumer keyword (backend/tenant/cookie/user-agent) => EXCLUDE.
    if grep -qEi 'https?://[a-z0-9.-]+' "$file" && grep -qEi 'backend|tenant|cookie|user-agent' "$file"; then
      echo "EXCLUDE: hardcoded single-consumer detail found (test-mode heuristic)"
    else
      echo "REUSABLE"
    fi
    return 0
  fi

  ensure_claude_ready || true
  command -v claude >/dev/null 2>&1 || { echo "X reconstruct check-reusability: claude CLI not installed" >&2; return 3; }
  local skill_path
  skill_path=$(_reconstruct_skill_path)
  local content
  content=$(cat "$file")
  local prompt
  prompt="Read $skill_path (Step 3, genuine-reusability filter) before answering. File content follows. Task: does this class hardcode a specific backend URL, a specific product's user-agent string, a specific tenant's cookie name, or any other single-consumer detail that would make it consumer-specific business logic wearing a generic name? Reply with EXACTLY one line: either 'REUSABLE' or 'EXCLUDE: <reason>'. No other output.

===== BEGIN FILE =====
$content
===== END FILE ====="
  _reconstruct_claude_answer '^(REUSABLE|EXCLUDE: .+)$' "$prompt"
}

# ---------------------------------------------------------------------------
# [claude] Step 9 - ambiguous remnant-scrub hit review. Contract: prints
# exactly one line, either LEAK: <what to change it to> or
# NOT-A-LEAK: <why>.
# ---------------------------------------------------------------------------
reconstruct_review_scrub_hit() {
  local file="${1:?usage: reconstruct review-scrub-hit <file> <term>}"
  local term="${2:?usage: reconstruct review-scrub-hit <file> <term>}"
  [ -f "$file" ] || { echo "X reconstruct review-scrub-hit: file not found: $file" >&2; return 2; }

  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    # Canned, deterministic: a personal absolute path shape is an
    # unambiguous leak; anything else defaults to NOT-A-LEAK in test mode
    # (real judgment calls are exercised via the live claude path).
    case "$term" in
      /Users/*|/home/*) echo "LEAK: replace with a generic placeholder path" ;;
      *) echo "NOT-A-LEAK: term does not match a known leak shape (test-mode heuristic)" ;;
    esac
    return 0
  fi

  ensure_claude_ready || true
  command -v claude >/dev/null 2>&1 || { echo "X reconstruct review-scrub-hit: claude CLI not installed" >&2; return 3; }
  local skill_path
  skill_path=$(_reconstruct_skill_path)
  local content
  content=$(cat "$file")
  local prompt
  prompt="Read $skill_path (Step 9, remnant scrub categories) before answering. A grep sweep matched the term '$term' in the file below. Task: classify this hit against the five leak categories in Step 9 (prior codenames, personal absolute paths, internal-system self-references, hardcoded self-identity strings, directory-name leaks) versus a coincidental string match or legitimate generic use. Reply with EXACTLY one line: either 'LEAK: <what to change it to>' or 'NOT-A-LEAK: <why>'. No other output.

===== BEGIN FILE =====
$content
===== END FILE ====="
  _reconstruct_claude_answer '^(LEAK|NOT-A-LEAK): .+' "$prompt"
}
