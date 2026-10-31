# context-stub

## Sub-features

Each rule accepts an optional `context` (`appBundleId`, `processName`, all
nullable). MVP matcher ignores context and always returns true.

## How to get to it (user POV)

Add a `context` block to a rule. Behavior is unchanged in MVP; the fields
exist so a real per-app matcher slots in later.

## Driving it with verify.sh

V4a-V4b: type/field/matcher grep in `Sources/`, context reference in
`Tests/`.

## Gotchas

A test that asserts real per-app filtering would fail honestly in MVP. The
stub must be tested as always-true, not as matching.
