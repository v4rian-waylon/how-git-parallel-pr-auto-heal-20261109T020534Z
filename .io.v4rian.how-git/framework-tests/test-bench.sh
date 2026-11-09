#!/usr/bin/env bash
# framework-tests/test-bench.sh - the benchmark harness's arm resolution and
# its zero-model measurements. No model is called; every case is offline.
# Run directly: bash .io.v4rian.how-git/framework-tests/test-bench.sh
#
# Exit 0 if all cases pass, 1 if any fail.

set -uo pipefail
# shellcheck source=./_hermetic_env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_hermetic_env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCH="$NS_ROOT/bench/bin/bench"
WORK=$(mktemp -d -t v4rian-bench-test-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
FAIL_CASES=()
ok()   { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAIL_CASES+=("$1"); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

echo "→ bench arms"

# A loader that does not resolve must stop the harness before any run: a
# silent fallback to the baseline bundle measures the baseline twice.
out=$(python3 "$BENCH" run --dry --arms '' --arm 'ghost=@ref:no/such/loader/SKILL.md:HEAD' --tasks a \
  --out "$WORK/ghost" 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "loader"; then
  ok "an @ref loader missing at its ref is refused"
else
  bad "an @ref loader missing at its ref is refused (rc=$rc)" "$out"
fi

out=$(python3 "$BENCH" run --dry --arms '' --arm "ghost=$WORK/absent-loader.md:HEAD" --tasks a \
  --out "$WORK/ghost2" 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "loader" && ! printf '%s' "$out" | grep -q Traceback; then
  ok "a path loader that does not exist is refused by name"
else
  bad "a path loader that does not exist is refused by name (rc=$rc)" "$out"
fi

conf="$NS_ROOT/bench/arms/neo-git.conf"
if grep -qx 'loader=@ref:.io.v4rian.how-git/skills/how-git/SKILL.md' "$conf"; then
  ok "the neo-git arm loads the in-repo lean loader"
else
  bad "the neo-git arm loads the in-repo lean loader" "$(grep '^loader=' "$conf")"
fi

echo "→ bench loadbytes"

out=$(python3 "$BENCH" loadbytes --old-ref 5028b58 --new-ref HEAD 2>&1); rc=$?
lb_rc=$rc
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '^| Compose a commit |' \
   && printf '%s' "$out" | grep -q '^| Merge a pool into dev |'; then
  ok "loadbytes prints one row per decision-tree task"
else
  bad "loadbytes prints one row per decision-tree task (rc=$rc)" "$out"
fi

again=$(python3 "$BENCH" loadbytes --old-ref 5028b58 --new-ref HEAD 2>&1)
if [ $lb_rc -eq 0 ] && [ "$out" = "$again" ]; then
  ok "loadbytes is deterministic across runs"
else
  bad "loadbytes is deterministic across runs" "$(diff <(printf '%s\n' "$out") <(printf '%s\n' "$again") | head -20)"
fi

row=$(printf '%s\n' "$out" | grep '^| Compose a commit |')
loader_new=$(git -C "$NS_ROOT" show HEAD:.io.v4rian.how-git/skills/how-git/SKILL.md | wc -c | tr -d ' ')
skill_new=$(git -C "$NS_ROOT" show HEAD:.io.v4rian.how-git/skills/git-commit-audit/SKILL.md | wc -c | tr -d ' ')
if printf '%s' "$row" | grep -q "| $((loader_new + skill_new)) |"; then
  ok "the new arm counts the loader plus the row's skill (tool help aside)"
else
  bad "the new arm counts the loader plus the row's skill ($loader_new + $skill_new)" "$row"
fi

out=$(python3 "$BENCH" loadbytes --old-ref 5028b58 --new-ref HEAD --old-loader "$WORK/nope.md" 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "old loader"; then
  ok "loadbytes refuses a missing old loader"
else
  bad "loadbytes refuses a missing old loader (rc=$rc)" "$out"
fi

echo "→ bench fixtures"

# Every scripted fixture and reference message must pass the current gates:
# a refused merge leaves the fixture half built and the task unmeasurable.
out=$(python3 "$BENCH" run --dry --arms '' --arm 'head=@ref:.io.v4rian.how-git/skills/how-git/SKILL.md:HEAD' \
  --models opus --tasks c,d --out "$WORK/fixtures" 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'every reference solution passes'; then
  ok "the merge fixtures pass the current merge gates"
else
  bad "the merge fixtures pass the current merge gates (rc=$rc)" "$(printf '%s\n' "$out" | grep -E 'FAIL|ERROR|violations' | head -8)"
fi

echo "→ bench export / ingest"

EXP="$WORK/export"
out=$(python3 "$BENCH" export --arms 'how-git,neo-git' --tasks a --out "$EXP" 2>&1); rc=$?
n=$(ls -d "$EXP"/runs/*.agent.a-commit.r1 2>/dev/null | wc -l | tr -d ' ')
if [ $rc -eq 0 ] && [ "$n" = 2 ] && [ -f "$EXP/runs/how-git.agent.a-commit.r1/AGENT_PROMPT.md" ] \
   && [ -f "$EXP/runs/neo-git.agent.a-commit.r1/AGENT_PROMPT.md" ] && [ -d "$EXP/runs/neo-git.agent.a-commit.r1/repo/.git" ]; then
  ok "export builds one run dir with a fixture repo and AGENT_PROMPT.md per arm x task"
else
  bad "export builds one run dir with a fixture repo and AGENT_PROMPT.md per arm x task (rc=$rc n=$n)" "$out"
fi

# Every absolute path the prompt hands the agent must exist inside that run dir,
# and the loader must be the arm's own (neo-git: the in-repo lean loader).
cat > "$WORK/paths.py" <<'PYT'
import os, re, subprocess, sys
runs, ns = sys.argv[1], sys.argv[2]
bad = []
for r in sorted(os.listdir(runs)):
    run = os.path.join(runs, r)
    text = open(os.path.join(run, "AGENT_PROMPT.md")).read()
    paths = set(re.findall(r"`(/[^`\s]+)`", text))
    for p in paths:
        if not p.startswith(run + "/") and p != run:
            bad.append("%s: path outside the run dir %s" % (r, p))
        elif not os.path.exists(p):
            bad.append("%s: missing %s" % (r, p))
    loader = os.path.join(run, "home/.claude/skills/how-git/SKILL.md")
    if loader not in paths:
        bad.append("%s: loader path not named" % r)
    if r.startswith("neo-git."):
        want = subprocess.run(["git", "-C", ns, "show", "dev:.io.v4rian.how-git/skills/how-git/SKILL.md"],
                              capture_output=True, text=True).stdout
        if open(loader).read() != want:
            bad.append("%s: loader is not the arm's in-repo loader" % r)
    if "env -i " not in text or "HOME=%s/home" % run not in text:
        bad.append("%s: no sandbox env prefix" % r)
print("\n".join(bad))
PYT
miss=$(python3 "$WORK/paths.py" "$EXP/runs" "$NS_ROOT" 2>&1)
if [ -z "$miss" ]; then
  ok "every path an export prompt names resolves inside its run dir"
else
  bad "every path an export prompt names resolves inside its run dir" "$miss"
fi

# Play the external agent: the task's reference solution through the printed env prefix.
RUN="$EXP/runs/neo-git.agent.a-commit.r1"
prefix=$(grep -m1 '&& env -i ' "$RUN/AGENT_PROMPT.md" | sed -e 's/^ *//' -e 's/ <command>$//')
ident="GIT_AUTHOR_NAME='v4rian-waylon (Opus)' GIT_COMMITTER_NAME='v4rian-waylon (Opus)' GIT_AUTHOR_EMAIL=v4rian-waylon@users.noreply.github.com GIT_COMMITTER_EMAIL=v4rian-waylon@users.noreply.github.com"
eval "${prefix} ${ident} bash $NS_ROOT/bench/tasks/a-commit/reference.sh" >/dev/null 2>&1
out=$(python3 "$BENCH" ingest "$RUN" --tokens 250000 --tool-uses 12 --duration-ms 61000 --model opus 2>&1); rc=$?
row=$(tail -1 "$EXP/results.jsonl" 2>/dev/null)
if [ $rc -eq 0 ] && printf '%s' "$row" | python3 -c '
import json, sys
r = json.loads(sys.stdin.read())
assert r["arm"] == "neo-git" and r["task"] == "a-commit" and r["model"] == "claude-opus-5-5", r
assert r["success"] is True and r["compliance_pass"] == r["compliance_total"] and r["dataloss_ok"], r
assert r["total_tokens"] == 250000 and r["tool_calls"] == 12 and r["wall_s"] == 61.0, r
assert abs(r["total_cost_usd"] - 1.0) < 1e-9 and r["mode"] == "external-agent", r
'; then
  ok "ingest runs the checkers and appends a priced results.jsonl row"
else
  bad "ingest runs the checkers and appends a priced results.jsonl row (rc=$rc)" "$out
$row"
fi

out=$(python3 "$BENCH" ingest "$EXP/runs/how-git.agent.a-commit.r1" --tokens 100 --tool-uses 1 --duration-ms 1000 \
  --model opus --input-tokens 10 --output-tokens 5 --cache-read-tokens 80 --cache-write-tokens 5 2>&1); rc=$?
rows=$(grep -c . "$EXP/results.jsonl")
again=$(python3 "$BENCH" ingest "$RUN" --tokens 250000 --tool-uses 12 --duration-ms 61000 --model opus 2>&1)
rows2=$(grep -c . "$EXP/results.jsonl")
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'success=False' && [ "$rows" = 2 ] && [ "$rows2" = 2 ]; then
  ok "an untouched run ingests as a failure and a re-ingest replaces its row"
else
  bad "an untouched run ingests as a failure and a re-ingest replaces its row (rc=$rc rows=$rows/$rows2)" "$out"
fi

sm=$(python3 "$BENCH" summary "$EXP/results.jsonl" 2>&1)
df=$(python3 "$BENCH" diff "$EXP/results.jsonl" --arms how-git,neo-git 2>&1)
if printf '%s' "$sm" | grep -q '^| neo-git | claude-opus-5-5 | a-commit | 1 |' \
   && printf '%s' "$df" | grep -q '^| total tokens | 100 | 250000 |'; then
  ok "summary and diff read ingested rows"
else
  bad "summary and diff read ingested rows" "$sm
$df"
fi

echo
echo "=== Summary ==="
echo "  $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  printf '  - %s\n' "${FAIL_CASES[@]}"
  exit 1
fi
