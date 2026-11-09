# _hermetic_env.sh - sourced first by every framework suite.
#
# The suites simulate CI themselves (a test that wants a real run sets
# GITHUB_ACTIONS and GITHUB_RUN_ID for its own subprocess). Run inside a
# real GitHub Actions job they would otherwise inherit the runner's CI
# variables and token, so identity, claim and hook code under test take
# their real-CI branches and the suites fail on Linux CI only. Clear them,
# along with any commit identity exported by the caller, so a run is the
# same on a laptop and on a runner.
# grep -E, not sed alternation: BSD sed has no \| in basic expressions.
for _hv in $(env | grep -oE '^(GITHUB|RUNNER|ACTIONS)_[A-Za-z0-9_]*=' | tr -d '='); do
  unset "$_hv"
done
unset _hv CI GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
  GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL \
  GIT_AUTHOR_DATE GIT_COMMITTER_DATE 2>/dev/null || true

# A runner has no global git identity (the developer's laptop does), so a test that
# commits without -c user.* passed locally and died with exit 128 on CI. Every run
# reads one fixed global config instead of the machine's, and no system config.
_hg="${TMPDIR:-/tmp}"; _hg="${_hg%/}/v4rian-test-gitconfig"
printf '[user]\n\tname = v4rian-test\n\temail = test@v4rian.test\n[init]\n\tdefaultBranch = main\n[advice]\n\tdefaultBranchName = false\n' > "$_hg"
export GIT_CONFIG_GLOBAL="$_hg" GIT_CONFIG_NOSYSTEM=1
unset _hg
