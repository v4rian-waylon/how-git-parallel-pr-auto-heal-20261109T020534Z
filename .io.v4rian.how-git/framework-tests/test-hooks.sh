#!/usr/bin/env bash
# test/test-hooks.sh - exercise the v4rian local hooks and version math.
# Run directly: bash framework-tests/test-hooks.sh
#
# Exit 0 if all cases pass, 1 if any fail.

set -uo pipefail
# shellcheck source=./_hermetic_env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_hermetic_env.sh"

# Run from anywhere; resolve repo root from this script's location.
# framework-tests/ moved out of .io.v4rian.how-git/test/ in pool/n45, so
# $SCRIPT_DIR/.. is now the actual repo root. Tests in this file use
# relative paths like ./bin/version that only resolve from inside the
# namespace dir, so cd there.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT/.io.v4rian.how-git"

PASS=0
FAIL=0
FAIL_CASES=()

run() {
  local desc="$1"
  local expected="$2"   # pass or fail
  local cmd="$3"

  if bash -c "$cmd" >/dev/null 2>&1; then
    actual=pass
  else
    actual=fail
  fi

  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    FAIL_CASES+=("$desc (expected $expected, got $actual)")
    printf "  ✗ %s (expected %s, got %s)\n" "$desc" "$expected" "$actual"
  fi
}

# Branch-name regex test harness - runs the shared hg_branch_name_ok
# (scripts/_lib.sh, the one definition pre-push, post-checkout, and the
# scripts source) against a candidate without invoking git push. It accepts
# both the legacy flat layout (pool/nN.kind.short) and the vYYYY.MAIN/
# prefixed layout (pool/vYYYY.MAIN/nN.kind.short).
check_branch() {
  # shellcheck source=../scripts/_lib.sh
  . ./scripts/_lib.sh
  hg_branch_name_ok "$1"
}
export -f check_branch

echo "=== Branch name validation ==="
echo "--- Should ACCEPT (legacy flat layout) ---"
run "main"                                                "pass" "check_branch 'main'"
run "dev"                                                 "pass" "check_branch 'dev'"
run "pool/n3.feature.parser-rewrite"                       "pass" "check_branch 'pool/n3.feature.parser-rewrite'"
run "pool/n3.feature.sprint4-parser-rewrite"               "pass" "check_branch 'pool/n3.feature.sprint4-parser-rewrite'"
run "pool/n7.fix.PROJ-123-token-leak"                      "pass" "check_branch 'pool/n7.fix.PROJ-123-token-leak'"
run "pool/n12.r&d.sprint5-PROJ-456-embedding-cache"        "pass" "check_branch 'pool/n12.r&d.sprint5-PROJ-456-embedding-cache'"
run "pool/n4.refactor.config-module"                       "pass" "check_branch 'pool/n4.refactor.config-module'"
run "pool/n5.reconcile.vault-archive-pool-on-merge"        "pass" "check_branch 'pool/n5.reconcile.vault-archive-pool-on-merge'"
run "safety/n3.feature.parser-rewrite"                     "pass" "check_branch 'safety/n3.feature.parser-rewrite'"
run "safety/n5.reconcile.vault-archive-pool-on-merge"      "pass" "check_branch 'safety/n5.reconcile.vault-archive-pool-on-merge'"
run "pool/n99.feature.a"                                   "pass" "check_branch 'pool/n99.feature.a'"
run "pool/n0.feature.x-y-z"                                "pass" "check_branch 'pool/n0.feature.x-y-z'"

