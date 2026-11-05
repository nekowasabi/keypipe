# Fake desktop (the port of `FakeDesktop`)

## Sub-features

- Implements the Core `IDesktop` interface in-process: key appends, backspace removes,
  `text`/`setText` round-trip, `notify` log, busy/fired event order, fact reads log.
- Focus lattice: `nothing`, `text`, `composing`, `terminal`, plus `secure` flag.
- Timing modes: `ignoresBackspace`, `backspacePerRead` (one queued Backspace per read),
  `keysPerRead`, `ignoresWrite`, `writePerRead` (write lands on a later read),
  `fieldGoneAfter: erase` (window closed mid-fire).
- Live facts: `facts` map, `unreadableFacts` with reason, `appAfterSlowRead` (front switch
  during a slow fact read). JSON context keys mirror the Swift `--context` fixture so the
  same scenarios port 1:1.

## How to get to it (user POV)

There is no user-visible surface: the fake desktop is the test double behind every V1–V12
test. A scenario is a context (focus + field text + flags + facts) plus a keystroke or
hotkey feed, ending in a `FireResult` and desktop assertions (field text, backspace count,
notifications, shell invocations).

## Driving it with `dotnet test`

```sh
export PATH="$HOME/.dotnet:$PATH"
dotnet test Keypipe.sln --filter "FullyQualifiedName~TerminalTextTriggerStops|FullyQualifiedName~FrontChangeDuringSlowRead|FullyQualifiedName~EraseWaitsForEveryBackspace"
```

V3 asserts a terminal text trigger touches nothing (but a field-less hotkey still passes); V5
asserts a front switch mid-slow-read erases nothing; V12 asserts both erase timing modes yield
the body within 5 reads of a 3-char trigger.

## Gotchas

- `composing` requires a text field (`focusIsTextField`); composing with no field is rejected
  at fixture load, matching the Swift guard.
- Keystrokes append to the end of `fieldText`; Backspace removes from the end. `typeText`
  succeeds only with a caret (text field or terminal), never in a secure field or with nothing
  focused — and never reports success on the supplied path (V10).
- The fake desktop models Chromium/Electron timing (`ignoresWrite`, `writePerRead`), not real
  AX/UIA. A third app that delivers only one Backspace before the deadline is out of scope
  (same bound as the Mac `HandsBody` model).
