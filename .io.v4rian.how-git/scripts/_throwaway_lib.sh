#!/usr/bin/env bash
# _throwaway_lib.sh - shared helpers for operator-run canary scripts that
# create a real GitHub throwaway repo from the how-git template, exercise
# the framework against it, then delete it.
#
# Sourced (not executed). Provides:
#
#   throwaway_resolve_token        - returns the first GitHub token reachable
#                                    via: $GH_TOKEN, $CREATE_POOL_BRANCH_TOKEN,
#                                    `gh auth token` (if installed), or line 1
#                                    of any *.credential file under
#                                    $HOME/.gcm/store/git/https/github.com.
#                                    Returns 1 when nothing resolves so the
#                                    caller can refuse the run cleanly.
#
#   throwaway_default_template     - derives "owner/repo" from this repo's
#                                    origin URL (via git config). The
#                                    framework never hardcodes a default
#                                    template; an origin swap retests
#                                    connectivity in one step.
#
#   throwaway_default_name <prefix> - produces "<prefix>-<UTC-stamp>" so
#                                    each invocation lands a uniquely
#                                    named throwaway.
#
#   throwaway_check_deps           - probes the shared deps (bash, git,
#                                    curl, python3) and exits 3 with a
#                                    message naming the missing tool.
#                                    Callers append script-specific deps
#                                    after invoking this.
#
#   throwaway_create_from_template <token> <template_repo> <account> <name>
#                                  - POSTs the GitHub /generate API to seed
#                                    a throwaway repo from <template_repo>'s
#                                    default branch. Requires
#                                    is_template=true on the source. Echoes
#                                    the new repo's html_url on success.
#                                    Returns non-zero on failure with a
#                                    diagnostic on stderr.
#
#   throwaway_create_empty <token> <account> <name>
#                                  - POSTs /user/repos (or /orgs/<account>/repos
#                                    for an org) to create an empty throwaway,
#                                    private unless THROWAWAY_PRIVATE=false.
#                                    Echoes html_url on success. Used by
#                                    the --from-branch seed path that the
#                                    /generate API cannot serve.
#
#   throwaway_seed_from_branch <token> <template_repo> <ref> <clone_url> <test_dir>
#                                  - Clones <template_repo>@<ref>, builds a
#                                    single-commit orphan branch carrying
#                                    that tree, and pushes it to
#                                    <clone_url>'s main. Mirrors what
#                                    /generate produces but works against
#                                    any named ref. The temp source clone
#                                    lands under <test_dir>/source.
#
#   throwaway_clone_with_retry <clone_url> <dest> [max_tries]
#                                  - /generate is asynchronous; the repo's
#                                    refs are sometimes reachable before
#                                    the working tree is populated. This
#                                    helper retries clone-and-populate up
#                                    to <max_tries> (default 30, 2s apart)
#                                    and only returns 0 when the working
#                                    tree carries at least one entry other
#                                    than .git/. Echoes the final populated
#                                    entry count for the caller's log.
#
#   throwaway_adopt_identity <account>
#                                  - Run inside the throwaway clone. Exports
#                                    GIT_AUTHOR_* and GIT_COMMITTER_* for the
#                                    clone's mapped identity (bin/identity,
#                                    origin org = <account>) so canary commits
#                                    pass the identity gates exactly as an
#                                    operator's would. An account without a
#                                    mapping gets one in identity-map.local
#                                    (consumer-owned, never committed):
#                                    "<account> <account>@users.noreply.github.com
#                                    <account>-canary".
#
#   throwaway_delete <token> <account> <name>
#                                  - DELETEs the throwaway via API. Echoes
#                                    the HTTP status code so the caller
#                                    can branch on 204 / 403 / 404 /
#                                    other. Never aborts on non-204 - a
#                                    403 from a missing delete_repo scope
#                                    is a known orphan condition, not a
#                                    canary failure.
#
# Source via:
#   SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
#   . "$SCRIPT_DIR/_throwaway_lib.sh"

# THROWAWAY_PRIVATE=false (the canaries' --public flag) creates public
# throwaways: GitHub gives private repos on a free plan no branch
# protection or rulesets, so connected mode is only testable live there on
# a public repo. Default private.
throwaway_private_json() {
  case "${THROWAWAY_PRIVATE:-true}" in
    false|0|no) echo false ;;
    *) echo true ;;
  esac
}

