# Candidate 2. Typed focus, app traits as Desktop data, sink scoped by focus

The user's goal. keypipe is a macOS daemon. Typing a trigger such as `@@@` in a text field sends that field's text through a configured transform to a configured sink, all declared in one JSON config. The question is whether the context model (frontmost app, focus state, app quirks) and the execution model (shell, webhook, app-specific processing) are valid and feasible against what was measured on macOS 26.6.

Short verdict. The axes are right. The current encoding is not. A `focusIsTextField` boolean is falsified by fact 4 (iTerm2 is a settable `AXTextArea`) and blind to fact 7 (composition). The generic "Backspace, read back, rewrite" step hides a TextEdit quirk inside the fire sequence and depends on event timing. This candidate replaces the boolean with a four-state `Focus` enum classified from AX facts plus a per-app traits table owned by the Desktop layer, puts the sink inside the focus scope so `replaceInput` outside a text field cannot be parsed, and adds `webhook` as a typed sink.

## 1. Usage (caller's view)

### README excerpt

A rule is a trigger, a `when`, an optional `transform`, and an `output`.

- `when.app` is a list of bundle ids. Omitted means any app.
- `when.focus` is one of these.
  - `textField`. A normal editable text element. Input is the element's text with the trigger removed. Only these rules may use `replaceInput` or `insert`.
  - `terminal`. A terminal app (iTerm2, Terminal). Input is the line you typed since the last Return, with the trigger removed. keypipe never reads the pane.
  - `any` (default). Any of the above, or nothing useful focused. Input is the field text, the typed line, or empty.
- Nothing fires while an input method is composing (for example ATOK showing underlined kana). Switch to ABC or commit first.
- `transform` is a shell command. Input arrives on stdin, `$1` and `KEYPIPE_INPUT`. stdout, minus one trailing newline, is the result.
- `output` is one of these.
  - `"replaceInput"` or `"insert"`. Writes back into the same field the trigger was typed in, even if focus moved while the transform ran. Requires `focus: textField`.
  - `"clipboard"`, `"notify"`, `"none"`.
  - `{ "shell": "..." }`. Result on stdin, `$1`, `KEYPIPE_INPUT`. App in `KEYPIPE_APP`.
  - `{ "webhook": "https://..." }`. POSTs `{"text": <result>, "app": <bundle id or null>, "trigger": <trigger>}` as JSON. Put the token in the URL. For auth headers use `{ "shell": "curl ..." }`.

App quirks are not configuration. You never write "TextEdit ignores Backspace" in a rule. keypipe knows that.

### Case A. Translate in place in TextEdit

```json
{
  "rules": [
    {
      "trigger": "@@@",
      "when": { "app": ["com.apple.TextEdit"], "focus": "textField" },
      "transform": "claude -p 'Translate to English. Output only the translation.'",
      "output": "replaceInput"
    }
  ]
}
```

The user types `こんにちは@@@` with the input source on ABC for the trigger. keypipe sees TextEdit, classifies the body as `.field` with `erase: .rewriteValue` (from the traits table), waits until the field ends with `@@@`, sets `AXValue` to `こんにちは`, runs `claude -p`, and writes `Hello` into that same element.

Transcript.

```
keypipe matched @@@ rule 0
keypipe erase 3
keypipe transform exit 0
keypipe apply replaceInput "Hello"
```

### Case B. Send to tmux from iTerm2

```json
{
  "rules": [
    {
      "trigger": ";;;",
      "when": { "app": ["com.googlecode.iterm2"], "focus": "terminal" },
      "output": {
        "shell": "tmux send-keys -t work:claude -l -- \"$1\" && tmux send-keys -t work:claude Enter"
      }
    }
  ]
}
```

The user types `fix the flaky test;;;` at a shell prompt. keypipe classifies iTerm2's `AXTextArea` as `.terminal` (traits table), posts 3 Backspaces (inferred to work; iTerm2 was not probed for synthetic Backspace), and passes `fix the flaky test` (the typed line, not the 3,800-char pane) to the shell. If the user pressed an arrow key, pasted, or clicked since the last Return, the line is unknown and keypipe prints `keypipe skip ;;; line-unknown` instead of sending a guess.