echo "--- Should ACCEPT (vYYYY.MAIN/ prefixed layout) ---"
run "pool/v2026.0/n3.feature.parser-rewrite"               "pass" "check_branch 'pool/v2026.0/n3.feature.parser-rewrite'"
run "pool/v2026.0/n3.feature.sprint4-parser-rewrite"       "pass" "check_branch 'pool/v2026.0/n3.feature.sprint4-parser-rewrite'"
run "pool/v2026.0/n7.fix.PROJ-123-token-leak"              "pass" "check_branch 'pool/v2026.0/n7.fix.PROJ-123-token-leak'"
run "pool/v2026.12/n12.r&d.sprint5-PROJ-456-embedding-cache" "pass" "check_branch 'pool/v2026.12/n12.r&d.sprint5-PROJ-456-embedding-cache'"
run "pool/v2026.0/n4.refactor.config-module"               "pass" "check_branch 'pool/v2026.0/n4.refactor.config-module'"
run "pool/v2026.0/n5.reconcile.vault-archive-pool-on-merge" "pass" "check_branch 'pool/v2026.0/n5.reconcile.vault-archive-pool-on-merge'"
run "safety/v2026.0/n3.feature.parser-rewrite"             "pass" "check_branch 'safety/v2026.0/n3.feature.parser-rewrite'"
run "safety/v2026.0/n5.reconcile.vault-archive-pool-on-merge" "pass" "check_branch 'safety/v2026.0/n5.reconcile.vault-archive-pool-on-merge'"
run "pool/v2027.3/n99.feature.a"                           "pass" "check_branch 'pool/v2027.3/n99.feature.a'"
run "pool/v2026.0/n0.feature.x-y-z"                        "pass" "check_branch 'pool/v2026.0/n0.feature.x-y-z'"
run "pool/v2026.0/n22.doc.runbook-rewrite"                 "pass" "check_branch 'pool/v2026.0/n22.doc.runbook-rewrite'"

echo "--- Should REJECT ---"
run "feature/foo (missing scope)"                         "fail" "check_branch 'feature/foo'"
run "pool/foo (no nN)"                                     "fail" "check_branch 'pool/foo'"
run "pool/n3.feature (no short_name)"                      "fail" "check_branch 'pool/n3.feature'"
run "pool/n3.unknown.foo (bad kind)"                       "fail" "check_branch 'pool/n3.unknown.foo'"
run "pool/N3.feature.foo (uppercase N)"                    "fail" "check_branch 'pool/N3.feature.foo'"
run "pool/n3.feature.Foo (uppercase in short_name)"        "fail" "check_branch 'pool/n3.feature.Foo'"
run "pool/n.feature.foo (no digit)"                        "fail" "check_branch 'pool/n.feature.foo'"
run "pool/3.feature.foo (no n prefix)"                     "fail" "check_branch 'pool/3.feature.foo'"
run "random/n3.feature.foo (bad scope)"                   "fail" "check_branch 'random/n3.feature.foo'"
run "pool/n3.feature.-leading_dash"                        "fail" "check_branch 'pool/n3.feature.-leading_dash'"
run "pool/n3.feature.parser_rewrite (underscore)"          "fail" "check_branch 'pool/n3.feature.parser_rewrite'"
run "pool/n3.feature.sprint4-parser_rewrite (underscore in short_name)" "fail" "check_branch 'pool/n3.feature.sprint4-parser_rewrite'"
run "pool/n7.fix.PROJ-123-token_leak (underscore)"         "fail" "check_branch 'pool/n7.fix.PROJ-123-token_leak'"
run "pool/n12.r&d.sprint5-PROJ-456-embedding_cache (underscore)" "fail" "check_branch 'pool/n12.r&d.sprint5-PROJ-456-embedding_cache'"
run "pool/n4.refactor.config_module (underscore)"          "fail" "check_branch 'pool/n4.refactor.config_module'"
run "pool/n5.reconcile.vault_archive_pool_on_merge (underscores)" "fail" "check_branch 'pool/n5.reconcile.vault_archive_pool_on_merge'"
run "safety/n3.feature.parser_rewrite (underscore)"        "fail" "check_branch 'safety/n3.feature.parser_rewrite'"
run "safety/n5.reconcile.vault_archive_pool_on_merge (underscores)" "fail" "check_branch 'safety/n5.reconcile.vault_archive_pool_on_merge'"
run "pool/v2026/n3.feature.foo (single-segment prefix)"    "fail" "check_branch 'pool/v2026/n3.feature.foo'"
run "pool/v2026.0.0/n3.feature.foo (3-segment prefix)"     "fail" "check_branch 'pool/v2026.0.0/n3.feature.foo'"
run "pool/v2026.0/N3.feature.foo (uppercase N under prefix)" "fail" "check_branch 'pool/v2026.0/N3.feature.foo'"
run "pool/v2026.0/n3.unknown.foo (bad kind under prefix)"  "fail" "check_branch 'pool/v2026.0/n3.unknown.foo'"
run "safety/v2026/n3.feature.foo (single-segment prefix)"  "fail" "check_branch 'safety/v2026/n3.feature.foo'"
run "HEAD (detached checkout has no branch name)"         "fail" "check_branch 'HEAD'"

echo ""
echo "=== Version bin (bump.sh + init-version.sh deleted; bin/version is canonical) ==="

