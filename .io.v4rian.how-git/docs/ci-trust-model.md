# CI trust model

On a `push`, a same-repository `pull_request` or a `workflow_dispatch`, GitHub runs the workflow file of the pushed or selected ref. Anyone who can push a branch can therefore edit a workflow on that branch and print every secret the job can reach. Overlaying "trusted" scripts inside such a job does not help, because the job definition itself is untrusted. The framework keeps secrets away from that code with three rules.

## 1. Secrets live in one protected environment

The CI bot App key, the Claude token and the Anthropic key live only in the GitHub Environment `v4rian-trusted`, never as repository secrets. Its deployment branch policy admits `dev`, `main` and `v*` tags and nothing else, so a job on any other ref cannot read them, whatever its workflow says. `bin/bootstrap-ci` creates the environment and its policy, stores the secrets there and deletes the repository-level copies.

Environments with deployment branch policies are available on public repositories and on paid plans. On a private repository of a free plan, connected mode has no branch protection either; run such a repository off-grid.

## 2. Code from an untrusted ref runs without secrets

`ci-dispatch.yml` grants `contents: read` at the workflow level. The `check` job runs the gates of the pushed ref (suites, compile, coverage, runtime, the deterministic commit rules) with no secret and a read-only token; its conclusion is the status check. Only the `check-trusted` job, bound to `v4rian-trusted`, runs the claims and the tag build, and therefore only on `dev`, `main` and tags.

## 3. Judgment on a pull request runs from the base branch

The Claude commit judgment needs a secret and must judge commits from untrusted branches. It runs in `commit-judgment.yml` on `pull_request_target`: GitHub takes that workflow from the base branch (`dev`), the job is bound to `v4rian-trusted` with the base ref, and it reads the pull request's commits as data (it fetches them; it never checks them out or executes them). It posts `required.commit-judgment` on the head SHA.

## Consequences

- A change to a gate script takes effect for other branches only after it merges into dev. That is the point: a branch cannot weaken the gates that judge it.
- `workflow_dispatch` entries (dev-merge, main-merge, build-on-tag, audit-pushed-branch) reach secrets only when dispatched on dev, main or a tag, whatever their own admin checks say.
- The canaries use their own environment, `v4rian-canary`, admitted only on `dev` and `main`, and never run on pull request events.
- Operator tokens never travel as workflow inputs: inputs are not secret (they appear in the event payload, logs and webhooks).
