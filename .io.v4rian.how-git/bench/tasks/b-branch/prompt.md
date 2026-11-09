Implement a small `greet` feature on a new working branch allocated per the protocol (base: dev), as exactly three atomic commits in this order:
1. `src/greet.sh`: prints `Hello, <name>!` for its first argument, defaulting to `world`.
2. `tests/greet_test.sh`: asserts both outputs and exits non-zero on failure. Run it before committing.
3. A `## Usage` section at the end of `README.md` documenting `bash src/greet.sh <name>`.
Push your work. Do not merge anything.