The same rule with `"focus": "textField"` is legal but never matches in iTerm2, because iTerm2 is never `.field`. That is the fix for fact 4.

### Case C. Webhook from any app

```json
{
  "rules": [
    {
      "trigger": "@@w",
      "output": { "webhook": "https://hooks.example.com/keypipe/T0K3N" }
    }
  ]
}
```

`focus` defaults to `any`. In TextEdit the field text is posted and the trigger erased from the field. In iTerm2 the typed line is posted. In Finder with nothing useful focused the body is `{"text":"","app":"com.apple.finder","trigger":"@@w"}` and nothing is erased.

Transcript adds one line.

```
keypipe matched @@w rule 0
keypipe webhook status 200
```

### Rejected at load

```
{"trigger":"@@@","output":"replaceInput"}
invalid config: output replaceInput requires focus textField
```

### Call sites in keypipe's own code

```swift
// main.swift, live mode
var engine = Engine(config: config, desktop: MacDesktop(), runner: .live, log: transcript)
MacKeyTap.start { key in engine.key(key) }   // own posted events already filtered out

// main.swift, --smoke-feed with --context
let desktop = FakeDesktop(context: try FakeContext.load(path))
var engine = Engine(config: config, desktop: desktop, runner: .live, log: transcript)
for c in feed { engine.key(.char(c)) }
transcript("keypipe field \(json(desktop.text))")

// Tests, pure selection with no desktop at all
let d = decide(rules, trigger: Trigger("@@@")!, snapshot: Snapshot(app: iterm, focus: .terminal), line: .known("ls"))
XCTAssertEqual(d, .nomatch)   // textField rules never match a terminal
```

`--context` JSON keeps its keys and gains one optional key: `{"app":"com.googlecode.iterm2","focusIsTextField":true,"fieldText":"...","composing":false}`. `FakeDesktop` runs the same `classify` as `MacDesktop`, so the iTerm2 context above yields `.terminal`. There is no second way to say "text field".

`--probe` gains one key: `{"trusted":true,"app":"...","focusIsTextField":true,"focus":"terminal","fieldText":...}`. The `focus` value is one of `textField`, `terminal`, `composing`, `none`. That string comes from one `Focus.name` mapping, and `when.focus` parsing reads the same mapping (plus `any`), so the Swift case names, the config vocabulary and the probe output cannot drift apart.

## 2. Type sketch and signatures

```swift
// Config.swift. The only parse boundary for JSON. Everything below is valid by construction.

/// 1...64 characters. Parsed once in loadConfig.
struct Trigger: Hashable { let text: String; init?(_ s: String) { notImplemented() } }
struct BundleID: Hashable { let raw: String }
/// Non-empty /bin/sh script.
struct ShellCommand: Equatable { let script: String }
/// http or https only. Token lives in the URL; no headers in v1.
struct WebhookURL: Equatable { let url: URL }

/// Sinks that never touch the originating field.
enum Sink: Equatable {
    case none, clipboard, notify
    case shell(ShellCommand)
    case webhook(WebhookURL)
}

/// Sinks that write back into the field the trigger came from.
enum FieldSink: String, Equatable { case replaceInput, insert }

enum FieldOutput: Equatable { case field(FieldSink), elsewhere(Sink) }

/// The sink lives inside the scope, so "replaceInput under focus any" has no value.
enum Scope: Equatable {
    case textField(FieldOutput)
    case terminal(Sink)
    case any(Sink)
}

struct Rule: Equatable {
    let trigger: Trigger
    let apps: Set<BundleID>?        // nil = any app
    let scope: Scope
    let transform: ShellCommand?    // nil = identity
}

struct KeypipeConfig: Equatable { let rules: [Rule] }

/// Reasons kept verbatim: empty trigger, unknown key <k>, unknown output <v>,
/// empty output.shell, empty transform, unknown focus <v>.
/// New: output <sink> requires focus textField, invalid webhook <v>.
func loadConfig(path: String) throws -> KeypipeConfig { notImplemented() }
```

