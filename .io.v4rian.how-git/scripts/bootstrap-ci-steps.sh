#!/usr/bin/env bash
# bootstrap-ci-steps.sh - step engine for the bootstrap-ci.yml workflow.
#
# Each step_* function below mirrors the prior bin/bootstrap-ci layout
# one to one. The workflow invokes one step per YAML step via:
#
#   bash .io.v4rian.how-git/scripts/bootstrap-ci-steps.sh <step_name>
#
# where <step_name> is the bare suffix after step_ (e.g. actions_enabled,
# workflows_enabled, seed_dev, apply_rules, required_checks,
# merge_commit_defaults, merge_mode_lock, disable_auto_delete, topics,
# claude_setup, consumer_cleanup, report). Splitting the engine out of
# bin/bootstrap-ci lets the YAML stay readable while keeping the existing
# step logic verbatim.
#
# Environment contract (set by the workflow before invocation):
#   GH_TOKEN     authoritative GitHub token; mirrors TOKEN for legacy use
#   TOKEN        same value; api_call reads $TOKEN
#   OWNER_REPO   owner/repo slug derived from $GITHUB_REPOSITORY
#   REPO_ROOT    workspace path; defaults to git toplevel when absent
#   NS_DIR       framework namespace dir name (.io.v4rian.how-git)
#   MODE         apply | check | dry-run
#   TOKEN_SRC    free-form provenance string echoed by step_report
#
# Operates under secrets.GITHUB_TOKEN. GITHUB_TOKEN does not grant the
# administration scope, so ruleset POSTs and branch protection PUTs that
# require admin will surface 422s in the workflow log; apply-repo-rules.sh
# has soft-skip handlers for the known cases (Integration bypass actor,
# Name must be unique). The workflow log is the operator-facing surface
# for those visible-error outcomes.

set -uo pipefail

# Loud-on-failure EXIT trap. Only fires on non-zero exit; intentional
# success exits stay silent so silence keeps its sh-land meaning. Bash
# 3.2 LINENO inside a trap is unreliable so it is omitted; $BASH_COMMAND
# carries the last command which is enough to localize the failure.
trap '_rc=$?; if [ "$_rc" -ne 0 ]; then printf "\nX %s exited with status %d (last command: %s)\n" "$(basename "$0")" "$_rc" "$BASH_COMMAND" >&2; fi' EXIT

