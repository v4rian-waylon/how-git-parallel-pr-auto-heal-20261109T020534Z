#!/usr/bin/env bash
# required.offline-test-suites.sh — sys-layer push test that fronts
# the existing framework offline test suite through the new layered
# dispatcher.
#
# Runs on every push that lands a new head SHA. The pr-open event
# does NOT re-run this test; the PR reuses the latest push-
# validation result for the head SHA via the bound check context
# name 'required.offline-test-suites'.
#
# Delegates to offline-test.sh which already gates on the
# FRAMEWORK_REPO marker (consumer repos: marker absent → clean
# skip; framework source: marker present → run lifecycle + hooks).
# The sys layer of the dispatcher is itself gated on the same
# marker, so on a consumer this script never actually executes; on
# the framework source repo this is the canonical entry point for
# the dev-into-main release path's pre-merge gate.
#
# Posts as 'required.offline-test-suites'. The legacy check name was
# 'offline test suites' (with spaces); branch protection bindings
# referring to the old name are translated by bin/bootstrap-ci on
# the next run as part of step 5's required.* discovery.

set -uo pipefail
exec bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/workflows/offline-test.sh"