```swift
// Focus.swift. Desktop-owned domain knowledge. Pure; compiles on Linux.

enum EraseMethod: Equatable {
    case backspace      // post N Backspaces, wait until the value shrinks
    case rewriteValue   // set AXValue to value minus trigger (TextEdit, fact 5)
}

/// Opaque handle to the element captured at snapshot time.
/// MacDesktop maps token -> retained AXUIElement. Writes go here, not to "current focus".
struct Field: Equatable { let token: Int; let erase: EraseMethod }

enum Focus: Equatable {
    case none           // fact 6: focused element exists but is not editable text
    case composing      // fact 7: AXTextInputMarkedRange.length > 0
    case field(Field)   // fact 3: editable text whose AXValue is the user's text
    case terminal       // fact 4: AXValue is the pane; input comes from the key stream
}

extension Focus {
    /// The single user-facing vocabulary. --probe prints it; Config parses `when.focus` against it plus "any".
    var name: String { notImplemented() }   // "none" | "composing" | "textField" | "terminal"
}

struct Snapshot: Equatable { let app: BundleID?; let focus: Focus }

/// Raw AX facts, parsed once in MacDesktop (or from --context in FakeDesktop).
struct AXFacts: Equatable {
    let isEditableText: Bool   // role in {AXTextField, AXTextArea, AXComboBox, AXSearchField} and AXValue settable
    let markedLength: Int      // AXTextInputMarkedRange.length, 0 if absent
}

enum Surface: Equatable { case editor, terminal }

struct AppTraits: Equatable {
    var surface: Surface = .editor
    var erase: EraseMethod = .backspace
}

/// The one list of app quirks. Adding the next quirk is one row here.
let appTraits: [BundleID: AppTraits] = [
    BundleID(raw: "com.apple.TextEdit"): AppTraits(erase: .rewriteValue),       // measured, fact 5
    BundleID(raw: "com.googlecode.iterm2"): AppTraits(surface: .terminal),      // measured, fact 4
    BundleID(raw: "com.apple.Terminal"): AppTraits(surface: .terminal),         // guess, unprobed
]

/// Precedence: composing beats everything (the field holds uncommitted text),
/// then non-text is .none, then the app's surface decides field vs terminal.
func classify(_ ax: AXFacts, app: BundleID?, token: Int) -> Focus { notImplemented() }
```

```swift
// Desktop.swift. The port. Two implementations: MacDesktop, FakeDesktop.

enum DesktopSink: Equatable { case clipboard, notify }

protocol Desktop {
    func snapshot() -> Snapshot
    /// .field only. Waits (bounded, ~200 ms) until the value ends with the trigger,
    /// removes it with field.erase, waits until the removal is visible, returns the rest.
    /// nil on deadline. Hides fact 5 and the tap-before-insert ordering from Engine.
    func consumeTrigger(_ t: Trigger, from field: Field) -> String?
    /// .terminal only. Posts Backspaces tagged with keypipe's eventSourceUserData. No readback.
    func backspace(_ count: Int)
    func write(_ sink: FieldSink, _ text: String, to field: Field)
    func deliver(_ sink: DesktopSink, _ text: String)
}

struct FakeContext: Decodable { let app: String?; let focusIsTextField: Bool; let fieldText: String; let composing: Bool? }
final class FakeDesktop: Desktop {
    init(context: FakeContext) { notImplemented() }
    var text: String { notImplemented() }       // printed as `keypipe field`
    // snapshot() calls classify(AXFacts(isEditableText: focusIsTextField, markedLength: composing ? 1 : 0), ...)
}
```