# ----------------------------------------------------------------------------
# Required env. The workflow exports every value before invocation; the
# fallbacks below cover ad hoc local invocation (running a single step from
# a workstation shell for debugging) but the canonical caller is the YAML.
# ----------------------------------------------------------------------------
if [ -z "${TOKEN:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
  TOKEN="$GH_TOKEN"
fi
if [ -z "${TOKEN:-}" ]; then
  echo "X bootstrap-ci-steps: TOKEN (or GH_TOKEN) not set" >&2
  exit 3
fi

if [ -z "${REPO_ROOT:-}" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
if [ -z "$REPO_ROOT" ]; then
  echo "X bootstrap-ci-steps: REPO_ROOT not resolvable (not inside a git repo)" >&2
  exit 2
fi

NS_DIR="${NS_DIR:-.io.v4rian.how-git}"
MODE="${MODE:-apply}"
TOKEN_SRC="${TOKEN_SRC:-actions secrets}"

if [ -z "${OWNER_REPO:-}" ]; then
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    OWNER_REPO="$GITHUB_REPOSITORY"
  else
    OWNER_REPO=$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null \
      | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||' || true)
  fi
fi
if [ -z "$OWNER_REPO" ]; then
  echo "X bootstrap-ci-steps: OWNER_REPO not resolvable" >&2
  exit 2
fi

# ----------------------------------------------------------------------------
# Logging helpers (match open-pr.sh tone)
# ----------------------------------------------------------------------------
ok()   { printf "  ok   %s\n" "$1"; }
miss() { printf "  miss %s - %s\n" "$1" "$2"; }
skip() { printf "  skip %s - %s\n" "$1" "$2"; }
note() { printf "  .    %s\n" "$1"; }
hdr()  { printf "\n-> %s\n" "$1"; }

# ----------------------------------------------------------------------------
# Thin curl wrapper that respects the mode (check / dry-run / apply)
# ----------------------------------------------------------------------------
api_call() {
  local method="$1" path="$2" body="${3:-}"
  local url="https://api.github.com/$path"
  if [ "$MODE" = "dry-run" ]; then
    if [ -n "$body" ]; then
      printf '  [dry-run] %s %s\n            body: %s\n' "$method" "$url" "$body"
    else
      printf '  [dry-run] %s %s\n' "$method" "$url"
    fi
    return 0
  fi
  if [ -n "$body" ]; then
    curl -sS -X "$method" \
      -H "Authorization: token $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "$url"
  else
    curl -sS -X "$method" \
      -H "Authorization: token $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$url"
  fi
}

# ----------------------------------------------------------------------------
# Step 1: verify Actions is enabled on the repo
# ----------------------------------------------------------------------------
step_actions_enabled() {
  hdr "step 1: Actions enabled"
  local resp enabled
  resp=$(curl -sS \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER_REPO/actions/permissions" 2>/dev/null || true)
  enabled=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(str(d.get('enabled','')).lower())
except Exception:
    print('error')" 2>/dev/null || echo error)
  case "$enabled" in
    true) ok "Actions enabled for $OWNER_REPO" ;;
    false)
      case "$MODE" in
        check)
          miss "Actions" "currently DISABLED on $OWNER_REPO"
          note "operator step: GitHub web UI -> Settings -> Actions -> General -> 'Allow all actions and reusable workflows'"
          ;;
        dry-run)
          note "[dry-run] would enable Actions: PUT /repos/$OWNER_REPO/actions/permissions {\"enabled\":true,\"allowed_actions\":\"all\"}"
          ;;
        apply)
          # SET, don't advise: a consumer without Actions has no framework -
          # every event-triggered gate (validate, audits, claims) silently
          # never runs while workflow_dispatch still works, which masks it.
          note "Actions disabled; enabling (all actions and reusable workflows)"
          curl -sS -X PUT \
            -H "Authorization: token $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER_REPO/actions/permissions" \
            -d '{"enabled":true,"allowed_actions":"all"}' >/dev/null 2>&1 || true
          # truth-from-state: re-read and hard-fail if the toggle did not land
          resp=$(curl -sS \
            -H "Authorization: token $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER_REPO/actions/permissions" 2>/dev/null || true)
          enabled=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    print(str(json.load(sys.stdin).get('enabled','')).lower())
except Exception:
    print('error')" 2>/dev/null || echo error)
          if [ "$enabled" = "true" ]; then
            ok "Actions enabled for $OWNER_REPO (set + verified)"
          else
            miss "Actions" "PUT did not stick (verify returned '$enabled'); token may lack 'administration'"
            echo "X bootstrap-ci: Actions could not be enabled on $OWNER_REPO; no event-triggered CI can run. Aborting." >&2
            exit 4
          fi
          ;;
      esac
      ;;
    error|*)
      miss "Actions" "could not read actions permissions (token may lack 'administration' scope)"
      ;;
  esac
}