# The 2 dead scripts MUST be gone (replaced by bin/version)
run "bump.sh deleted (dead code under tags-as-seal model)" \
    "fail" \
    "test -e ./scripts/bump.sh"

run "init-version.sh deleted (dead code under tags-as-seal model)" \
    "fail" \
    "test -e ./scripts/init-version.sh"

# bin/version produces a 3-segment vYEAR.SERIES.DEV output
run "bin/version --seal produces vYEAR.SERIES.DEV" \
    "pass" \
    "./bin/version --seal | grep -qE '^v[0-9]{4}\.[0-9]+\.[0-9]+$'"

run "bin/version (default identifier) produces vYEAR.SERIES.DEV-sha.build" \
    "pass" \
    "./bin/version | grep -qE '^v[0-9]{4}\.[0-9]+\.[0-9]+-[0-9a-f]+\.[0-9]+$'"

run "bin/version --release-tag produces vYEAR.SERIES.DEV" \
    "pass" \
    "./bin/version --release-tag | grep -qE '^v[0-9]{4}\.[0-9]+\.[0-9]+$'"

echo ""
echo "=== pre-commit binary detection (n94) ==="

# The pre-commit hook's `_is_text_file` helper must use the portable
# `file -b --mime-encoding` token instead of the broken
# `grep -q $'\x00'` probe that bash collapses to the empty pattern.
run "pre-commit uses file -b --mime-encoding for binary detection" \
    "pass" \
    "grep -q 'file -b --mime-encoding' ./githooks/pre-commit"

# Negative guard: the broken `grep -q $'\x00'` probe must be gone from
# every non-comment line (the explanatory comment in `_is_text_file`
# keeps the historical pattern in prose form so a future reader knows
# why mime-encoding is used).
run "pre-commit no longer carries the grep null-byte probe in code" \
    "pass" \
    "! grep -nE \"grep -q \\\\\$'\\\\\\\\x00'\" ./githooks/pre-commit | grep -vE '^[0-9]+:#'"

# The hook must skip itself, the auto-fix lib, the framework-tests
# fixtures, and the commit-audit worker so each retains its em-dash
# bytes as test data or gate-pattern literals.
run "pre-commit skips the auto-fix scrub library" \
    "pass" \
    "grep -q 'auto-fix-commit-message.sh) return 0' ./githooks/pre-commit"
run "pre-commit skips itself to preserve python literals" \
    "pass" \
    "grep -q 'githooks/pre-commit) return 0' ./githooks/pre-commit"
run "pre-commit skips the framework-tests fixtures" \
    "pass" \
    "grep -q 'framework-tests/test-lifecycle.sh) return 0' ./githooks/pre-commit"
run "pre-commit skips the commit-audit worker" \
    "pass" \
    "grep -q 'scripts/audits/commit-audit.sh) return 0' ./githooks/pre-commit"

echo ""
echo "=== commit-audit em-dash gate (n94) ==="

# The deterministic em-dash gate must live in the commit-audit worker
# and must be wired in front of the lens loop so a missed local scrub
# fails the audit even when the lens canned-passes under
# LIFECYCLE_TEST_MODE.
run "commit-audit worker defines scan_em_dashes_in_range" \
    "pass" \
    "grep -q 'scan_em_dashes_in_range()' ./scripts/audits/commit-audit.sh"
run "commit-audit worker defines _em_dash_skip_path" \
    "pass" \
    "grep -q '_em_dash_skip_path()' ./scripts/audits/commit-audit.sh"
run "commit-audit main flow calls scan_em_dashes_in_range" \
    "pass" \
    "grep -q 'scan_em_dashes_in_range \"\$SHAS\"' ./scripts/audits/commit-audit.sh"
run "commit-audit gate exits 1 on em-dash hits" \
    "pass" \
    "grep -q 'EM_DASH_HITS.*-gt 0' ./scripts/audits/commit-audit.sh"

# Framework tests run under pipefail: an echo piped into grep -q loses a race when
# grep exits early and echo takes SIGPIPE. Feed greps from here strings instead.
run "framework tests never pipe echo or printf into grep -q" \
    "pass" \
    "! grep -nE '(echo|printf) [^|]*\\| *grep +-[a-zA-Z]*q' ./framework-tests/test-hooks.sh ./framework-tests/test-lifecycle.sh ./framework-tests/test-agent-hooks.sh"

echo ""
echo "=== Merge message gate (git-merge-audit rule 5, pool 8) ==="