```swift
// Engine.swift. The fire sequence and the only owner of key-stream state.

enum Key: Equatable { case char(Character), backspace, newline, other }   // other: arrows, modifiers+key, mouse down

/// What the user typed on the current terminal line. Unknown once editing left the visible stream.
enum TypedLine: Equatable { case known(String), unknown }

enum SkipReason: String { case composing, lineUnknown = "line-unknown" }

enum Decision: Equatable { case fire(ruleIndex: Int), nomatch, skip(SkipReason) }

/// Pure. Composing skips before any rule is consulted. First rule in config order whose
/// apps and scope accept the snapshot wins. No fallback to shorter triggers.
/// A terminal-accepting rule with line .unknown yields .skip(.lineUnknown).
func decide(_ rules: [Rule], trigger: Trigger, snapshot: Snapshot, line: TypedLine) -> Decision { notImplemented() }

struct Runner {
    let shell: (ShellCommand, _ input: String, _ env: [String: String]) -> (status: Int32, stdout: String)
    let webhook: (WebhookURL, _ body: Data) -> Int?          // HTTP status, nil on transport error
    static let live: Runner = notImplemented()
}

struct Engine {
    init(config: KeypipeConfig, desktop: Desktop, runner: Runner, log: @escaping (String) -> Void) { notImplemented() }
    /// .char feeds the matcher and the line. .backspace/.other reset the matcher (a trigger
    /// cannot straddle an edit, fact 8). .newline resets both. On a match:
    /// snapshot, decide, then for .fire:
    ///   .field    -> consumeTrigger, input = returned text      (`keypipe erase N`)
    ///   .terminal -> backspace(N), input = line minus trigger   (`keypipe erase N`)
    ///   .none     -> no erase, input = ""
    /// transform, then sink. Runs the post-snapshot work on one serial queue.
    mutating func key(_ k: Key) { notImplemented() }
}
```

```swift
// Trigger.swift. Unchanged algorithm, narrower type.
struct TriggerMatcher {
    init(triggers: [Trigger], maxBuffer: Int = triggerMaxBuffer) { notImplemented() }
    mutating func feed(_ c: Character) -> Trigger? { notImplemented() }   // longest wins, ties by config order
    mutating func reset() { notImplemented() }
}
```

```swift
// Sinks.swift. Replaces Actions.swift.
func runShell(_ cmd: ShellCommand, input: String, env: [String: String]) -> (status: Int32, stdout: String) { notImplemented() }
/// POST application/json, 10 s timeout. Body built with JSONEncoder, never string interpolation.
func postWebhook(_ url: WebhookURL, body: Data) -> Int? { notImplemented() }
```

```swift
// MacKeyTap.swift
enum MacKeyTap {
    /// listen-only CGEventTap on keyDown + leftMouseDown. Drops events whose
    /// eventSourceUserData is keypipe's tag (fact 2). Maps the rest to Key.
    static func start(_ onKey: @escaping (Key) -> Void) { notImplemented() }
}
```

## 3. Module map (Sources/keypipe)

| File | Owns | Status vs current design |
| --- | --- | --- |
| `Config.swift` | Rule domain types and `loadConfig`, the only JSON boundary | `When`/`Output` become `Scope`/`FieldOutput`/`Sink`; two new reasons |
| `Focus.swift` | `Focus`, `Field`, `EraseMethod`, `Snapshot`, `AXFacts`, `AppTraits`, `appTraits`, `classify` | Replaces `Context.swift` |
| `Desktop.swift` | `Desktop` protocol, `DesktopSink`, `FakeDesktop`, `FakeContext` | `erase`+`fieldText` become `consumeTrigger`+`backspace`; `apply` splits into `write(to:)` and `deliver` |
| `MacDesktop.swift` | AX reads into `AXFacts`, element token table, settle polling, CGEvent Backspace, pasteboard, notification | New, as planned |
| `MacKeyTap.swift` | CGEventTap to `Key`, self-event filter | New, as planned |
| `Engine.swift` | `Key`, `TypedLine`, `Decision`, `decide`, `Runner`, `Engine` | New, as planned, plus `decide` and the line |
| `Sinks.swift` | `runShell`, `postWebhook` | Replaces `Actions.swift` |
| `Trigger.swift` | `TriggerMatcher` over `[Trigger]` | `TriggerRule` deleted |
| `main.swift` | Wiring, `--context`, `--smoke-feed`, `--feed-stdin`, `--probe` | As planned |

Tracing a fire touches three files: `Engine.swift` (sequence), `Focus.swift` (what the state means), `Desktop.swift` (how the field is touched). `Config.swift` is read once at load.

## 4. Rationale

### Problem

