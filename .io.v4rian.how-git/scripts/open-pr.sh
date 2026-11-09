#!/usr/bin/env bash
# open-pr.sh - open (or update) a PR per the v4rian model
#
# Idempotent. Run from any working branch in a v4rian-bootstrapped repo:
#   pool/* → opens or updates a PR into dev
#   dev    → opens or updates a PR into main
#
# Auto-derives:
#   - target branch (dev / main) from current branch
#   - version (full vYYYY.main.dev for pool→dev, release vYYYY.main for dev→main)
#     from `bin/version` (`--next-dev` for pool→dev, `--release-tag` for dev→main)
#   - title prefix [TAG] from the latest commit on the branch
#   - description default from `git log --reverse base..head`
#
# Title format (per feedback_merge_to_main_includes_version):
#   pool/n7.feature.parser_rewrite → dev:
#     [TAG] vYYYY.M.X-b.Y: <short description>
#   dev → main:
#     [MERGE] dev into main: vYYYY.M.X
#
# Dependency policy:
#   REQUIRED: bash, git, curl, python3   (preinstalled on macOS + most Linux)
#   OPTIONAL: gh CLI                      (used only as a token source if present)
#
# Auth token resolution order:
#   1. $GH_TOKEN
#   2. $CREATE_POOL_BRANCH_TOKEN (the same token bin/create-pool-branch uses)
#   3. `gh auth token` (if gh is installed)
#   4. ~/.gcm/store/git/https/github.com/<account>.credential  (first line)
#   5. fails loudly with the exact one-line install/setup command for each option
#
# Usage:
#   open-pr.sh                           open or update PR from current branch
#   open-pr.sh --title "..."             override auto-derived title
#   open-pr.sh --body-file path/to/body  use body from file instead of git log
#   open-pr.sh --body "..."              inline body
#   open-pr.sh --dry-run                 show what would be sent, don't call API
#   open-pr.sh --doctor                  check dependencies + token, exit
#   open-pr.sh -h | --help               print this help

set -euo pipefail

# ----------------------------------------------------------------------------
# Locate the repo root and the namespace dir relative to this script
# ----------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS_DIR=$(basename "$(dirname "$SCRIPT_DIR")")    # e.g. .io.v4rian.how-git
REPO_ROOT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "✗ open-pr.sh: not inside a git repo" >&2
  exit 2
fi

# Auto-activate hooks (no setup script needed). Idempotent.
HOOKS_PATH_OVERRIDE="$NS_DIR/githooks"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"
( cd "$REPO_ROOT" && ensure_hooks_path )

# ----------------------------------------------------------------------------
# Parse flags
# ----------------------------------------------------------------------------
TITLE_OVERRIDE=""
BODY_OVERRIDE=""
BODY_FILE=""
DRY_RUN=false
DOCTOR=false