MM="$PWD/scripts/check-merge-message.sh"
MP="$PWD/scripts/check-merge-parity.sh"
HOOKS="$PWD/githooks"
MB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/merge-body-tests.XXXXXX")
export MM MP HOOKS MB_TMP
GOOD_TITLE='[MERGE] pool/n7.feature.parser-rewrite into dev: v2026.0.164'
GOOD_BODY='Lands the parser rewrite with error recovery for malformed input.

- Parser.
    - Block grammar: parses nested blocks and recovers at the next block.
    - Error report: names the line of the first malformed block.
- Reverts within the branch.
    - Eager mode: drops the eager parse the branch first tried.'
mb_msg() { printf '%s\n\n%s\n' "$1" "$2" > "$MB_TMP/$3"; }
mb_msg "$GOOD_TITLE" "$GOOD_BODY" good.txt
mb_msg "$GOOD_TITLE" "PR #12 https://github.com/o/r/pull/12

$GOOD_BODY" good-pr.txt
mb_msg "$GOOD_TITLE" 'Lands the parser rewrite with error recovery for malformed input.' para-only.txt
mb_msg "$GOOD_TITLE" '- Parser.
    - Block grammar: parses nested blocks.' bullets-only.txt
mb_msg "$GOOD_TITLE" 'Lands the parser rewrite.

- Block grammar: parses nested blocks.
- Error report: names the line.' flat.txt
mb_msg "$GOOD_TITLE" 'Lands the parser rewrite.

- Parser.
    - Block grammar: parses nested blocks' no-period.txt
mb_msg "$GOOD_TITLE" 'Lands the parser rewrite.

Changes:
- Parser.
    - Block grammar: parses nested blocks.' changes-header.txt
mb_msg "$GOOD_TITLE" 'One. Two. Three. Four.

- Parser.
    - Block grammar: parses nested blocks.' four-sentences.txt
mb_msg '[MERGE] pool/n7.feature.parser-rewrite into dev' "$GOOD_BODY" no-version.txt
mb_msg '[MERGE] Merge pool/n7.feature.parser-rewrite into dev: v2026.0.164' "$GOOD_BODY" merge-word.txt
mb_msg '[MERGE] dev into main: v2026.0.164' "$GOOD_BODY" dev-main.txt
printf '%s\n' "$GOOD_BODY" > "$MB_TMP/pr-body.txt"
printf '%s\n\n<!-- opened-via-correct-flow run=42 -->\n' "$GOOD_BODY" > "$MB_TMP/pr-body-signed.txt"
printf '[REFACTOR] %s\n' "$GOOD_BODY" > "$MB_TMP/pr-body-tagged.txt"

run "gate: ruled shape passes"                          "pass" "\"\$MM\" --file \"\$MB_TMP/good.txt\""
run "gate: dev into main in ruled shape passes"         "pass" "\"\$MM\" --file \"\$MB_TMP/dev-main.txt\""
run "gate: PR reference paragraph passes with --pr-ref" "pass" "\"\$MM\" --file \"\$MB_TMP/good-pr.txt\" --pr-ref"
run "gate: PR reference paragraph fails without --pr-ref" "fail" "\"\$MM\" --file \"\$MB_TMP/good-pr.txt\""
run "gate: paragraph only fails"                        "fail" "\"\$MM\" --file \"\$MB_TMP/para-only.txt\""
run "gate: bullets only fails"                          "fail" "\"\$MM\" --file \"\$MB_TMP/bullets-only.txt\""
run "gate: flat bullets fail"                           "fail" "\"\$MM\" --file \"\$MB_TMP/flat.txt\""
run "gate: missing period on a leaf fails"              "fail" "\"\$MM\" --file \"\$MB_TMP/no-period.txt\""
run "gate: Changes: header fails"                       "fail" "\"\$MM\" --file \"\$MB_TMP/changes-header.txt\""
run "gate: four sentence paragraph fails"               "fail" "\"\$MM\" --file \"\$MB_TMP/four-sentences.txt\""
run "gate: title without version fails"                 "fail" "\"\$MM\" --file \"\$MB_TMP/no-version.txt\""
run "gate: title repeating Merge fails"                 "fail" "\"\$MM\" --file \"\$MB_TMP/merge-word.txt\""
run "gate: PR body in ruled shape passes"               "pass" "\"\$MM\" --body-file \"\$MB_TMP/pr-body.txt\""
run "gate: PR body with a derived tag prefix fails"     "fail" "\"\$MM\" --body-file \"\$MB_TMP/pr-body-tagged.txt\""
run "gate: PR body with an appended signature fails"    "fail" "\"\$MM\" --body-file \"\$MB_TMP/pr-body-signed.txt\""

