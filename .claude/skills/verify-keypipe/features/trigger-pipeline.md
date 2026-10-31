# trigger-pipeline

## Sub-features

Pure `TriggerMatcher`: feed characters, detect when `@@@` completes, select
the action. No Accessibility API on Linux. Hook point for a future macOS
CGEvent tap is documented.

## How to get to it (user POV)

Feed keystrokes (later via the macOS tap, now via unit tests). On `@@@` the
mapped action fires.

## Driving it with verify.sh

V5a-V5c: matcher module with `feed`, unit test asserting `@@@` detection,
hook doc grep (`CGEvent`/tap in README or sources).

## Gotchas

Real key capture needs macOS and is out of scope for this PR. Linux runs prove
the pure matcher only, marked MAC_UNVERIFIED for the tap.