# ----------------------------------------------------------------------------
# Step 1b: every shipped workflow is in the active state
# ----------------------------------------------------------------------------
step_workflows_enabled() {
  hdr "step 1b: per-workflow enable state"
  local wf_dir registered
  wf_dir="$REPO_ROOT/.github/workflows"
  if [ ! -d "$wf_dir" ]; then
    note "no .github/workflows dir on disk; nothing to enable"
    return 0
  fi
  registered=$(curl -sS \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER_REPO/actions/workflows?per_page=100" 2>/dev/null || true)
  if [ -z "$registered" ]; then
    miss "workflows" "could not read /actions/workflows from the API"
    return 0
  fi
  local file basename state
  for file in "$wf_dir"/*.yml "$wf_dir"/*.yaml; do
    [ -f "$file" ] || continue
    basename=$(basename "$file")
    state=$(printf '%s' "$registered" | WF_NAME="$basename" python3 -c "import json,sys,os
name=os.environ['WF_NAME']
try:
    d=json.load(sys.stdin)
    for w in d.get('workflows',[]):
        p=w.get('path','')
        if p.endswith('/'+name) or p == name:
            print(w.get('state',''))
            sys.exit(0)
    print('not_registered')
except Exception:
    print('error')" 2>/dev/null || echo error)
    case "$state" in
      active)
        ok "$basename active"
        ;;
      disabled_manually|disabled_inactivity)
        if [ "$MODE" = "check" ]; then
          miss "$basename" "registered but state=$state (would enable)"
        elif [ "$MODE" = "dry-run" ]; then
          note "[dry-run] PUT /repos/$OWNER_REPO/actions/workflows/$basename/enable"
        else
          local rc
          rc=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
            -H "Authorization: token $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER_REPO/actions/workflows/$basename/enable" 2>/dev/null || echo 000)
          case "$rc" in
            204) ok "$basename re-enabled (was $state)" ;;
            *)   miss "$basename" "enable returned HTTP $rc" ;;
          esac
        fi
        ;;
      not_registered)
        note "$basename not registered yet (no trigger has fired; auto-registers on first run)"
        ;;
      error|"")
        miss "$basename" "could not read state from API response"
        ;;
      *)
        note "$basename state=$state (no action)"
        ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# Step 2: verify dev branch exists; seed from main if missing
# ----------------------------------------------------------------------------
step_seed_dev() {
  hdr "step 2: dev branch exists on origin"
  local resp dev_sha main_sha
  resp=$(curl -sS \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER_REPO/branches/dev" 2>/dev/null || true)
  dev_sha=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('commit',{}).get('sha',''))
except Exception:
    print('')" 2>/dev/null || true)
  if [ -n "$dev_sha" ]; then
    ok "dev exists at $dev_sha"
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    miss "dev" "branch absent on origin"
    return 0
  fi

  # Read main's SHA to seed dev at the same commit
  resp=$(curl -sS \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER_REPO/branches/main" 2>/dev/null || true)
  main_sha=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('commit',{}).get('sha',''))
except Exception:
    print('')" 2>/dev/null || true)
  if [ -z "$main_sha" ]; then
    miss "dev" "could not read main's SHA to seed from"
    return 1
  fi
  local body
  body=$(SHA="$main_sha" python3 -c "import json,os; print(json.dumps({'ref':'refs/heads/dev','sha':os.environ['SHA']}))")
  api_call POST "repos/$OWNER_REPO/git/refs" "$body" >/dev/null
  ok "dev seeded at $main_sha (matches main)"
}

# ----------------------------------------------------------------------------
# Step 3 + 4: apply branch protection + Repository Rules via apply-repo-rules.sh
# ----------------------------------------------------------------------------
step_apply_rules() {
  hdr "step 3+4: branch protection + Repository Rules"
  local apply="$REPO_ROOT/$NS_DIR/scripts/apply-repo-rules.sh"
  if [ ! -x "$apply" ]; then
    miss "apply-repo-rules.sh" "not present or not executable at $apply"
    return 1
  fi

  if [ "$MODE" = "check" ]; then
    note "would invoke apply-repo-rules.sh against $OWNER_REPO (skipping in check mode)"
    return 0
  fi
  if [ "$MODE" = "dry-run" ]; then
    printf '  [dry-run] %s with ORG=%s REPO=%s\n' \
      "$apply" "${OWNER_REPO%/*}" "${OWNER_REPO#*/}"
    return 0
  fi

  note "delegating to apply-repo-rules.sh"

  ORG="${OWNER_REPO%/*}" \
  REPO="${OWNER_REPO#*/}" \
  GH_TOKEN="$TOKEN" \
  bash "$apply"
}

# ----------------------------------------------------------------------------
# Step 5: bind required status checks on PRs to dev.
# ----------------------------------------------------------------------------
step_required_checks() {
  hdr "step 5: required status checks"
  # reconcile is seeded by validate-pr-open from live mergeability and
  # refreshed by every reconcile pass; binding it required makes a
  # conflicting PR read red instead of stale green beside the conflict
  # banner. Hard wired like opened-via-correct-flow: neither lives as a
  # required.*.sh file the discovery walk could find.
  local dev_checks=("opened-via-correct-flow" "reconcile")
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    dev_checks+=("$c")
  done < <(_discover_required_checks push)
  local main_checks=("doc-freshness")
  _bind_required_checks main ${main_checks[@]+"${main_checks[@]}"}
  _bind_required_checks dev ${dev_checks[@]+"${dev_checks[@]}"}
}