keypipe picks a rule from the situation at the instant a trigger completes, removes the trigger, reads input, transforms it, and delivers it. The probes showed the situation has more states than the design names. A terminal looks exactly like an editor by role (fact 4, measured). A composing IME puts uncommitted text in the field while the tap sees ASCII (fact 7, measured). "Nothing focused" is a non-nil `AXGroup` (fact 6, measured). And how to remove the trigger depends on the app (fact 5, measured). Constraints carried in: trigger ≤ 64 and longest wins with no fallback, config is the only user-facing declaration, `Desktop` is the only AX/CGEvent boundary besides the tap, the transcript and reason strings are additive-only contracts.

### Shape

The data shape is two enums meeting in one pure function. `Focus` (four states) comes from the Desktop. `Scope` (three states, each carrying the sinks it allows) comes from config. `decide(rules, trigger, snapshot, line)` is the whole selection policy and is pure.

Per **model-the-domain**, the boolean `focusIsTextField` became `Focus`. Each case is justified by a measured fact and a rule a user writes.

| State | Measured fact | Rule the user writes |
| --- | --- | --- |
| `.field` | 3. TextEdit and CotEditor bodies are settable `AXTextArea` | Case A, translate in place |
| `.terminal` | 4. iTerm2 prompt is a settable `AXTextArea` holding the whole pane | Case B, send line to tmux |
| `.none` | 6. Finder desktop focus is `AXGroup` with `AXFocused=1` | Case C fires with empty text; textField rules stay silent (M3) |
| `.composing` | 7. `AXTextInputMarkedRange` length 4 while ATOK composes | Nobody writes it. It exists so no rule can fire into a composition |

Users write only `textField`, `terminal`, `any`. A writable `none` was rejected because no real rule wants "only when nothing is focused".

Per **type-system-discipline**, the sink sits inside the scope. `Scope.textField(FieldOutput)` is the only case that can hold `.field(.replaceInput)`, so a parsed rule cannot write a field it never read. `Trigger`, `ShellCommand`, `WebhookURL` are validated newtypes, so the Engine never re-checks emptiness or URL scheme. `Field` is an opaque token captured at snapshot time, so `write(to:)` cannot target whatever is focused after a slow `claude -p`. The current `apply(sink, text)` has no target, which is a latent bug (inferred, not reproduced).

Per **boundary-discipline**, AX attributes are parsed once into `AXFacts` in `MacDesktop`, and `classify` is a pure function shared by `MacDesktop` and `FakeDesktop`. The fake harness therefore exercises the real classification and the real traits table. JSON is parsed only in `loadConfig`.

Interface depth. `Desktop` keeps five methods, close to today's four. `consumeTrigger` is the deep one. It hides the quirk table's erase method, the wait for the final trigger character to land (the tap sees keyDown before the app inserts it, inferred), and the wait for the removal to become visible. Engine sees "give me the field text without the trigger, or nil".

What the design does not do. It does not read the terminal pane. It does not let config override app traits. It does not fire during composition. It does not retry a failed webhook.

### Answers to the grounding questions

**Snapshot type and focus states.** `Snapshot { app: BundleID?, focus: Focus }` with `Focus = none | composing | field(Field) | terminal`. Justified in the table above.

**Where app-specific behavior lives.** In `Focus.swift`, as the `appTraits` table, read only by `classify` and by `MacDesktop` through `Field.erase`. TextEdit's ignored Backspace (fact 5) is `erase: .rewriteValue`. iTerm2's whole-pane value (fact 4) is `surface: .terminal`. The next quirk is one row. If it needs a new behavior (say an Electron app that ignores `AXValue` writes, unverified), that is one new case on `AppTraits` handled inside `MacDesktop`. `decide` and `Scope` never change, because they only see `Focus`.

The current design's step 4 (Backspace, read back, rewrite if the trigger remains) is rejected on validity. It is a TextEdit quirk applied to every app, and it races. If CotEditor has not processed the posted Backspaces when AX is read, keypipe sees the trigger still there, rewrites the value, and then the late Backspaces delete three more user characters (inferred from CGEventPost being asynchronous, not reproduced). With a table, each app gets one deterministic method, and the backspace method waits for the value to shrink instead of guessing.

