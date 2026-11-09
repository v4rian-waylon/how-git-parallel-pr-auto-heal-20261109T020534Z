| arm | model | task | n | success % | compliance % | no loss % | readability | turns | tool calls | input | cache read | cache write | output | protocol B read | hook denials | retries | nested AI calls | total tokens | $ total | wall s | violations |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| how-git | claude-fable-5-1 | a-commit | 3 | 100 | 100 | 100 | 100 | 19 | 17 | 303 | 498237 | 60319 | 7543 | 198823 | 0 | 0 | 0 | 566402 | 1.7111 | 99 | - |
| how-git | claude-fable-5-1 | b-branch | 3 | 100 | 100 | 100 | 93 | 61 | 59 | 601 | 1733337 | 100345 | 19835 | 216133 | 1.3333 | 1 | 0 | 1854118 | 3.438 | 292 | - |
| how-git | claude-fable-5-1 | c-merge-dev | 3 | 100 | 92 | 100 | 100 | 45 | 43 | 356 | 770549 | 105487 | 13688 | 356157 | 1.3333 | 1.3333 | 0 | 890080 | 2.9903 | 183 | merge-body-nested-list x3 |
| how-git | claude-fable-5-1 | d-ship | 3 | 100 | 100 | 100 | 93 | 46 | 44 | 473 | 1026209 | 97405 | 15337 | 296004 | 0.3333 | 0.6667 | 0 | 1139424 | 2.9762 | 212 | - |
| how-git | claude-fable-5-1 | e-rewrite | 3 | 100 | 100 | 0 | 100 | 42 | 40 | 527 | 862698 | 64254 | 18155 | 146558 | 1 | 0.3333 | 0 | 945633 | 2.4138 | 234 | - |
| how-git | claude-fable-5-1 | f-snapshots | 3 | 100 | 94 | 100 | 93 | 86 | 84 | 580 | 1914117 | 167355 | 33404 | 401454 | 1.3333 | 0.3333 | 0 | 2115456 | 5.5016 | 408 | branch-naming x1, identity x1 |
| how-git | claude-opus-5-5 | a-commit | 3 | 100 | 100 | 100 | 93 | 8.6667 | 6.6667 | 15 | 177053 | 21678 | 1576 | 36830 | 0 | 0 | 0 | 200323 | 0.2404 | 23 | - |
| how-git | claude-opus-5-5 | b-branch | 3 | 100 | 100 | 100 | 100 | 15 | 13 | 27 | 494152 | 40837 | 4024 | 124223 | 0 | 0 | 0 | 539040 | 0.5061 | 46 | - |
| how-git | claude-opus-5-5 | c-merge-dev | 3 | 67 | 85 | 100 | 100 | 10 | 8.3333 | 18 | 217272 | 22966 | 2056 | 62204 | 0.3333 | 0 | 0 | 242312 | 0.2684 | 30 | merge-body-nested-list x2, merge-title-spec x1, no-ff x1, pool-vaulted x1, tag-pushed x1 |
| how-git | claude-opus-5-5 | d-ship | 3 | 67 | 94 | 100 | 95 | 11 | 9 | 19 | 261720 | 28483 | 2260 | 102719 | 0 | 0 | 0 | 292482 | 0.3255 | 33 | no-ff x1, release-title-spec x1 |
| how-git | claude-opus-5-5 | e-rewrite | 3 | 67 | 93 | 67 | 95 | 16 | 13 | 25 | 338917 | 22944 | 3653 | 37807 | 0.6667 | 0.6667 | 0 | 365539 | 0.3245 | 54 | branch-naming x1, pushed x1 |
| how-git | claude-opus-5-5 | f-snapshots | 3 | 33 | 100 | 100 | 94 | 32 | 30 | 44 | 978788 | 32504 | 5115 | 122620 | 0.6667 | 0.6667 | 0 | 1016451 | 0.5583 | 66 | - |

Runs 36, total tokens 30501780, total cost $63.7628 (prices: claude-api skill (Claude Code 2.1.312) shared/models.md + shared/prompt-caching.md, list prices cached 2026-10-06).