while [ $# -gt 0 ]; do
  case "$1" in
    --title)      TITLE_OVERRIDE="$2"; shift 2 ;;
    --body)       BODY_OVERRIDE="$2"; shift 2 ;;
    --body-file)  BODY_FILE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --doctor)     DOCTOR=true; shift ;;
    -h|--help)    sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Dependency probe + install hints (no sudo / no brew invoked by this script;
# we surface the exact command the user should run themselves)
# ----------------------------------------------------------------------------

ok() { printf "  ✓ %s\n" "$1"; }
miss() { printf "  ✗ %s - %s\n" "$1" "$2"; }

probe_deps() {
  local fail=0
  echo "→ dependency probe"
  for t in bash git curl python3; do
    if command -v "$t" >/dev/null 2>&1; then
      ok "$t: $(command -v "$t")"
    else
      miss "$t" "REQUIRED - install via your platform's package manager (macOS: 'brew install $t'; Debian/Ubuntu: 'sudo apt install $t'). $t is preinstalled on stock macOS, so missing here means a broken PATH."
      fail=1
    fi
  done

  if command -v gh >/dev/null 2>&1; then
    ok "gh (optional): $(command -v gh)"
  else
    printf "  · gh (optional, used as a token source): not installed. Install with 'brew install gh' (macOS) or 'sudo apt install gh' (Debian/Ubuntu) if you want gh-based auth.\n"
  fi
  return $fail
}

# ----------------------------------------------------------------------------
# Token resolution
# ----------------------------------------------------------------------------
resolve_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    echo "  ✓ token source: \$GH_TOKEN" >&2
    printf '%s' "$GH_TOKEN"; return 0
  fi
  if [ -n "${CREATE_POOL_BRANCH_TOKEN:-}" ]; then
    echo "  ✓ token source: \$CREATE_POOL_BRANCH_TOKEN" >&2
    printf '%s' "$CREATE_POOL_BRANCH_TOKEN"; return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    local t
    t=$(gh auth token 2>/dev/null || true)
    if [ -n "$t" ]; then
      echo "  ✓ token source: gh auth token" >&2
      printf '%s' "$t"; return 0
    fi
  fi
  # GCM plaintext credential store (used by Git Credential Manager when configured)
  local gcm_dir="$HOME/.gcm/store/git/https/github.com"
  if [ -d "$gcm_dir" ]; then
    local f
    for f in "$gcm_dir"/*.credential; do
      [ -f "$f" ] || continue
      local t
      t=$(head -1 "$f" 2>/dev/null || true)
      if [ -n "$t" ]; then
        echo "  ✓ token source: $f" >&2
        printf '%s' "$t"; return 0
      fi
    done
  fi
  cat >&2 <<'EOF'

✗ no GitHub token available. Resolve one of:

  1. Export an existing token:
        export GH_TOKEN=<your-token>

  2. Install gh and log in (recommended; macOS):
        brew install gh && gh auth login

     (Debian/Ubuntu:  sudo apt install gh && gh auth login)

  3. Place a credential file at:
        ~/.gcm/store/git/https/github.com/<your-account>.credential
        (line 1 = the personal-access token)

Then re-run this script.
EOF
  return 3
}

# ----------------------------------------------------------------------------
# Derive owner/repo from origin remote
# ----------------------------------------------------------------------------
derive_owner_repo() {
  local url
  url=$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)
  if [ -z "$url" ]; then
    echo "✗ origin remote not configured" >&2
    return 2
  fi
  # supports https://github.com/owner/repo(.git) and git@github.com:owner/repo(.git)
  echo "$url" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||'
}

# ----------------------------------------------------------------------------
# Derive base branch from HEAD
# ----------------------------------------------------------------------------
derive_base() {
  local head="$1"
  case "$head" in
    pool/*) echo dev ;;
    dev)    echo main ;;
    *)
      echo "✗ HEAD '$head' is not a pool/* working branch or 'dev'. Per the v4rian model only those branches open PRs (pool/* → dev, dev → main)." >&2
      return 2
      ;;
  esac
}

# ----------------------------------------------------------------------------
# Derive the version this PR ASPIRES TO claim. Read from the latest reachable
# v* tag this year - tags are the canonical version state, there is no live
# VERSION file at repo root. This is genuinely aspirational: until the PR
# actually merges and the claim script runs, the real claimed version
# depends on which other PR lands first.
# ----------------------------------------------------------------------------
derive_version() {
  # Delegates to the canonical version utility. pool/* PRs target dev and
  # claim the next dev tag value. dev->main PRs reuse the existing dev tag
  # (same code = same version), so both use --next-dev (which returns the
  # next-to-be-claimed value pre-merge).
  local base="$1"
  local version_bin="$REPO_ROOT/.io.v4rian.how-git/bin/version"
  if [ ! -x "$version_bin" ]; then
    echo "X bin/version not executable - run heal.sh" >&2
    return 2
  fi
  case "$base" in
    dev)  "$version_bin" --next-dev ;;
    main) "$version_bin" --release-tag ;;
  esac
}

# ----------------------------------------------------------------------------
# Title derivation
#   pool/* → dev: [TAG] <version>: <description>
#   dev    → main: [MERGE] dev into main: <release-version>
# ----------------------------------------------------------------------------
derive_title() {
  local head="$1" base="$2" version="$3"
  if [ "$base" = main ]; then
    printf '[MERGE] dev into main: %s' "$version"
    return 0
  fi
  # pool/* → dev path: take latest commit subject on the branch, strip its [TAG]
  local subj tag desc
  subj=$(git -C "$REPO_ROOT" log -1 --format='%s' "$head")
  tag=$(printf '%s' "$subj" | grep -oE '^\[[A-Z]+\]' || echo '[REFACTOR]')
  desc=$(printf '%s' "$subj" | sed -E 's/^\[[A-Z]+\] *//')
  printf '%s %s: %s' "$tag" "$version" "$desc"
}

# ----------------------------------------------------------------------------
# Body resolution: --body > --body-file > default (git log range)
# ----------------------------------------------------------------------------
derive_body() {
  local head="$1" base="$2"
  if [ -n "$BODY_OVERRIDE" ]; then
    printf '%s' "$BODY_OVERRIDE"
    return 0
  fi
  if [ -n "$BODY_FILE" ]; then
    [ -f "$BODY_FILE" ] || { echo "✗ --body-file '$BODY_FILE' not found" >&2; return 2; }
    cat "$BODY_FILE"
    return 0
  fi
  # default: render the commit list for the branch
  git -C "$REPO_ROOT" log --reverse --format='- %s%n%n%w(0,2,2)%b' "origin/$base..$head"
}

