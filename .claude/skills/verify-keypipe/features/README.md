# Feature map: keypipe MVP journeys

Each journey is driven by `verify.sh` (see `../SKILL.md`). A journey whose
precondition is missing reports SKIP/FAIL with the reason, never a weakened
assertion.

- `daemon-lifecycle.md`: background process, start line, signal shutdown (S2).
- `config-trigger.md`: JSON config mapping `@@@` to an action (S3).
- `context-stub.md`: optional context field, always-match stub (S4).
- `trigger-pipeline.md`: pure buffer matcher detecting `@@@` (S5).