**Webhook.** A typed sink, `{ "webhook": url }`. The reason is correctness, not convenience. A webhook body is JSON, and building JSON from arbitrary field text in `sh` needs `jq`, which stock macOS lacks (guess about the user's machine; true of a fresh install). A builtin encodes with `JSONEncoder` and spawns no shell, which removes the R8 injection surface for this sink entirely. The ceiling is no custom headers. URL-embedded tokens cover Slack, Discord, n8n and Zapier style hooks. Anything needing `Authorization` stays `{ "shell": "curl ..." }`. App-specific sinks (tmux, `cot`, `agmsg`) stay shell. App-specific field I/O is Desktop data. These are two different axes, so there are no per-app sink builtins.

**Trigger mid-composition.** Ignore, with a line. `decide` returns `.skip(.composing)` before looking at rules and the Engine prints `keypipe skip <trigger> composing`. Firing would Backspace into kana that is not yet text, and read an `AXValue` that already contains marked text (fact 7, measured). Deferring to commit was rejected because after commit the trigger has become full-width `＠` in the field and never existed as typed (measured, `hello@@@` became `へっぉ＠`). Consequence for the user, stated in the README. ASCII triggers work only in ABC or direct-input mode.

**espanso and self-events (fact 8, fact 2).** `MacKeyTap` drops events carrying keypipe's `eventSourceUserData`. Every other non-character key (espanso's Backspaces included) resets the matcher. Typing `@@@` with espanso's `@@` active therefore yields no keypipe fire, which is the safe outcome (inferred from the measured event sequence of 2 Backspaces then a space).

### Validity and feasibility verdict

| Axis | Valid | Feasible | Basis |
| --- | --- | --- | --- |
| Frontmost app | Yes | Yes | Bundle id via `NSWorkspace`; probes read the front app's AX tree (measured for the tree, inferred for the API) |
| Focus: text field | Yes, as `.field` | Yes | Fact 3, measured read and write |
| Focus: nothing useful | Yes, as `.none` from role | Yes | Fact 6, measured |
| Focus: composing | Yes, required | Yes | Fact 7, measured |
| Focus: terminal | Required by fact 4 | Yes by bundle table; by AX unverified | `AXRoleDescription` error on iTerm2 is a candidate to replace the table |
| App-specific handling | Yes, required | Yes as data | Fact 5, measured |
| Shell transform and sink | Yes | Yes | R5, R6, R8 planned; fact 10 |
| Webhook | Yes | Yes | URLSession; nothing uncertain |
| Synchronous execution | Valid only off the tap thread | Yes | A multi-second transform on the tap's run loop stalls key delivery to keypipe (inferred) |

### Synthesis decision

Left for arena.

### Tradeoffs accepted

- We accept a hand-maintained bundle-id table in exchange for classification that works today without the unverified `AXRoleDescription` signal.
- We accept that an unknown app which ignores Backspace leaves the trigger in the input (visible, not destructive) in exchange for never running a racy generic rewrite. The visible symptom tells the user which row to add.
- We accept that terminal input is lost after arrows, paste, Tab completion or a mouse click (`line-unknown`) in exchange for never sending a guessed line.
- We accept no webhook headers in exchange for a sink with one field.
- We accept that IME users must type triggers in ABC mode in exchange for never corrupting a composition.
- `.none` erases nothing. This reverses a decided review default ("`focus: any` のルールでも打ったトリガーは Backspace で消す" in verification-plan.md, step 3 of context-rules.md). The reason is that nothing editable received the trigger, and Backspace into a non-text element is an unbounded side effect (in Finder it can act on the selection, guess). It changes verifier expectations. Any R item that asserts `keypipe erase` under `focusIsTextField: false` flips to asserting no erase, and the pending medium R2g item (fire in a non-text context, field stays `hello`) becomes the positive test of this rule. `.terminal` still erases.

### Alternatives considered

