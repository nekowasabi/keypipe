# Trigger matching (longest suffix + reset)

## Sub-features

- `TriggerMatcher.feed` returns the fired trigger string or nothing; rule selection is the
  engine's candidate loop, not the matcher.
- Same keystroke completing two suffixes fires the longest. With `@@`+`@@@` configured, the
  2nd char fires `@@` and the buffer clears, so `@@@` never accumulates (V11).
- The firing keystroke clears the buffer (`ResetOnFire`); the next character starts fresh.
- Buffer keeps at most the last 64 keystrokes (`triggerMaxBuffer`); hotkeys reset without a
  text fire; unconfigured chords touch the desktop not at all (V7/V11).

## How to get to it (user POV)

A rule author configures `trigger: "@@@"` (or a hotkey chord with at least one modifier).
Typing the trigger fires the first `when`-satisfied rule in config order; no satisfied rule
means no erase and no shell, and no shorter-trigger substitution (V6).

## Driving it with `dotnet test`

```sh
export PATH="$HOME/.dotnet:$PATH"
dotnet test Keypipe.sln --filter "FullyQualifiedName~LongestMatchWins|FullyQualifiedName~NoMatchDoesNotErase"
```

## Gotchas

- Config order breaks ties on identical trigger strings; length wins across different strings
  completing on the same keystroke. Order the matcher tests over both config orders.
- `+` is typed as `ctrl++`; shift is a character, not a modifier (`ctrl+A` ≠ `ctrl+a`); `cmd`
  maps to the Windows key on this platform without a schema change (analysis §3).
- Hotkey chords need at least one modifier; a bare key is a trigger, not a hotkey.
