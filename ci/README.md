# ci/ — consumer CI hook directory

This directory is the consumer-owned (usr-layer) extension point for the v4rian CI dispatcher. Drop shell scripts under `ci/tests/<trigger>/` or `ci/audits/<trigger>/` and they run as separate status checks on the matching trigger. Two file conventions decide the binding:

| Filename prefix | Behavior |
|---|---|
| `required.*` | Bound as a REQUIRED status check on PRs (added to branch protection by `bin/bootstrap-ci`). Merge is blocked until the check is green. |
| anything else | Runs as an advisory check. Failures surface in the PR conversation but do not block merge. |

## Triggers

| Trigger dir | Fires on |
|---|---|
| `push` | Every push to any branch. |
| `pr-open` | `pull_request` opened, synchronize, or reopened, targeting dev or main. |
| `pr-merge-dev` | `pull_request` closed-merged into dev. |
| `pr-merge-main` | `pull_request` closed-merged into main. |
| `tag` | Tag push matching `v*`. |

Every `.sh` in a trigger directory is invoked separately; the file's basename minus the `.sh` extension becomes the GitHub check context name (e.g. `ci/audits/pr-open/required.compile.sh` posts as `required.compile`).

## Layering — usr vs sys

Two layers feed the dispatcher:

- **usr layer**, this `ci/` directory at the repo root, is the consumer's surface. Any project consuming the v4rian framework adds its own scripts here.
- **sys layer**, `.io.v4rian.how-git/ci/`, ships with the framework and runs ONLY on the framework source repo (gated by the FRAMEWORK_REPO marker, the same gate that already governs the offline test suite).

When this repo is a consumer the dispatcher walks the usr layer alone; on the framework source repo it walks both layers and runs every matched script. The split mirrors an operating system's `/usr` vs `/sys` separation so the framework can carry its own audits without leaking them into consumer CI.

## Contract per script

Every `.sh` in this directory runs from the repo root with a clean checkout. The script must:

- Exit 0 on pass, non-zero on fail.
- Write its diagnostic output to stdout or stderr; the dispatcher captures it into the workflow log and attaches it to the status check.
- Not write outside its own work area; the workflow's `actions/checkout` provides a fresh tree per run.

The dispatcher sets `CI_TRIGGER`, `CI_LAYER` (`usr` or `sys`), and `CI_CHECK_NAME` in the environment before invoking each script.
