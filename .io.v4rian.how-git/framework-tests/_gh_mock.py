#!/usr/bin/env python3
"""Mock gh CLI for offline e2e tests.

Implements just enough of the gh surface area to exercise the v4rian
template's GitHub-touching code paths (claim-main-release's Release
creation, auto-rebase-pools' PR list/create/edit/close/comment, build-
on-tag's release create/upload). State persists in a JSON file at
$GH_MOCK_STATE so multiple invocations within a test see consistent
state.

Supported commands:
  gh pr list [--state open|closed|all] [--base X] [--json ...]
  gh pr create --title T --body B --base BASE --head HEAD [--repo R]
  gh pr edit NUM --title T [--body B]
  gh pr close NUM [--comment C]
  gh pr view NUM [--json ...]
  gh pr comment NUM --body B
  gh release create TAG [--title T] [--generate-notes] [--notes N]
  gh release view TAG
  gh release upload TAG FILE...
  gh auth token
  gh --version
  gh api ...  (records the call, returns {})
"""

import json
import os
import sys
import tempfile

# Fallback honours TMPDIR, which the lifecycle runner points at its per-run
# root, so two concurrent runs never share one state file.
STATE = os.environ.get('GH_MOCK_STATE') or os.path.join(tempfile.gettempdir(), '.gh-mock-state.json')


def load():
    if not os.path.exists(STATE):
        return {'prs': [], 'releases': [], 'comments': [], 'next_pr': 1,
                'api_calls': [], 'statuses': {}, 'check_runs': {}}
    with open(STATE) as f:
        s = json.load(f)
    # `statuses` maps a commit SHA to the list of {context,state,description}
    # entries posted to it; `check_runs` maps a commit SHA to the list of
    # {name,conclusion} Actions check runs reported on it. Older state files
    # predate the keys; default them so the commit-status and check-run
    # read/post paths work against any seeded state.
    s.setdefault('statuses', {})
    s.setdefault('check_runs', {})
    return s


def save(s):
    with open(STATE, 'w') as f:
        json.dump(s, f, indent=2)


def pr_mergeable(p):
    """Mergeable state of a PR as gh would compute it. Tests flip a PR to
    CONFLICTING (or UNKNOWN) via GH_MOCK_PR_MERGEABLE_<N> so consumers of
    the mergeability signal (validate-pr-open reconcile seeding, queue)
    can exercise their conflict paths without a real merge conflict."""
    override = os.environ.get('GH_MOCK_PR_MERGEABLE_%d' % p['number'])
    return override if override else p.get('mergeable', 'MERGEABLE')


def parse_kv(args):
    """Pull --flag value pairs out of an arg list; positional args returned separately."""
    flags = {}
    pos = []
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith('--'):
            key = a[2:]
            if i + 1 < len(args) and not args[i + 1].startswith('--'):
                flags[key] = args[i + 1]
                i += 2
            else:
                flags[key] = True
                i += 1
        else:
            pos.append(a)
            i += 1
    return flags, pos


def cmd_pr_list(flags):
    state = load()
    target_state = flags.get('state', 'open')
    base_filter = flags.get('base')
    head_filter = flags.get('head')
    out = []
    for p in state['prs']:
        if target_state != 'all' and p['state'] != target_state:
            continue
        if base_filter and p['base'] != base_filter:
            continue
        if head_filter and p['head'] != head_filter:
            continue
        out.append({
            'number': p['number'],
            'title': p['title'],
            'headRefName': p['head'],
            'baseRefName': p['base'],
            'mergeable': pr_mergeable(p),
            'body': p.get('body', ''),
            'url': 'https://github.example/mock/pull/%d' % p['number'],
        })
    # Minimal --jq support for the reconcile-PR idempotency check, which
    # asks for '.[0].number' to read the first matching PR's number (empty
    # when no PR matches the head). Full jq grammar is out of scope.
    jq = flags.get('jq')
    if jq == '.[0].number':
        print(out[0]['number'] if out else '')
        return 0
    print(json.dumps(out))
    return 0


def _body_flag(flags):
    # gh accepts the body inline (--body) or from a file (--body-file).
    if isinstance(flags.get('body-file'), str):
        with open(flags['body-file']) as f:
            return f.read()
    return flags.get('body', '')


def cmd_pr_create(flags):
    state = load()
    n = state['next_pr']
    state['next_pr'] += 1
    state['prs'].append({
        'number': n,
        'title': flags.get('title', ''),
        'body': _body_flag(flags),
        'head': flags.get('head', ''),
        'base': flags.get('base', ''),
        'state': 'open',
        'mergeable': 'MERGEABLE',
    })
    save(state)
    repo = flags.get('repo', 'mock/repo')
    print(f'https://github.com/{repo}/pull/{n}')
    return 0