# A scratch repo whose hooks are this namespace's githooks, with dev, a
# pool branch one commit ahead, and a bare origin for the pre-push cases.
mb_repo() {
  local d="$MB_TMP/$1"
  git init -q -b main "$d" && cd "$d" || return 1
  git config user.email t@t; git config user.name t
  git config core.hooksPath "$HOOKS"
  echo base > f; git add f; git commit -q --no-verify -m "[NEW] Add the base file for the scratch repo"
  git checkout -q -b dev
  git checkout -q -b pool/n7.feature.parser-rewrite
  echo change >> f; git commit -q -a --no-verify -m "[NEW] Add one change to the base file"
  git checkout -q dev
  git init -q --bare "$d.origin.git"; git remote add origin "$d.origin.git"
  git push -q --no-verify origin main dev >/dev/null 2>&1
}
export -f mb_repo

run "commit-msg: merge into dev with paragraph only body is rejected" "fail" \
  "mb_repo cm1 && git merge -q --no-ff pool/n7.feature.parser-rewrite -F \"\$MB_TMP/para-only.txt\""
run "commit-msg: merge into dev in ruled shape is accepted" "pass" \
  "mb_repo cm2 && git merge -q --no-ff pool/n7.feature.parser-rewrite -F \"\$MB_TMP/good.txt\""
run "commit-msg: default merge subject into dev is rejected" "fail" \
  "mb_repo cm3 && git merge -q --no-ff --no-edit pool/n7.feature.parser-rewrite"
run "commit-msg: an untagged subject is refused" "fail" \
  "mb_repo cm6 && echo x >> f && git commit -q -a -m 'tidy the base file'"
run "commit-msg: a cherry-pick replay keeps its original subject" "pass" \
  "mb_repo cm7 && git checkout -q -b side && echo y > g && git add g && git commit -q --no-verify -m '[NEW] lowercase start' && git checkout -q dev && echo z > g && git add g && git commit -q --no-verify -m '[NEW] Clash on g' && { git cherry-pick side >/dev/null 2>&1; echo y > g; git add g; GIT_EDITOR=true git cherry-pick --continue; }"
run "commit-msg: plain commits are not merge checked" "pass" \
  "mb_repo cm4 && echo x >> f && git commit -q -a -m '[FIX] Correct one line of the base file'"
run "commit-msg: claim style amend with PR reference is accepted" "pass" \
  "mb_repo cm5 && git merge -q --no-ff pool/n7.feature.parser-rewrite -F \"\$MB_TMP/good.txt\" && git commit -q --amend -F \"\$MB_TMP/good-pr.txt\""
run "pre-push: dev push carrying a merge with a bad body is rejected" "fail" \
  "mb_repo pp1 && git -c core.hooksPath=/dev/null merge -q --no-ff pool/n7.feature.parser-rewrite -F \"\$MB_TMP/para-only.txt\" && git push -q origin dev"
# A merge that already landed with a foreign message (hooks off, a non-pool
# merge) must not block the claim from publishing dev and sealing its
# version (DECISIONS: gates refuse only what the claim writes or amends).
run "pre-push: a claim push warns on an already landed foreign merge" "pass" \
  "mb_repo pp3 && git -c core.hooksPath=/dev/null merge -q --no-ff pool/n7.feature.parser-rewrite -m 'Integrate topic work' && V4RIAN_CLAIM_PUSH=1 git push -q origin dev"
run "pre-push: dev push carrying a ruled merge is accepted" "pass" \
  "mb_repo pp2 && git merge -q --no-ff pool/n7.feature.parser-rewrite -F \"\$MB_TMP/good.txt\" && git push -q origin dev"

