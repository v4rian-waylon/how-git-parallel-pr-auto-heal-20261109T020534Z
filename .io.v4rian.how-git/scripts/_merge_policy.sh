#!/usr/bin/env bash
# _merge_policy.sh - shared reader for the pool -> dev merge policy and the
# warp flag. Sourced (never executed) by bin/finalize-pool-merge,
# bin/init-pool-merge, bin/set-merge-policy, bin/warp, bin/status,
# bin/doctor and githooks/pre-push so every surface applies one rule set.
#
# Files (both committed, both under .io.v4rian.how-git/):
#   MERGE_POLICY  key=value policy; absent file or key = documented default
#   WARP          "on" or "off"; absent = off
# Defaults reproduce the behaviour before the policy existed.

MP_KEYS="dev_merge_who dev_merge_list dev_merge_pr dev_merge_approval dev_merge_gates dev_merge_max_commits"

mp_ns_dir() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  echo "$root/.io.v4rian.how-git"
}

mp_default() {
  case "$1" in
    dev_merge_who)      echo "admins" ;;
    dev_merge_pr)       echo "required" ;;
    dev_merge_approval) echo "none" ;;
    dev_merge_max_commits) echo "20" ;;
    *)                  echo "" ;;
  esac
}

# mp_valid KEY VALUE - 0 when VALUE is legal for KEY.
mp_valid() {
  case "$1" in
    dev_merge_who)      case "$2" in anyone|admins|list) return 0 ;; esac ;;
    dev_merge_pr)       case "$2" in required|optional) return 0 ;; esac ;;
    dev_merge_approval) case "$2" in none|required) return 0 ;; esac ;;
    dev_merge_list)     [[ "$2" =~ ^[^,[:space:]]*(,[^,[:space:]]+)*$ ]] && return 0 ;;
    dev_merge_gates)    [[ "$2" =~ ^[A-Za-z0-9._-]*(,[A-Za-z0-9._-]+)*$ ]] && return 0 ;;
    dev_merge_max_commits) [[ "$2" =~ ^[0-9]+$ ]] && return 0 ;;
  esac
  return 1
}

# mp_get KEY - the committed value, or the default when absent.
mp_get() {
  local f val
  f="$(mp_ns_dir)/MERGE_POLICY"
  val=""
  if [ -f "$f" ]; then
    val=$(grep -E "^$1=" "$f" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)
  fi
  [ -z "$val" ] && val=$(mp_default "$1")
  echo "$val"
}

warp_state() {
  local f
  f="$(mp_ns_dir)/WARP"
  if [ -f "$f" ] && [ "$(tr -d '[:space:]' < "$f")" = "on" ]; then
    echo on
  else
    echo off
  fi
}

# mp_effective KEY - the value the gates apply: warp lifts who, pr and
# approval; gates and the list are never lifted.
mp_effective() {
  if [ "$(warp_state)" = "on" ]; then
    case "$1" in
      dev_merge_who)      echo "anyone"; return 0 ;;
      dev_merge_pr)       echo "optional"; return 0 ;;
      dev_merge_approval) echo "none"; return 0 ;;
    esac
  fi
  mp_get "$1"
}

# mp_may_merge EMAIL - 0 when EMAIL may merge a pool into dev under the
# effective policy. Prints the reason on stdout either way.
mp_may_merge() {
  local email="$1" who admins list
  who=$(mp_effective dev_merge_who)
  case "$who" in
    anyone)
      echo "dev_merge_who=anyone$([ "$(warp_state)" = on ] && echo ' (WARP on)')"; return 0 ;;
    admins)
      admins="$(mp_ns_dir)/admins.txt"
      if [ ! -f "$admins" ]; then
        echo "admins.txt absent; permissive first run"; return 0
      fi
      if [ -n "$email" ] && grep -Fxq "$email" "$admins"; then
        echo "$email listed in admins.txt"; return 0
      fi
      echo "'${email:-<unset user.email>}' is not listed in admins.txt (dev_merge_who=admins)"; return 1 ;;
    list)
      list=$(mp_get dev_merge_list)
      if [ -n "$email" ] && printf '%s\n' "$list" | tr ',' '\n' | grep -Fxq "$email"; then
        echo "$email listed in dev_merge_list"; return 0
      fi
      echo "'${email:-<unset user.email>}' is not in dev_merge_list (dev_merge_who=list)"; return 1 ;;
  esac
  echo "dev_merge_who has invalid value '$who'"; return 1
}

# mp_check_approval COMMIT OPERATOR - 0 when approval is not required or the
# commit carries an Approved-by trailer from an allowed merger other than
# OPERATOR.
mp_check_approval() {
  local commit="$1" operator="$2" approver
  [ "$(mp_effective dev_merge_approval)" = "required" ] || return 0
  while IFS= read -r approver; do
    [ -z "$approver" ] && continue
    [ "$approver" = "$operator" ] && continue
    if mp_may_merge "$approver" >/dev/null; then
      echo "approved by $approver"; return 0
    fi
  done < <(git log -1 --format=%B "$commit" | sed -n 's/^Approved-by:[[:space:]]*\([^[:space:]]*\).*$/\1/p')
  echo "dev_merge_approval=required: no 'Approved-by: <email>' trailer from an allowed merger other than '$operator'"
  return 1
}

# mp_run_gates - run every dev_merge_gates check through bin/ci-local; 0 when
# all pass (or none are configured).
mp_run_gates() {
  local gates ns g rc=0
  gates=$(mp_get dev_merge_gates)
  [ -z "$gates" ] && return 0
  ns=$(mp_ns_dir)
  for g in $(printf '%s' "$gates" | tr ',' ' '); do
    echo "-> merge gate: $g"
    if ! "$ns/bin/ci-local" --trigger push --only "$g"; then
      echo "X merge gate '$g' failed" >&2
      rc=1
    fi
  done
  return $rc
}

# mp_check_pool_size MERGE - 0 when the pool a pool -> dev merge brings in
# (MERGE^2 not reachable from MERGE^1, merges excluded) holds at most
# dev_merge_max_commits commits; 0 disables the cap. A deterministic gate,
# never lifted by warp: one pool is one feature area of about 20 commits,
# bigger deliveries are sequential pools (friction ledger FP-01). Prints the
# reason on stdout either way.
mp_check_pool_size() {
  local merge="$1"
  git rev-parse -q --verify "$merge^2" >/dev/null 2>&1 || { echo "not a merge; no pool size to check"; return 0; }
  mp_check_branch_size "$merge^2" "$merge^1"
}

# mp_check_branch_size TIP BASE - the same cap for a pool TIP that is not
# merged yet (bin/init-pool-merge before it opens the PR).
mp_check_branch_size() {
  local tip="$1" base="$2" cap n
  cap=$(mp_get dev_merge_max_commits)
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=20
  n=$(git rev-list --count --no-merges "$tip" --not "$base")
  if [ "$cap" -eq 0 ]; then
    echo "pool size $n commits (dev_merge_max_commits=0, no cap)"; return 0
  fi
  if [ "$n" -gt "$cap" ]; then
    echo "the pool carries $n commits, above dev_merge_max_commits=$cap; split it into sequential pools of one feature area each, or raise the cap with bin/set-merge-policy dev_merge_max_commits=N (admin-gated)"
    return 1
  fi
  echo "pool size $n commits (dev_merge_max_commits=$cap)"
}
