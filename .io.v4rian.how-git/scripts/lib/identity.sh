#!/usr/bin/env bash
# identity.sh - commit identity and source time, derived, never asked.
#
# Sourced by bin/identity, _lib.sh and the commit-msg / pre-push hooks.
# bash 3.2 and bash 5 compatible; no associative arrays.
#
#   identity_org                 GitHub org of origin (or how-git.org pin)
#   identity_lookup              "<email>\t<name>" for that org, rc 3 if unmapped
#   identity_export_if_unset     export GIT_{AUTHOR,COMMITTER}_{NAME,EMAIL}
#   identity_email_allowed EMAIL rc 0 when EMAIL is the mapped identity, or
#                                Joel's own under the snapshot-rebuild switch,
#                                or the configured bot in a real CI run
#   identity_name_allowed N E    rc 0 when name N fits the allowed email E:
#                                the map name, its <Model> slot filled by any
#                                model or dropped; the configured bot name
#   identity_real_ci             rc 0 inside a real GitHub Actions run
#   identity_source_date PATH    "<epoch> <+hhmm>" from the mtime, in the
#                                zone offset real at that instant
#   identity_utc_stamp           YYYYMMDDTHHMMSSZ for ref and zip names

IDENTITY_JOEL_EMAIL="joel.quatro@gmail.com"

_identity_ns() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  printf '%s/.io.v4rian.how-git' "$top"
}

identity_org() {
  local pin url org
  pin=$(git config --get how-git.org 2>/dev/null || true)
  if [ -n "$pin" ]; then printf '%s' "$pin"; return 0; fi
  url=$(git remote get-url origin 2>/dev/null) || return 3
  case "$url" in
    *github.com[:/]*) org=${url#*github.com}; org=${org#?}; org=${org%%/*} ;;
    *) return 3 ;;
  esac
  [ -n "$org" ] || return 3
  printf '%s' "$org"
}

_identity_model() {
  if [ -n "${HOW_GIT_MODEL:-}" ]; then printf '%s' "$HOW_GIT_MODEL"; return; fi
  case "${ANTHROPIC_MODEL:-}" in
    *opus*) printf Opus ;; *sonnet*) printf Sonnet ;;
    *haiku*) printf Haiku ;; *fable*) printf Fable ;;
  esac
}

# "<email>\t<name template>" from the first map that carries the org.
_identity_map_line() {
  local org ns f line
  org=$(identity_org) || return 3
  ns=$(_identity_ns) || return 3
  for f in "${HOW_GIT_IDENTITY_MAP:-}" "$ns/identity-map.local" "$ns/identity-map"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    line=$(awk -v o="$org" '$1 !~ /^#/ && tolower($1) == tolower(o) {
             e=$2; $1=""; $2=""; sub(/^ +/, ""); print e "\t" $0; exit }' "$f")
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
    return 0
  done
  return 3
}

identity_lookup() {
  local line model name
  line=$(_identity_map_line) || return 3
  name=${line#*	}
  model=$(_identity_model)
  if [ -n "$model" ]; then
    name=$(printf '%s' "$name" | sed "s/<Model>/$model/")
  else
    name=$(printf '%s' "$name" | sed 's/ *(<Model>)//; s/<Model>//')
  fi
  printf '%s\t%s\n' "${line%%	*}" "$name"
}

# A real GitHub Actions run sets both; a bare GITHUB_ACTIONS=true does not
# make a local shell a CI run. There the workflow's configured bot identity
# (git config user.name / user.email) authors the ceremony commits.
identity_real_ci() {
  [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${GITHUB_RUN_ID:-}" ]
}

_identity_ci_bot_email() {
  identity_real_ci || return 1
  git config --get user.email 2>/dev/null
}

identity_export_if_unset() {
  local hit
  [ -z "${GIT_AUTHOR_EMAIL:-}" ] && [ -z "${GIT_COMMITTER_EMAIL:-}" ] || return 0
  identity_real_ci && [ -n "$(_identity_ci_bot_email)" ] && return 0
  hit=$(identity_lookup 2>/dev/null) || return 0
  GIT_AUTHOR_EMAIL=${hit%%	*}; GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
  GIT_AUTHOR_NAME=${hit#*	};   GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
  export GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL GIT_AUTHOR_NAME GIT_COMMITTER_NAME
}

identity_snapshot_rebuild_on() {
  [ "${HOW_GIT_SNAPSHOT_REBUILD:-0}" = "1" ] && return 0
  [ "$(git config --bool --get how-git.snapshotRebuild 2>/dev/null)" = "true" ]
}

# rc 0 allowed, 1 refused, 3 repo unmapped (nothing to enforce).
identity_email_allowed() {
  local hit
  hit=$(identity_lookup 2>/dev/null) || return 3
  [ "$1" = "${hit%%	*}" ] && return 0
  if [ "$1" = "$IDENTITY_JOEL_EMAIL" ] && identity_snapshot_rebuild_on; then return 0; fi
  [ -n "$1" ] && [ "$1" = "$(_identity_ci_bot_email)" ] && return 0
  return 1
}

# rc 0 allowed, 1 refused, 3 repo unmapped. Call after the email passed.
identity_name_allowed() {
  local name="$1" email="$2" line tmpl pre post mid
  line=$(_identity_map_line 2>/dev/null) || return 3
  if [ "$email" = "${line%%	*}" ]; then
    tmpl=${line#*	}
    case "$tmpl" in
      *"<Model>"*)
        pre=${tmpl%%<Model>*}; post=${tmpl#*<Model>}
        # The model slot dropped, as identity_lookup does without a model.
        [ "$name" = "$(printf '%s' "$tmpl" | sed 's/ *(<Model>)//; s/<Model>//')" ] && return 0
        case "$name" in "$pre"*"$post") ;; *) return 1 ;; esac
        mid=${name#"$pre"}; mid=${mid%"$post"}
        [ -n "$mid" ] && return 0
        return 1 ;;
      *) [ "$name" = "$tmpl" ] && return 0; return 1 ;;
    esac
  fi
  if [ "$email" = "$IDENTITY_JOEL_EMAIL" ] && identity_snapshot_rebuild_on; then return 0; fi
  if [ -n "$email" ] && [ "$email" = "$(_identity_ci_bot_email)" ]; then
    [ "$name" = "$(git config --get user.name 2>/dev/null)" ] && return 0
  fi
  return 1
}

identity_expected_email() {
  local hit
  hit=$(identity_lookup 2>/dev/null) || return 3
  printf '%s' "${hit%%	*}"
}

identity_source_date() {
  local epoch off
  # GNU forms first: BSD rejects them, while GNU stat -f means filesystem.
  epoch=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || return 1
  off=$(date -d "@$epoch" +%z 2>/dev/null || date -r "$epoch" +%z) || return 1
  printf '%s %s\n' "$epoch" "$off"
}

identity_utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }
