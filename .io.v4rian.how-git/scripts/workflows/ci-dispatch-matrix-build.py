#!/usr/bin/env python3
# ci-dispatch-matrix-build.py
#
# Reads TAB-separated tuples from stdin (one per discovered script,
# as emitted by ci-dispatch.sh --list) and prints a JSON
# {"include": [...]} value suitable for a GitHub Actions strategy.matrix.
#
# Pulled out of ci-dispatch.yml's inline run block because YAML block
# scalars terminate at the first line that dedents below the block
# indent, and a Python heredoc with unindented top-level statements
# kills the block early. Keeping the script in its own file sidesteps
# the YAML / Python indentation collision entirely.

import json
import sys


def main() -> int:
    # Dedupe by (kind, check): the template ships usr-layer wrappers for
    # every required gate so consumers (whose sys layer is skipped) still
    # report the statuses the branch rules demand. On the framework source
    # BOTH layers enumerate the same check names; running both would post
    # duplicate checks, so the sys entry (the canonical script) wins and
    # the usr wrapper is dropped from the matrix.
    chosen = {}
    order = []
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        parts = line.split('\t')
        if len(parts) < 6:
            continue
        layer, kind, path, name, req, bn = parts[:6]
        entry = {
            'layer': layer,
            'kind': kind,
            'script': path,
            'check': name,
            'required': req,
            'basename': bn,
        }
        key = (kind, name)
        if key not in chosen:
            chosen[key] = entry
            order.append(key)
        elif layer == 'sys' and chosen[key]['layer'] == 'usr':
            chosen[key] = entry
    print(json.dumps({'include': [chosen[k] for k in order]}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
