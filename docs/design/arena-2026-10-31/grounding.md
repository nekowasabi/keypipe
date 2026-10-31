# Grounding for the keypipe context/output design arena

## User's goal (restated)

keypipe is a macOS background daemon. The user types a trigger (e.g. `@@@`) in a text field; keypipe takes the field's text, runs it through a configurable transform (shell script, `claude -p`, API call), and hands the result to a configurable sink (replace the field, tmux, Herdr, Grok Bot, CotEditor, a webhook, any script). Everything is declared in one JSON config. Selected text is out of scope.

The user now asks whether the design's **context model** and **execution model** are valid and feasible, specifically:

- Context axes: the frontmost app; the focus state, including "a text field is focused", "nothing useful is focused", and "the user is mid-IME-composition"; and the likelihood that some apps need app-specific handling.
- Execution axes: shell commands, webhooks, and app-specific special processing.

Deliverable of the arena: one candidate design for how context and execution are modeled, as a caller-first sketch (usage, types, signatures, module map) with a rationale that explicitly judges validity and feasibility against the measured facts below.

## Current design (read these files in full)

- `/Users/takets/repos/keypipe/docs/design/context-rules.md` (design, revision 2, with verified-facts section)
- `/Users/takets/repos/keypipe/docs/design/verification-plan.md` (verification plan and the measured results table)
- `/Users/takets/repos/keypipe/.claude/skills/verify-keypipe-rules/SKILL.md` (the transcript-line contract the verifier asserts)
- Current code (old schema, pre-implementation): `/Users/takets/repos/keypipe/Sources/keypipe/*.swift`

Current shape in one paragraph: a rule is `trigger` + `when { app?: [bundleId], focus: textField|any }` + optional `transform` (shell, input on stdin/`$1`/`KEYPIPE_INPUT`) + `output` (builtin `replaceInput|insert|clipboard|notify|none` or `{ "shell": "..." }`). Fire sequence: match trigger, select first rule whose `when` holds against a snapshot `{app, focusIsTextField}`, Backspace the trigger, read the field, transform, apply output. Boundaries: `Desktop` protocol (snapshot, erase, fieldText, apply) with `MacDesktop` (AX + CGEvent) and `FakeDesktop` (JSON-driven, used by `--context` + `--smoke-feed`).

## Measured facts (macOS 26.6, 2026-10-31, throwaway Swift probes)

Probes live at `/Users/takets/repos/keypipe/.claude/skills/verify-keypipe-rules/probes/` and `/private/tmp/claude-501/-Users-takets-repos-keypipe/91c00c6f-3cf1-4cd3-bacb-5f9856f965de/scratchpad/proto/axnames.swift`.

1. A listen-only CGEventTap receives `System Events` synthetic keystrokes. Accessibility alone suffices (no Input Monitoring) for a CLI launched from a trusted terminal.
2. Backspace posted by keypipe is seen by keypipe's own tap; `eventSourceUserData` distinguishes it.
3. TextEdit body: `AXTextArea`, `AXValue` readable and settable; readback matches. CotEditor: same.
4. **iTerm2's prompt is `AXTextArea`** with `AXValue` = the entire pane (~3,800 chars), settable. `AXRole` cannot separate a terminal from an editor. `AXRoleDescription` was present on TextEdit/CotEditor and errored (-25212) on iTerm2 (a candidate discriminator, unverified).
5. **Synthetic Backspace is app-dependent.** CotEditor and an AppleScript dialog delete; TextEdit ignores Backspace, left-arrow and forward-delete (from CGEvent post, from `System Events`, and from espanso), while accepting character keys. Root cause unknown. So "erase by Backspace then read" needs a readback + `AXValue` rewrite fallback, and that is itself an app-specific behavior.
6. **"Nothing focused"**: with Finder frontmost and the desktop active, `AXFocusedUIElement` is not nil; it is an `AXGroup` with `AXFocused=1`. "No text focus" must be derived from role/attributes, not from nil.
7. **IME composing is observable.** TextEdit's text area exposes `AXTextInputMarkedRange`; while ATOK composes `にほｎご` it is `{location:0,length:4}` and `AXValue` already contains the marked text; after Escape it is `{0,0}`. Typing under ATOK turns `hello@@@` into `へっぉ＠`, so a trigger typed mid-composition reaches the tap as romaji keystrokes while the field holds kana.
8. espanso (user's) has a `@@` trigger; typing `@@@` makes espanso post 2 Backspaces + space. Two tools share the keystroke stream.
9. Terminal needs Automation grants (TextEdit, System Events) besides Accessibility; the first osascript blocks ~60 s on the dialog.
10. A webhook is just `curl` inside `output.shell` or `transform`; nothing was measured because nothing is uncertain there. The open question is whether "webhook" deserves a builtin or stays shell.

## Constraints the design keeps

- Trigger max 64 chars, longest match wins, no fallback to a shorter trigger when the longest trigger's rules all fail `when`.
- Config is the only place behavior is declared. No plugin code, no hot reload, no TOML/YAML.
- `Desktop` is the only boundary that touches AX/CGEvent. Config JSON is validated in one place with reason-specific errors (`invalid config: empty trigger`, `unknown key action`, `unknown output replaceAll`, `empty output.shell`, `empty transform`, `unknown focus window`).
- Transcript lines `keypipe matched/nomatch/erase/transform exit/apply/output-shell exit/field` are the verification contract; a design may add lines, not remove them.
- Lazy: no abstraction with one implementation, no registry for a value that never changes, deletion over addition.

## Questions each candidate must answer in its rationale

- What is the snapshot type, and which focus states does it distinguish? Justify each state by a measured fact and by a rule the user would actually write.
- Where does app-specific behavior (fact 5, fact 4) live, and how does a contributor add the next quirk without touching rule selection?
- Is "webhook" a builtin sink, a shell idiom, or something else? Why?
- What happens when the trigger fires mid-composition (fact 7)? Fire, ignore, or defer?
- What is the smallest change from the current design that reaches this shape? List files.