# Preflight backups (~/.claude/hooks/git-preflight.sh, git-snapshot-preflight)
# push preflight-bak-YYYY-MM-DD/NN: a commit-tree snapshot of the working
# tree whose message is not in the ruled shape. Exactly that name shape is
# accepted; every near miss keeps the branch-name refusal.
pf_push() {
  mb_repo "$1" || return 1
  local c
  c=$(printf 'preflight backup before a rewrite\n' | git commit-tree "HEAD^{tree}" -p HEAD) || return 1
  git update-ref "refs/heads/$2" "$c" || return 1
  git push -q origin "refs/heads/$2:refs/heads/$2"
}
export -f pf_push
run "pre-push: preflight-bak-YYYY-MM-DD/NN backup is accepted" "pass" "pf_push pf1 preflight-bak-2026-10-29/01"
run "pre-push: preflight-bak without /NN is rejected"          "fail" "pf_push pf2 preflight-bak-2026-10-29"
run "pre-push: preflight-bak with a letter suffix is rejected" "fail" "pf_push pf3 preflight-bak-2026-10-29a"
run "pre-push: preflight-bak with one digit NN is rejected"    "fail" "pf_push pf4 preflight-bak-2026-10-29/1"
run "pre-push: preflight-bak with a deeper path is rejected"   "fail" "pf_push pf5 preflight-bak-2026-10-29/01/x"
run "pre-push: preflight-bak with a non-date is rejected"      "fail" "pf_push pf6 preflight-bak-today/01"
run "pre-push: a preflight-bak prefix inside a name is rejected" "fail" "pf_push pf7 x-preflight-bak-2026-10-29/01"
run "pre-push: preflight-bak shape is not a general branch name" "fail" "check_branch 'preflight-bak-2026-10-29/01'"

run "parity: merge body minus the PR reference equals the PR body" "pass" \
  "mb_repo pa1 && git merge -q --no-ff pool/n7.feature.parser-rewrite -F \"\$MB_TMP/good-pr.txt\" && \"\$MP\" HEAD --pr-body-file \"\$MB_TMP/pr-body.txt\""
run "parity: a PR body with an appended signature differs" "fail" \
  "mb_repo pa2 && git merge -q --no-ff pool/n7.feature.parser-rewrite -F \"\$MB_TMP/good-pr.txt\" && \"\$MP\" HEAD --pr-body-file \"\$MB_TMP/pr-body-signed.txt\""
run "parity: a merge without the PR reference still compares the body" "pass" \
  "mb_repo pa3 && git merge -q --no-ff pool/n7.feature.parser-rewrite -F \"\$MB_TMP/good.txt\" && \"\$MP\" HEAD --pr-body-file \"\$MB_TMP/pr-body.txt\""
rm -rf "$MB_TMP"

# Deterministic subject rules in commit-msg (jev evaluation, gitlint parity):
# the 200 seeded subjects of bench-results/jev, 61 of them violations. Every
# violation is refused and every clean subject accepted; the hook runs in a
# scratch repo with no origin, so only the message rules are under test.
echo ""
echo "=== commit-msg: jev message corpus (61 seeded violations) ==="
CORPUS="$SCRIPT_DIR/fixtures/jev-msg-corpus.tsv"
CM="$PWD/githooks/commit-msg"
JEV_TMP=$(mktemp -d "${TMPDIR:-/tmp}/jev-corpus.XXXXXX")
git init -q "$JEV_TMP/repo"
jev_caught=0; jev_bad=0; jev_wrong=""
while IFS="$(printf '\t')" read -r want subj; do
  case "$want" in ok|bad) ;; *) continue ;; esac
  printf '%s\n\nDescription paragraph explaining why.\n' "$subj" > "$JEV_TMP/msg"
  if (cd "$JEV_TMP/repo" && bash "$CM" "$JEV_TMP/msg") >/dev/null 2>&1; then got=ok; else got=bad; fi
  [ "$want" = bad ] && jev_bad=$((jev_bad + 1))
  [ "$want" = bad ] && [ "$got" = bad ] && jev_caught=$((jev_caught + 1))
  [ "$want" = "$got" ] || jev_wrong="$jev_wrong
    want $want, got $got: $subj"
done < "$CORPUS"
rm -rf "$JEV_TMP"
export jev_caught jev_bad jev_wrong
run "corpus: commit-msg catches $jev_caught of $jev_bad seeded violations" "pass" '[ "$jev_bad" -eq 61 ] && [ "$jev_caught" -eq 61 ]'
run "corpus: commit-msg verdict matches every corpus label" "pass" '[ -z "$jev_wrong" ] || { printf "%s\n" "$jev_wrong" >&2; false; }'
[ -z "$jev_wrong" ] || printf '%s\n' "$jev_wrong" | head -12

echo ""
echo "=== Summary ==="
echo "  $PASS passed, $FAIL failed"

if (( FAIL > 0 )); then
  echo ""
  echo "Failures:"
  for c in "${FAIL_CASES[@]}"; do
    echo "  - $c"
  done
  exit 1
fi

exit 0