- **Keep the boolean and add `when.app` excludes for terminals.** Small public surface, but every user must know that terminals are text areas and list them in every textField rule. That leaks fact 4 into every config. Lost.
- **Generic erase with readback and rewrite (current design).** No table, but the quirk is hidden in the fire sequence and the race can delete user text. Lost on validity.
- **App traits in config** (`"apps": {"com.apple.TextEdit": {"erase": "rewrite"}}`). Lets users fix a new app without a rebuild, but exposes Desktop internals as public schema and gives two owners for one fact. Lost for now. It is the natural next step if the table churns.
- **Terminal rules carry no input.** Smallest, but Case B can then only fire a fixed command, which misses "send the field's text". Kept as the first cut if the typed line proves unreliable.
- **Webhook as shell idiom only.** Zero code, but correct JSON needs `jq` and the field text goes through `sh`. Lost.

### Open questions and risks

- Does `AXRoleDescription` (or another attribute) separate terminals across iTerm2, Terminal, Ghostty, WezTerm? If yes, should `classify` prefer it over the table?
- Is the tap really ahead of the app's insertion of the last trigger character? The settle wait covers both orders, but the deadline (~200 ms) is a guess.
- Does an `AXValue` write into an element that is no longer focused land in Electron or browser fields?
- Should the settle wait key on length growth since the snapshot rather than on suffix match? If the text already ends in trigger characters (`a@@@`, then the user types `@@@`), a suffix check passes before the last keystroke lands, the rewrite strips three, and the late `@` inserts afterwards.
- Does iTerm2 accept keypipe's synthetic Backspace? Fact 5 shows Backspace acceptance is per app, and iTerm2 was not probed. If it refuses, the terminal row needs a different erase method.
- Should a terminal rule also clear the typed line from the prompt (Ctrl-U), or only the trigger? This candidate erases only the trigger, matching M2 where the field keeps `abc`.
- Is the typed line worth its ceiling for the user's real tmux use, or does the user only fire fixed commands from iTerm2?
- Should `any` rules see `KEYPIPE_FOCUS=field|terminal|none`? Skipped until a shell needs to branch on it.

### Smallest change from the current design

Core (needed for validity).

- `Sources/keypipe/Context.swift` deleted, `Sources/keypipe/Focus.swift` added with `Focus`, `Field`, `AXFacts`, `appTraits`, `classify`.
- `Sources/keypipe/Config.swift`. `focus` accepts `terminal`. `When`+`Output` become `Scope`. New reason `output <sink> requires focus textField`.
- `Sources/keypipe/Desktop.swift`, `FakeDesktop` (optional `composing` key), `MacDesktop.swift`. `consumeTrigger(from: Field)`, `backspace`, `write(to:)`, `deliver`.
- `Sources/keypipe/Engine.swift`. `decide` with the composing skip, line `keypipe skip <trigger> composing`, serial fire queue.
- `Sources/keypipe/MacKeyTap.swift`. `Key` mapping and the self-event filter.
- `Sources/keypipe/Trigger.swift`. Matcher over `[Trigger]`, reset on non-char keys.
- `Sources/keypipe/main.swift`. Wiring, `--context` with optional `composing`, `--probe` `focus` key.
- `Tests/keypipeTests/` (all five files, schema change), plus a `classify` table test.
- `.claude/skills/verify-keypipe-rules/` (`SKILL.md`, `verify.sh`). New reason, new skip line, `composing` and terminal contexts, `--probe` `focus` key, no erase under `.none`.
- `.claude/skills/verify-keypipe-trigger/`. The matcher returns `Trigger?` and resets on non-character keys, and the `feedAndRun` loop moves into `Engine`.
- `.claude/skills/verify-keypipe/`. Old `action` schema.
- `config.example.json`, `README.md`, `README.ja.md`.
- `docs/design/context-rules.md`. Replace step 4, the "use focus any for terminals" workaround, and the "focus any still erases" default.

Increments (cut either without touching the core).

- Terminal typed line. `TypedLine` in `Engine.swift`, `line-unknown` skip, mouse-down in the tap mask.
- Webhook sink. `WebhookURL`, `Sink.webhook`, `postWebhook` in `Sources/keypipe/Sinks.swift` (which replaces `Actions.swift` either way), reason `invalid webhook <v>`, line `keypipe webhook status <code>`.

### Next implementation step

Write `Focus.swift` with `classify` and the traits table, plus a test table that feeds the four measured AX situations (TextEdit body, iTerm2 prompt, Finder `AXGroup`, ATOK composing) and asserts the four `Focus` cases.