# Helper: walk ci/{tests,audits}/<trigger>/required.*.sh under both layers.
_discover_required_checks() {
  local trigger="$1"
  local layer kind dir f bn name
  {
    for layer in "ci" ".io.v4rian.how-git/ci"; do
      for kind in tests audits; do
        dir="$REPO_ROOT/$layer/$kind/$trigger"
        [ -d "$dir" ] || continue
        while IFS= read -r f; do
          [ -f "$f" ] || continue
          bn=$(basename "$f")
          case "$bn" in
            required.*.sh)
              name="${bn%.sh}"
              printf '%s\n' "$name"
              ;;
          esac
        done < <(find "$dir" -maxdepth 1 -type f -name 'required.*.sh' 2>/dev/null | sort)
      done
    done
  } | sort -u
}

# Helper: bind the supplied required-status-check contexts on the given branch.
_bind_required_checks() {
  local branch="$1"; shift
  local wanted=("$@")
  local resp current
  resp=$(curl -sS \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER_REPO/branches/$branch/protection/required_status_checks" 2>/dev/null || true)
  current=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    ctx=d.get('contexts',[])
    print('\n'.join(ctx))
except Exception:
    print('')" 2>/dev/null || true)

  local missing=()
  local c
  for c in ${wanted[@]+"${wanted[@]}"}; do
    if printf '%s\n' "$current" | grep -Fxq "$c"; then
      ok "$branch already requires '$c'"
    else
      missing+=("$c")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    for c in ${missing[@]+"${missing[@]}"}; do
      miss "$branch" "missing required check '$c'"
    done
    return 0
  fi

  local merged body all
  all=$(printf '%s\n' "$current" ${missing[@]+"${missing[@]}"} | grep -v '^$')
  merged=$(printf '%s\n' "$all" | sort -u | python3 -c "import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
  body=$(CTX="$merged" python3 -c "import json,os; print(json.dumps({'strict':True,'contexts':json.loads(os.environ['CTX'])}))")
  if [ "$MODE" = "dry-run" ]; then
    api_call PATCH "repos/$OWNER_REPO/branches/$branch/protection/required_status_checks" "$body"
  else
    api_call PATCH "repos/$OWNER_REPO/branches/$branch/protection/required_status_checks" "$body" >/dev/null
  fi
  for c in ${missing[@]+"${missing[@]}"}; do
    ok "$branch now requires '$c'"
  done
}

# ----------------------------------------------------------------------------
# Step 6: merge-commit defaults.
# ----------------------------------------------------------------------------
step_merge_commit_defaults() {
  hdr "step 6: merge-commit defaults (subject=PR_TITLE, body=PR_BODY)"
  local resp title msg
  resp=$(curl -sS \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER_REPO" 2>/dev/null || true)
  title=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('merge_commit_title',''))
except Exception:
    print('')" 2>/dev/null || true)
  msg=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('merge_commit_message',''))
except Exception:
    print('')" 2>/dev/null || true)

  if [ "$title" = "PR_TITLE" ] && [ "$msg" = "PR_BODY" ]; then
    ok "merge_commit_title=PR_TITLE, merge_commit_message=PR_BODY already set"
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    [ "$title" = "PR_TITLE" ] || miss "merge_commit_title" "is '$title' (want PR_TITLE)"
    [ "$msg"   = "PR_BODY"  ] || miss "merge_commit_message" "is '$msg' (want PR_BODY)"
    return 0
  fi

  local body='{"merge_commit_title":"PR_TITLE","merge_commit_message":"PR_BODY"}'
  if [ "$MODE" = "dry-run" ]; then
    api_call PATCH "repos/$OWNER_REPO" "$body"
  else
    api_call PATCH "repos/$OWNER_REPO" "$body" >/dev/null
  fi
  ok "merge_commit_title=PR_TITLE, merge_commit_message=PR_BODY"
}

# ----------------------------------------------------------------------------
# Step 7: lock merge mode to --no-ff merge commits only.
# ----------------------------------------------------------------------------
step_merge_mode_lock() {
  hdr "step 7: merge mode lock (no-ff merge commits only)"
  local resp squash rebase merge
  resp=$(curl -sS \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER_REPO" 2>/dev/null || true)
  squash=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(str(d.get('allow_squash_merge','')).lower())
except Exception:
    print('')" 2>/dev/null || true)
  rebase=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(str(d.get('allow_rebase_merge','')).lower())
except Exception:
    print('')" 2>/dev/null || true)
  merge=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(str(d.get('allow_merge_commit','')).lower())
except Exception:
    print('')" 2>/dev/null || true)

  if [ "$squash" = "false" ] && [ "$rebase" = "false" ] && [ "$merge" = "true" ]; then
    ok "merge mode already locked (squash off, rebase off, merge on)"
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    [ "$squash" = "false" ] || miss "allow_squash_merge" "is '$squash' (want false)"
    [ "$rebase" = "false" ] || miss "allow_rebase_merge" "is '$rebase' (want false)"
    [ "$merge"  = "true"  ] || miss "allow_merge_commit"  "is '$merge' (want true)"
    return 0
  fi

  local body='{"allow_squash_merge":false,"allow_rebase_merge":false,"allow_merge_commit":true}'
  if [ "$MODE" = "dry-run" ]; then
    api_call PATCH "repos/$OWNER_REPO" "$body"
  else
    api_call PATCH "repos/$OWNER_REPO" "$body" >/dev/null
  fi
  ok "merge mode locked (squash off, rebase off, merge on)"
}

# ----------------------------------------------------------------------------
# Step 8: disable auto-delete of merged branches.
# ----------------------------------------------------------------------------
step_disable_auto_delete() {
  hdr "step 8: disable auto-delete of merged branches"
  local resp current
  resp=$(curl -sS \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER_REPO" 2>/dev/null || true)
  current=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(str(d.get('delete_branch_on_merge','')).lower())
except Exception:
    print('')" 2>/dev/null || true)

  if [ "$current" = "false" ]; then
    ok "delete_branch_on_merge already false"
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    miss "delete_branch_on_merge" "is '$current' (want false)"
    return 0
  fi

  local body='{"delete_branch_on_merge":false}'
  if [ "$MODE" = "dry-run" ]; then
    api_call PATCH "repos/$OWNER_REPO" "$body"
  else
    api_call PATCH "repos/$OWNER_REPO" "$body" >/dev/null
  fi
  ok "delete_branch_on_merge=false"
}

# ----------------------------------------------------------------------------
# Step 9: repo topics for v4rian identification.
# ----------------------------------------------------------------------------
step_topics() {
  hdr "step 9: repo topics (v4rian, how-git)"
  local resp current_json wanted="v4rian how-git"
  resp=$(curl -sS \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github.mercy-preview+json" \
    "https://api.github.com/repos/$OWNER_REPO/topics" 2>/dev/null || true)
  current_json=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(json.dumps(d.get('names',[])))
except Exception:
    print('[]')" 2>/dev/null || echo '[]')

  local missing_list
  missing_list=$(CUR="$current_json" WANT="$wanted" python3 -c "import json,os
cur=set(json.loads(os.environ['CUR']))
want=os.environ['WANT'].split()
miss=[w for w in want if w not in cur]
print(' '.join(miss))" 2>/dev/null || echo "")

  if [ -z "$missing_list" ]; then
    ok "topics already include v4rian + how-git"
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    local t
    for t in $missing_list; do
      miss "topic '$t'" "not set on repo"
    done
    return 0
  fi

  local merged_body
  merged_body=$(CUR="$current_json" WANT="$wanted" python3 -c "import json,os
cur=json.loads(os.environ['CUR'])
want=os.environ['WANT'].split()
seen=set(cur)
out=list(cur)
for w in want:
    if w not in seen:
        out.append(w); seen.add(w)
print(json.dumps({'names':out}))")
  if [ "$MODE" = "dry-run" ]; then
    api_call PUT "repos/$OWNER_REPO/topics" "$merged_body"
  else
    api_call PUT "repos/$OWNER_REPO/topics" "$merged_body" >/dev/null
  fi
  local t
  for t in $missing_list; do
    ok "topic '$t' added"
  done
}

# ----------------------------------------------------------------------------
# Step 9b: claude CLI install + CLAUDE_CODE_OAUTH_TOKEN secret probe.
# ----------------------------------------------------------------------------
# Environments that hold the CI secrets (docs/ci-trust-model.md). A job on
# any ref outside an environment's deployment policy cannot read its
# secrets, whatever the workflow file says. "name|branch,...|tag,..."
TRUSTED_ENVS="v4rian-trusted|dev,main|v*
v4rian-canary|dev,main|"
# Secrets that belong in v4rian-trusted, never at repository level.
TRUSTED_SECRETS="CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CI_BOT_APP_PRIVATE_KEY"

step_trusted_env() {
  hdr "step 9a: protected environments for the CI secrets"
  local line name branches tags have want t kind
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%|*}; branches=$(printf '%s' "$line" | cut -d'|' -f2); tags=$(printf '%s' "$line" | cut -d'|' -f3)
    have=$(curl -sS -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER_REPO/environments/$name/deployment-branch-policies?per_page=100" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(" ".join(sorted(p["type"] + ":" + p["name"] for p in d.get("branch_policies", []))))
except Exception:
    print("?")' 2>/dev/null || echo "?")
    want=$( { for t in $(printf '%s' "$branches" | tr ',' ' '); do echo "branch:$t"; done
              for t in $(printf '%s' "$tags" | tr ',' ' '); do echo "tag:$t"; done; } | sort | tr '\n' ' ' | sed 's/ $//')
    if [ "$have" = "$want" ]; then ok "$name admits only $want"; continue; fi
    case "$MODE" in
      check) miss "$name" "deployment policy is [${have:-none}], want [$want]"; continue ;;
    esac
    local resp
    resp=$(api_call PUT "repos/$OWNER_REPO/environments/$name" \
      '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}')
    if [ "$MODE" != "dry-run" ] && ! printf '%s' "$resp" | grep -q '"name"'; then
      miss "$name" "environment create failed: $(printf '%s' "$resp" | tr -d '\n' | cut -c1-200)"
      note "environments with branch policies need a public repository or a paid plan; otherwise run this repository off-grid"
      return 1
    fi
    for t in $want; do
      kind=${t%%:*}; t=${t#*:}
      case " $have " in *" $kind:$t "*) continue ;; esac
      api_call POST "repos/$OWNER_REPO/environments/$name/deployment-branch-policies" \
        "{\"name\":\"$t\",\"type\":\"$kind\"}" >/dev/null
    done
    ok "$name admits only $want"
  done <<EOF_ENVS
$TRUSTED_ENVS
EOF_ENVS

  # Repository-level copies are readable by a workflow on any branch.
  local repo_secrets s
  repo_secrets=$(curl -sS -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$OWNER_REPO/actions/secrets?per_page=100" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(" ".join(x["name"] for x in json.load(sys.stdin).get("secrets", [])))
except Exception: print("")' 2>/dev/null || true)
  for s in $TRUSTED_SECRETS CANARY_TOKEN; do
    case " $repo_secrets " in *" $s "*) ;; *) continue ;; esac
    case "$MODE" in
      apply)
        api_call DELETE "repos/$OWNER_REPO/actions/secrets/$s" >/dev/null
        miss "$s" "repository-level copy deleted (any branch could read it); set it again into its environment: bootstrap-ci --claude-token / --ci-app-pem, or gh secret set $s -R $OWNER_REPO --env <environment>" ;;
      *) miss "$s" "repository-level secret (readable by a workflow on any branch); apply moves it out" ;;
    esac
  done
}

step_claude_setup() {
  hdr "step 9b: claude CLI + CLAUDE_CODE_OAUTH_TOKEN secret"

  # Part 1: claude install probe (the workflow installs it inline before
  # this step runs, so we expect to find it on PATH already).
  if [ "${BOOTSTRAP_LOCAL:-0}" = "1" ]; then
    note "run locally: the claude CLI is installed by the CI jobs that use it, not here"
  elif command -v claude >/dev/null 2>&1; then
    local ver
    ver=$(claude --version 2>/dev/null || echo unknown)
    ok "claude already installed ($ver)"
  else
    case "$MODE" in
      check)
        miss "claude" "not installed on runner"
        note "install with: curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.150"
        ;;
      dry-run)
        note "[dry-run] would install claude: curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.150"
        ;;
      apply)
        note "claude not installed; installing v2.1.150 via the official Anthropic script"
        local attempt
        for attempt in 1 2 3; do
          if curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.150; then
            break
          fi
          if [ "$attempt" -eq 3 ]; then
            miss "claude" "install failed after 3 attempts"
            break
          fi
          sleep 5
        done
        if command -v claude >/dev/null 2>&1; then
          ok "claude installed: $(claude --version 2>/dev/null || echo unknown)"
        elif [ -x "$HOME/.local/bin/claude" ]; then
          ok "claude installed at \$HOME/.local/bin/claude; add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
        fi
        ;;
    esac
  fi

  # Part 2: repo CLAUDE_CODE_OAUTH_TOKEN secret - SET when the operator passed
  # one (--claude-token, written locally), probe otherwise. The
  # token is minted by a human (claude setup-token); setting it is automation's
  # job, and bootstrap already holds the admin token that authorizes it.
  if [ -n "${CLAUDE_TOKEN_INPUT:-}" ] && [ "$MODE" = "apply" ]; then
    if command -v gh >/dev/null 2>&1 && \
       printf '%s' "$CLAUDE_TOKEN_INPUT" | GH_TOKEN="$TOKEN" gh secret set CLAUDE_CODE_OAUTH_TOKEN -R "$OWNER_REPO" --env v4rian-trusted 2>/dev/null; then
      note "CLAUDE_CODE_OAUTH_TOKEN written to the v4rian-trusted environment"
    else
      miss "CLAUDE_CODE_OAUTH_TOKEN" "secret write FAILED (gh secret set)"
    fi
  fi

  # Truth-from-state probe (runs in every mode; verifies the write above too)
  local resp present
  resp=$(curl -sS \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER_REPO/environments/v4rian-trusted/secrets" 2>/dev/null || true)
  present=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    names=[s.get('name','') for s in d.get('secrets',[])]
    print('yes' if 'CLAUDE_CODE_OAUTH_TOKEN' in names else 'no')
except Exception:
    print('error')" 2>/dev/null || echo error)
  case "$present" in
    yes)
      ok "CLAUDE_CODE_OAUTH_TOKEN set in the v4rian-trusted environment of $OWNER_REPO"
      ;;
    no)
      miss "CLAUDE_CODE_OAUTH_TOKEN" "not set on $OWNER_REPO - ALL claude-judgment audits will run DEGRADED (semantic layer skipped)"
      note "operator step 1: claude setup-token"
      note "operator step 2: re-run bootstrap with --claude-token <value> (or: gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $OWNER_REPO --env v4rian-trusted)"
      # an unarmed AI layer must never hide inside a green bootstrap
      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
          echo "## :red_circle: CLAUDE_CODE_OAUTH_TOKEN missing"
          echo "Claude-judgment audits are running DEGRADED on $OWNER_REPO."
          echo "Mint once (human): \`claude setup-token\`, then run \`bin/bootstrap-ci --claude-token <value>\` locally."
        } >> "$GITHUB_STEP_SUMMARY"
      fi
      ;;
    error|*)
      miss "CLAUDE_CODE_OAUTH_TOKEN" "could not read /actions/secrets (token may lack 'secrets:read' scope)"
      ;;
  esac
}