# ----------------------------------------------------------------------------
# Look up existing PR for this head branch (idempotency)
# ----------------------------------------------------------------------------
existing_pr_number() {
  local token="$1" owner_repo="$2" owner head="$3"
  owner="${owner_repo%/*}"
  curl -sS -H "Authorization: token $token" \
    "https://api.github.com/repos/$owner_repo/pulls?state=open&head=$owner:$head" \
    | python3 -c "import json,sys; a=json.load(sys.stdin); print(a[0]['number'] if a else '')"
}

# ----------------------------------------------------------------------------
# POST a new PR
# ----------------------------------------------------------------------------
api_create_pr() {
  local token="$1" owner_repo="$2" title="$3" head="$4" base="$5" body="$6"
  local payload
  payload=$(BODY="$body" TITLE="$title" HEAD="$head" BASE="$base" \
    python3 -c "import json,os; print(json.dumps({'title':os.environ['TITLE'],'head':os.environ['HEAD'],'base':os.environ['BASE'],'body':os.environ['BODY']}))")
  curl -sS -X POST \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.github.com/repos/$owner_repo/pulls"
}

# ----------------------------------------------------------------------------
# PATCH an existing PR (title + body)
# ----------------------------------------------------------------------------
api_patch_pr() {
  local token="$1" owner_repo="$2" number="$3" title="$4" body="$5"
  local payload
  payload=$(BODY="$body" TITLE="$title" \
    python3 -c "import json,os; print(json.dumps({'title':os.environ['TITLE'],'body':os.environ['BODY']}))")
  curl -sS -X PATCH \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.github.com/repos/$owner_repo/pulls/$number"
}

# ----------------------------------------------------------------------------
# --doctor mode: check + report, then exit
# ----------------------------------------------------------------------------
if $DOCTOR; then
  probe_deps || true
  echo "→ token probe"
  resolve_token >/dev/null && echo "  (token resolved)" || true
  exit 0
fi

# ----------------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------------
probe_deps >/dev/null || {
  echo "✗ open-pr.sh: required dependency missing - run 'open-pr.sh --doctor' to see which" >&2
  exit 3
}

HEAD=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
BASE=$(derive_base "$HEAD")
OWNER_REPO=$(derive_owner_repo)
VERSION=$(derive_version "$BASE")

# branch-name guardrail for pool/*: enforce the regex (the pre-push hook does
# this too, but enforcing here means we never POST a malformed branch to GH).
# Accepts both the legacy flat layout and the vYYYY.MAIN/ prefixed layout so
# branches allocated under either scheme can open PRs into dev.
if [ "$BASE" = dev ]; then
  if ! [[ "$HEAD" =~ $HG_POOL_BRANCH_RE ]]; then
    echo "✗ branch '$HEAD' does not match the v4rian pool/* shape: $HG_POOL_BRANCH_RE" >&2
    exit 2
  fi
fi

if [ -n "$TITLE_OVERRIDE" ]; then
  TITLE="$TITLE_OVERRIDE"
else
  TITLE=$(derive_title "$HEAD" "$BASE" "$VERSION")
fi
BODY=$(derive_body "$HEAD" "$BASE")

echo "→ owner/repo: $OWNER_REPO"
echo "→ head:       $HEAD"
echo "→ base:       $BASE"
echo "→ version:    $VERSION"
echo "→ title:      $TITLE"
echo "→ body chars: ${#BODY}"

TOKEN=$(resolve_token)

EXISTING=$(existing_pr_number "$TOKEN" "$OWNER_REPO" "$HEAD")

if $DRY_RUN; then
  echo
  echo "[dry-run] no API calls made"
  if [ -n "$EXISTING" ]; then
    echo "[dry-run] would PATCH PR #$EXISTING"
  else
    echo "[dry-run] would POST new PR ($HEAD → $BASE)"
  fi
  exit 0
fi

if [ -n "$EXISTING" ]; then
  echo "→ updating existing PR #$EXISTING"
  RESP=$(api_patch_pr "$TOKEN" "$OWNER_REPO" "$EXISTING" "$TITLE" "$BODY")
else
  echo "→ creating new PR"
  RESP=$(api_create_pr "$TOKEN" "$OWNER_REPO" "$TITLE" "$HEAD" "$BASE" "$BODY")
fi

# Parse response
URL=$(echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('html_url',''))" 2>/dev/null || true)
NUM=$(echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('number',''))" 2>/dev/null || true)

if [ -z "$URL" ]; then
  echo "✗ API call returned no html_url - full response:" >&2
  echo "$RESP" | python3 -m json.tool >&2 || echo "$RESP" >&2
  exit 1
fi

echo
if [ -n "$EXISTING" ]; then
  echo "✓ updated PR #$NUM"
else
  echo "✓ created PR #$NUM"
fi
echo "$URL"
