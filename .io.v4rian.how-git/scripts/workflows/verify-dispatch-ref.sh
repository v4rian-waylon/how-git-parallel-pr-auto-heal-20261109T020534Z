#!/usr/bin/env bash
# verify-dispatch-ref.sh - refuse a ref a thin workflow entry was asked to
# run CI on unless it belongs to this repo.
#
# ci-dispatch.yml runs this from its trusted checkout (the dispatch ref,
# before the requested ref is checked out) whenever a caller passes
# inputs.ref. The requested ref's ci/ scripts then run with the CI
# secrets, so only code that already lives on this repo's branches or tags
# may be named:
#   refs/heads/NAME, refs/tags/NAME   must exist on origin
#   NAME                              an origin branch or tag
#   <40-hex sha>                      a commit some origin branch contains
# Everything else (refs/pull/*, refs/remotes/*, other refs, short SHAs,
# refspecs, glob characters, commits only another remote carries) is
# refused. A tag counts as a repo ref wherever it points: only someone
# with write access can create one.
#
# Usage: verify-dispatch-ref.sh <ref>    (empty ref: nothing to check)
# Exit codes: 0 accepted; 1 refused; 2 usage error.

set -uo pipefail

if [ $# -ne 1 ]; then
  echo "X verify-dispatch-ref: want exactly one <ref>" >&2
  exit 2
fi
REF="$1"
[ -n "$REF" ] || exit 0

refuse() { echo "X verify-dispatch-ref: refusing '$REF': $1" >&2; exit 1; }

on_origin() { git ls-remote --exit-code origin "$1" >/dev/null 2>&1; }

case "$REF" in
  *:*|*' '*|-*|*'*'*|*'?'*|*'['*|*\\*) refuse "not a plain ref name (no refspecs, options or glob characters)" ;;
  refs/heads/?*|refs/tags/?*)
    on_origin "$REF" || refuse "not on origin"
    ;;
  refs/*) refuse "only branches and tags of this repo may be dispatched (pull request heads and other refs run untrusted code)" ;;
  *)
    if printf '%s' "$REF" | grep -qE '^[0-9a-f]{40}$'; then
      git cat-file -e "$REF^{commit}" 2>/dev/null || refuse "commit not present in the checkout"
      [ -n "$(git branch -r --list 'origin/*' --contains "$REF" 2>/dev/null | grep -v ' -> ')" ] \
        || refuse "commit is on no origin branch"
    elif on_origin "refs/heads/$REF" || on_origin "refs/tags/$REF"; then
      :
    else
      refuse "no origin branch or tag of that name"
    fi
    ;;
esac
echo "=> verify-dispatch-ref: '$REF' belongs to this repo"
exit 0
