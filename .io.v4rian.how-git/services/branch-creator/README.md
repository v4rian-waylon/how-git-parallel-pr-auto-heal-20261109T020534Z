# services/branch-creator

The synchronous allocator service that creates `pool/X` + `safety/X` branch
pairs atomically. **Not implemented in this skeleton** — your team picks
the stack and deployment model.

This README is the spec. See also `docs/IMPLEMENTATION_HANDOFF.md`
(Milestone 2) for the full acceptance criteria.

---

## What it does

Receives a JSON request, atomically allocates the next `nN`, creates
both the `pool/...` and `safety/...` branches on the remote pointing at
current `dev` HEAD, and returns synchronously to the caller.

If either branch fails to create, **rolls back the partial state** —
the operation is all-or-nothing (Invariant I7 in the strategy doc).

## Request / Response

### POST /v1/branches

**Request:**

```json
{
  "kind": "feature",
  "short_name": "parser_rewrite",
  "sprint": 4,
  "jira": "PROJ-123"
}
```

`kind` and `short_name` are required. `sprint` and `jira` are optional.

**200 OK:**

```json
{
  "branch": "pool/n14.feature.sprint4-PROJ-123-parser_rewrite",
  "safety": "safety/n14.feature.sprint4-PROJ-123-parser_rewrite",
  "commit": "abc123def456…"
}
```

**4xx / 5xx:**

```json
{
  "error": "validation|conflict|allocation_failed|partial_pair_rollback|...",
  "message": "human-readable detail"
}
```

## Allocation algorithm

1. Validate input (regex same as `pre-push` hook)
2. Acquire allocation lock (see "Concurrency" below)
3. List existing remote refs matching `refs/heads/pool/n*` and
   `refs/heads/safety/n*`
4. Extract the integer after `n` for each; find the max across both
   sets; new `nN = max + 1`
5. Construct branch names:
   - `pool/n{N}.{kind}.{sprint_prefix}{jira_prefix}{short_name}`
   - `safety/n{N}.{kind}.{sprint_prefix}{jira_prefix}{short_name}`
   - `sprint_prefix = "sprint{n}-"` if sprint set, else `""`
   - `jira_prefix = "{key}-"` if jira set, else `""`
6. Get current `dev` HEAD SHA
7. Create both branches at that SHA via the Git Data API
8. If second creation fails, delete the first; return
   `partial_pair_rollback` error
9. Release lock
10. Return success with both branch names

## Concurrency

Two requests arriving in parallel must produce two distinct `nN` values.
Pick one of:

- **Advisory lock in a KV store** (Redis SETNX, Cloudflare KV, etc.).
  Simplest if you have one available.
- **Compare-and-swap on a sentinel ref.** Maintain a
  `refs/internal/next-n` blob; update it atomically with
  `If-Match: <sha>` via the Git Data API.
- **Single-instance service.** If the service runs as one process at a
  time (e.g., a single Worker handling all requests serially), an
  in-memory mutex is enough.

## Identity

Run as a **GitHub App** (or equivalent on other forges) with
`contents:write` permission scoped to this repository. Repository Rules
make this identity the *only* allowed creator of `pool/*` and `safety/*`
branches. See `docs/repo-config.md`.

## Implementation options (in order of complexity)

### Option 1 — Cloudflare Worker (simplest production-grade)

- ~100 LOC of TypeScript
- KV namespace for the allocation lock
- GitHub App auth via short-lived JWT
- Deployed via `wrangler deploy`
- Pricing: free tier covers low-volume teams

### Option 2 — AWS Lambda + DynamoDB

- Lambda function (Python or Node) behind API Gateway
- DynamoDB conditional write for the allocator lock
- IAM role for the GitHub App credentials (via Secrets Manager)

### Option 3 — Self-hosted (Go/Node service)

- Standalone binary behind your load balancer
- Postgres advisory lock or Redis SETNX for allocation
- More moving parts; only worth it if you have an internal services platform

### Option 4 — `workflow_dispatch` + polling (no service)

- Implement the allocator as a GitHub Actions workflow with
  `workflow_dispatch`
- CLI client triggers the workflow, polls for completion via the
  Actions API
- Not truly synchronous (typically 30–90s round-trip)
- Acceptable for low-volume teams that want to avoid running a service

Pick what fits your operational appetite. Option 1 (Cloudflare Worker)
is the recommended default for most teams. Option 4 is the cheapest
path to "it works at all."

## Hand off to your engineer / Claude Code

Drop this in their lap and they'll have everything needed:

- The contract (request/response above)
- The algorithm
- The concurrency requirements
- The deployment options
- Acceptance criteria in `docs/IMPLEMENTATION_HANDOFF.md`
- The invariants in `docs/Git_Strategy.md`