throwaway_resolve_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"; return 0
  fi
  if [ -n "${CREATE_POOL_BRANCH_TOKEN:-}" ]; then
    printf '%s' "$CREATE_POOL_BRANCH_TOKEN"; return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    local t
    t=$(gh auth token 2>/dev/null || true)
    [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  fi
  local gcm_dir="$HOME/.gcm/store/git/https/github.com"
  if [ -d "$gcm_dir" ]; then
    local f t
    for f in "$gcm_dir"/*.credential; do
      [ -f "$f" ] || continue
      t=$(head -1 "$f" 2>/dev/null || true)
      [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    done
  fi
  return 1
}

throwaway_default_template() {
  local template_root="$1"
  ( cd "$template_root" 2>/dev/null && git config --get remote.origin.url 2>/dev/null \
      | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||' )
}

throwaway_default_name() {
  local prefix="$1"
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  printf '%s-%s' "$prefix" "$stamp"
}

throwaway_check_deps() {
  local t
  for t in bash git curl python3; do
    if ! command -v "$t" >/dev/null 2>&1; then
      echo "X throwaway helper: missing dependency '$t' (install via your platform's package manager)" >&2
      exit 3
    fi
  done
}

throwaway_create_from_template() {
  local token="$1" template_repo="$2" account="$3" name="$4"
  local src_info is_template payload gen_resp gen_url
  src_info=$(curl -sS -H "Authorization: token $token" "https://api.github.com/repos/$template_repo")
  is_template=$(echo "$src_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('is_template'))" 2>/dev/null || echo "False")
  if [ "$is_template" != "True" ]; then
    echo "X $template_repo is_template=$is_template; flip it on or pass --from-branch <ref>" >&2
    return 1
  fi
  payload=$(NAME="$name" OWNER="$account" PRIV="$(throwaway_private_json)" python3 -c "
import json, os
print(json.dumps({
  'owner': os.environ['OWNER'],
  'name':  os.environ['NAME'],
  'description': 'Throwaway canary verification of how-git (delete me)',
  'private': os.environ['PRIV'] == 'true',
  'include_all_branches': False,
}))")
  gen_resp=$(curl -sS -X POST \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.github.com/repos/$template_repo/generate")
  gen_url=$(echo "$gen_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('html_url',''))")
  if [ -z "$gen_url" ]; then
    echo "X /generate failed; response:" >&2
    echo "$gen_resp" | python3 -m json.tool >&2 || echo "$gen_resp" >&2
    return 1
  fi
  printf '%s' "$gen_url"
}

throwaway_create_empty() {
  local token="$1" account="$2" name="$3"
  local payload create_resp gen_url endpoint="https://api.github.com/user/repos"
  # /user/repos always creates under the token's own user; an org account
  # needs its own endpoint or the throwaway lands in the wrong place.
  if [ "$(curl -sS -H "Authorization: token $token" "https://api.github.com/users/$account" \
          | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))" 2>/dev/null)" = "Organization" ]; then
    endpoint="https://api.github.com/orgs/$account/repos"
  fi
  payload=$(NAME="$name" PRIV="$(throwaway_private_json)" python3 -c "
import json, os
print(json.dumps({
  'name': os.environ['NAME'],
  'description': 'Throwaway canary verification of how-git (delete me)',
  'private': os.environ['PRIV'] == 'true',
  'auto_init': False,
}))")
  create_resp=$(curl -sS -X POST \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$endpoint")
  gen_url=$(echo "$create_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('html_url',''))")
  if [ -z "$gen_url" ]; then
    echo "X empty repo creation failed; response:" >&2
    echo "$create_resp" | python3 -m json.tool >&2 || echo "$create_resp" >&2
    return 1
  fi
  printf '%s' "$gen_url"
}

throwaway_seed_from_branch() {
  local token="$1" template_repo="$2" ref="$3" clone_url="$4" test_dir="$5"
  local src_clone="$test_dir/source"
  git clone -q --branch "$ref" --single-branch \
    "https://x-access-token:$token@github.com/$template_repo.git" "$src_clone" || return 1
  ( cd "$src_clone"
    git checkout -q --orphan _seed
    git -c user.email="throwaway-canary@local" -c user.name="throwaway-canary" \
        commit -q -m "Initial commit"
    git push -q "$clone_url" _seed:main
  )
}

throwaway_adopt_identity() {
  local account="$1" ns=.io.v4rian.how-git exports
  if ! exports=$(bash "$ns/bin/identity" --export 2>/dev/null); then
    printf '%s %s %s\n' "$account" "$account@users.noreply.github.com" \
      "$account-canary" >> "$ns/identity-map.local"
    printf '%s\n' "/$ns/identity-map.local" >> "$(git rev-parse --git-path info/exclude)"
    exports=$(bash "$ns/bin/identity" --export) || return 1
  fi
  eval "$exports"
}

throwaway_clone_with_retry() {
  local clone_url="$1" dest="$2" max_tries="${3:-30}"
  local tries=0 populated=0
  while :; do
    rm -rf "$dest"
    if git clone -q "$clone_url" "$dest" 2>/dev/null; then
      populated=$(ls -A1 "$dest" 2>/dev/null | grep -vc '^\.git$' || true)
      if [ "${populated:-0}" -gt 0 ]; then
        printf '%s' "$populated"
        return 0
      fi
    fi
    tries=$((tries+1))
    if [ "$tries" -ge "$max_tries" ]; then
      echo "X throwaway not populated after $max_tries attempts" >&2
      return 1
    fi
    sleep 2
  done
}

throwaway_delete() {
  local token="$1" account="$2" name="$3"
  local del_code
  del_code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Authorization: token $token" \
    "https://api.github.com/repos/$account/$name")
  printf '%s' "$del_code"
}
