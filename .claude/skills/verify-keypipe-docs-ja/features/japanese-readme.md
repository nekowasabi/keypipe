# Japanese README translation

## Sub-features

- README.ja.md mirrors README.md sections/structure; code blocks, commands, paths, trigger `@@@`, JSON keys, flag names stay in English.
- Mutual links near the top of both files (README.md -> README.ja.md, README.ja.md -> README.md).

## How to get to it (user POV)

Open `README.ja.md` in Japanese; open `README.md` in English. Each links to the other near the top.

## Driving it with verify-docs-ja.sh

```sh
REPO=/workspace/keypipe .claude/skills/verify-keypipe-docs-ja/verify-docs-ja.sh
```

PASS means the file exists, both links resolve by name, Japanese markers are present, and `@@@` / `--smoke-feed` / `--config` survived translation.

## Gotchas

- A missing or empty README.ja.md is a FAIL (Vd1), never a SKIP. Do not weaken the journey to make it pass.
- Machine-translated flag names or JSON keys are a fidelity bug even when Vd5 passes; Vd5 only checks the three load-bearing terms.
- This skill never builds Swift and never edits sources, tests, or config.