# ----------------------------------------------------------------------------
# Step 9c: consumer cleanup.
# ----------------------------------------------------------------------------
step_consumer_cleanup() {
  hdr "step 9c: consumer cleanup (mark framework-internals + replace README)"
  local marker="$REPO_ROOT/$NS_DIR/FRAMEWORK_REPO"
  if [ -f "$marker" ]; then
    local repo_resp is_template
    repo_resp=$(curl -sS \
      -H "Authorization: token $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$OWNER_REPO" 2>/dev/null || true)
    is_template=$(printf '%s' "$repo_resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(str(d.get('is_template', False)).lower())
except Exception:
    print('unknown')" 2>/dev/null || true)
    if [ "$is_template" = "true" ]; then
      ok "FRAMEWORK_REPO marker present AND is_template=true; this IS the framework source, skipping consumer-cleanup"
      return 0
    fi
    if [ "$is_template" = "false" ]; then
      # A consumer generated from the template inherits the marker. Every
      # marker-gated script (post-checkout, ci-dispatch, coverage, the usr
      # required.* wrappers) trusts it alone, so leaving it makes the
      # consumer behave as the framework source. Remove it.
      if [ "$MODE" = "check" ]; then
        miss "FRAMEWORK_REPO" "marker inherited from seed on a non-template repo (would remove)"
      elif [ "$MODE" = "dry-run" ]; then
        note "[dry-run] would remove the seed-inherited $NS_DIR/FRAMEWORK_REPO marker"
      else
        rm -f "$marker"
        ok "removed the seed-inherited $NS_DIR/FRAMEWORK_REPO marker (is_template=false)"
      fi
    else
      # is_template could not be read (API or token failure): removing the
      # marker from the real framework source would be worse than keeping a
      # stale one, so keep it and say so; the rest of the cleanup runs as
      # before.
      miss "FRAMEWORK_REPO" "marker present but is_template=${is_template:-unknown}; kept (re-run once the repo API answers)"
    fi
  fi

  local fw_tests_dir="$REPO_ROOT/framework-tests"
  local fw_self_workflow="$REPO_ROOT/.github/workflows/framework-self-tests.yml"
  local root_readme="$REPO_ROOT/README.md"
  local removed=0

  if [ -d "$fw_tests_dir" ]; then
    ok "$NS_DIR/framework-tests/ kept (diagnostic suite for bin/doctor --deep)"
  else
    note "$NS_DIR/framework-tests/ absent (no diagnostic suite installed; bin/doctor --deep will warn)"
  fi

  if [ -f "$fw_self_workflow" ]; then
    if [ "$MODE" = "check" ]; then
      miss "framework-self-tests.yml" "present on this consumer repo (would remove)"
    elif [ "$MODE" = "dry-run" ]; then
      note "[dry-run] would remove .github/workflows/framework-self-tests.yml"
    else
      rm -f "$fw_self_workflow"
      ok "removed .github/workflows/framework-self-tests.yml"
      removed=$((removed + 1))
    fi
  else
    ok ".github/workflows/framework-self-tests.yml already absent"
  fi

  # The framework no longer ships a root README (the canonical framework
  # README lives at $NS_DIR/README.md). A consumer generated via "Use this
  # template" therefore arrives with no root README, so seed the inline
  # consumer stub. If the consumer already has a README, leave it alone
  # (consumer-owned).
  if [ ! -f "$root_readme" ]; then
    if [ "$MODE" = "check" ]; then
      miss "README.md" "absent on this consumer repo (would create consumer stub)"
    elif [ "$MODE" = "dry-run" ]; then
      note "[dry-run] would create README.md consumer stub"
    else
      local repo_name="${OWNER_REPO##*/}"
      cat > "$root_readme" <<README
# ${repo_name}

Your project description here.
README
      ok "created README.md consumer stub for ${repo_name}"
      removed=$((removed + 1))
    fi
  else
    ok "README.md present (consumer-owned)"
  fi

  if [ "$MODE" != "check" ] && [ "$MODE" != "dry-run" ] && [ "$removed" -eq 0 ]; then
    ok "no framework-internal files to clean (consumer cleanup already applied)"
  fi
}

# ----------------------------------------------------------------------------
# Step 10: final report.
# ----------------------------------------------------------------------------
step_report() {
  hdr "step 10: final state"
  printf "  repo:          %s\n" "$OWNER_REPO"
  printf "  mode:          %s\n" "$MODE"
  printf "  token source:  %s\n" "$TOKEN_SRC"
  printf "  lifecycle id:  admin operator gh session (local bin/post-merge-lifecycle); optional CI bot App token in CI\n"
  printf "\n  setup complete. Verify in the web UI: Settings -> Rules -> confirm pool-creations, safety-lockdown, dev-required-checks, and vault-readonly are active.\n"
}

# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------
if [ $# -lt 1 ]; then
  echo "X bootstrap-ci-steps: missing step name argument" >&2
  echo "  usage: bootstrap-ci-steps.sh <step_name>" >&2
  echo "  steps: actions_enabled workflows_enabled seed_dev apply_rules required_checks merge_commit_defaults merge_mode_lock disable_auto_delete topics trusted_env claude_setup consumer_cleanup report" >&2
  exit 2
fi

case "$1" in
  actions_enabled)       step_actions_enabled ;;
  workflows_enabled)     step_workflows_enabled ;;
  seed_dev)              step_seed_dev ;;
  apply_rules)           step_apply_rules ;;
  required_checks)       step_required_checks ;;
  merge_commit_defaults) step_merge_commit_defaults ;;
  merge_mode_lock)       step_merge_mode_lock ;;
  disable_auto_delete)   step_disable_auto_delete ;;
  topics)                step_topics ;;
  trusted_env)           step_trusted_env ;;
  claude_setup)          step_claude_setup ;;
  consumer_cleanup)      step_consumer_cleanup ;;
  report)                step_report ;;
  *)
    echo "X bootstrap-ci-steps: unknown step '$1'" >&2
    exit 2
    ;;
esac