def cmd_pr_edit(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    for p in state['prs']:
        if p['number'] == n:
            if 'title' in flags:
                p['title'] = flags['title']
            if 'body' in flags:
                p['body'] = flags['body']
            save(state)
            print(f'edited PR #{n}')
            return 0
    return 1


def cmd_pr_close(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    for p in state['prs']:
        if p['number'] == n:
            p['state'] = 'closed'
            if 'comment' in flags:
                state['comments'].append({'pr': n, 'body': flags['comment']})
            save(state)
            print(f'closed PR #{n}')
            return 0
    return 1


def cmd_pr_merge(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    for p in state['prs']:
        if p['number'] == n:
            p['state'] = 'merged'
            save(state)
            print(f'merged PR #{n}')
            return 0
    return 1


def cmd_pr_ready(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    for p in state['prs']:
        if p['number'] == n:
            p['draft'] = False
            save(state)
            return 0
    return 1


def cmd_pr_view(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    for p in state['prs']:
        if p['number'] == n:
            # Output in gh's standard shape: head -> headRefName, base -> baseRefName
            out = {
                'number': p['number'],
                'title': p['title'],
                'body': p.get('body', ''),
                'headRefName': p['head'],
                'baseRefName': p['base'],
                'state': p['state'],
                'mergeable': pr_mergeable(p),
            }
            # Minimal --jq support: '.field' extracts a single top-level key
            # as a bare string. Used by validate-pr-open and the claim flow
            # to fetch the current title/body. Full jq grammar is out of
            # scope; tests that need richer expressions can extend this.
            jq = flags.get('jq')
            if isinstance(jq, str) and jq.startswith('.') and '.' not in jq[1:]:
                key = jq[1:]
                val = out.get(key, '')
                print(val if isinstance(val, str) else json.dumps(val))
            else:
                print(json.dumps(out))
            return 0
    return 1


def cmd_pr_comment(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    state['comments'].append({'pr': n, 'body': flags.get('body', '')})
    save(state)
    return 0


def cmd_release_create(flags, pos):
    if not pos:
        return 1
    tag = pos[0]
    state = load()
    state['releases'].append({
        'tag': tag,
        'title': flags.get('title', tag),
        'notes': flags.get('notes', ''),
        'generated_notes': flags.get('generate-notes', False),
        'assets': [],
    })
    save(state)
    print(f'release {tag} created')
    return 0


def cmd_release_view(flags, pos):
    if not pos:
        return 1
    tag = pos[0]
    state = load()
    for r in state['releases']:
        if r['tag'] == tag:
            print(json.dumps(r))
            return 0
    return 1


def cmd_release_upload(flags, pos):
    if not pos:
        return 1
    tag = pos[0]
    files = pos[1:]
    state = load()
    for r in state['releases']:
        if r['tag'] == tag:
            r['assets'].extend(files)
            save(state)
            return 0
    return 1


def cmd_auth_token():
    print('mock-token-xxxxx')
    return 0


def _api_parse_fields(args):
    """Pull -f key=value (gh api field) pairs out of an api arg list."""
    fields = {}
    i = 0
    while i < len(args):
        if args[i] in ('-f', '--field', '--raw-field') and i + 1 < len(args):
            kv = args[i + 1]
            if '=' in kv:
                k, v = kv.split('=', 1)
                fields[k] = v
            i += 2
        else:
            i += 1
    return fields


# Short flags that consume the following arg as their value. parse_kv only
# recognizes --long flags, so without skipping these their values (and the
# flags themselves) leak into the positional list and mask the endpoint.
_API_VALUE_FLAGS = {'-X', '--method', '-f', '--field', '-F', '--raw-field',
                    '-q', '--jq', '-H', '--header'}


def _api_url(args):
    """Resolve the gh api endpoint: the first positional that is neither a
    flag nor a flag value. Without this, a call like `api -X POST <url> -f k=v`
    resolves url to `-X` (parse_kv dumps short flags into pos), so endpoint
    matching (e.g. `/statuses/`) silently fails and the call is a no-op."""
    i = 0
    while i < len(args):
        a = args[i]
        if a in _API_VALUE_FLAGS:
            i += 2
            continue
        if a.startswith('-'):
            i += 1
            continue
        return a
    return ''


def cmd_api(args):
    state = load()
    state['api_calls'].append({'args': args})
    flags, pos = parse_kv(args)
    fields = _api_parse_fields(args)
    # The HTTP method (gh api -X POST / -X PATCH). parse_kv stores -X as a
    # short flag; recover it directly from the arg list.
    method = ''
    for i, a in enumerate(args):
        if a in ('-X', '--method') and i + 1 < len(args):
            method = args[i + 1].upper()
    url = _api_url(args)
    jq = flags.get('jq')

    # POST repos/<owner>/<repo>/statuses/<sha>: record the commit status
    # keyed by the trailing SHA so a later commits/<sha>/status read returns
    # it. The auto-rebase pass uses this to inherit already-passed required
    # checks onto the reconcile candidate SHA.
    if '/statuses/' in url and method == 'POST':
        sha = url.rsplit('/', 1)[-1]
        entry = {
            'context': fields.get('context', ''),
            'state': fields.get('state', ''),
            'description': fields.get('description', ''),
        }
        state['statuses'].setdefault(sha, [])
        # Latest post for a context wins (mirrors GitHub's combined-status
        # semantics where the most recent status per context is authoritative).
        state['statuses'][sha] = [
            e for e in state['statuses'][sha] if e['context'] != entry['context']
        ]
        state['statuses'][sha].append(entry)
        save(state)
        print('{}')
        return 0

    # POST repos/<owner>/<repo>/check-runs: record an Actions check run keyed
    # by its head_sha so a later commits/<sha>/check-runs read returns it.
    # This models how GitHub Actions reports every required.* job: as a check
    # run, NOT a legacy commit status. The legitimation gate reads both.
    if url.endswith('/check-runs') and method == 'POST':
        sha = fields.get('head_sha', '')
        entry = {
            'name': fields.get('name', ''),
            'conclusion': fields.get('conclusion', ''),
        }
        state['check_runs'].setdefault(sha, [])
        state['check_runs'][sha] = [
            e for e in state['check_runs'][sha] if e['name'] != entry['name']
        ]
        state['check_runs'][sha].append(entry)
        save(state)
        print('{}')
        return 0

    # GET repos/<owner>/<repo>/commits/<sha>/check-runs: return the check runs
    # for a SHA in GitHub's shape ({total_count, check_runs:[...]}). The
    # auto-rebase legitimation gate reads this alongside the status endpoint.
    if '/commits/' in url and url.endswith('/check-runs'):
        sha = url[:-len('/check-runs')].rsplit('/', 1)[-1]
        runs = state['check_runs'].get(sha, [])
        save(state)
        print(json.dumps({'total_count': len(runs), 'check_runs': runs}))
        return 0

    # GET repos/<owner>/<repo>/commits/<sha>/status: return the combined
    # status for a SHA in GitHub's shape ({state, statuses:[...]}). Used by
    # the auto-rebase legitimation gate to read the original PR head's
    # required checks before inheriting them onto the reconcile candidate.
    if '/commits/' in url and url.endswith('/status'):
        sha = url[:-len('/status')].rsplit('/', 1)[-1]
        entries = state['statuses'].get(sha, [])
        combined = 'success' if entries and all(
            e['state'] == 'success' for e in entries) else (
            'pending' if not entries else 'failure')
        save(state)
        print(json.dumps({'state': combined, 'statuses': entries}))
        return 0

    save(state)
    # Minimal canned responses for the API paths the v4rian template
    # exercises during PR-open validation. Anything not matched falls
    # through to the empty-object default so callers that only record
    # the call still pass.
    # repos/<owner>/<repo>/collaborators/<actor>/permission - the actor
    # check used by validate-pr-open's Step 2 (dev->main admin gate)
    # and by bin/init-pool-merge / bin/init-release advisory checks.
    if '/collaborators/' in url and url.endswith('/permission'):
        if isinstance(jq, str) and jq == '.permission':
            print('admin')
        else:
            print(json.dumps({'permission': 'admin'}))
        return 0
    print('{}')
    return 0


def main():
    args = sys.argv[1:]
    if not args:
        print('mock-gh: missing command', file=sys.stderr)
        return 1
    if args == ['--version']:
        print('gh version mock 1.0.0')
        return 0
    if args[0] == 'api':
        return cmd_api(args[1:])

    if len(args) < 2:
        print(f'mock-gh: incomplete: {args}', file=sys.stderr)
        return 1

    cmd, sub = args[0], args[1]
    flags, pos = parse_kv(args[2:])
    key = f'{cmd}-{sub}'

    dispatch = {
        'pr-list': lambda: cmd_pr_list(flags),
        'pr-create': lambda: cmd_pr_create(flags),
        'pr-edit': lambda: cmd_pr_edit(flags, pos),
        'pr-close': lambda: cmd_pr_close(flags, pos),
        'pr-merge': lambda: cmd_pr_merge(flags, pos),
        'pr-ready': lambda: cmd_pr_ready(flags, pos),
        'pr-view': lambda: cmd_pr_view(flags, pos),
        'pr-comment': lambda: cmd_pr_comment(flags, pos),
        'release-create': lambda: cmd_release_create(flags, pos),
        'release-view': lambda: cmd_release_view(flags, pos),
        'release-upload': lambda: cmd_release_upload(flags, pos),
        'auth-token': cmd_auth_token,
    }

    fn = dispatch.get(key)
    if fn is None:
        print(f'mock-gh: unsupported: {cmd} {sub}', file=sys.stderr)
        return 1
    return fn()


if __name__ == '__main__':
    sys.exit(main())
