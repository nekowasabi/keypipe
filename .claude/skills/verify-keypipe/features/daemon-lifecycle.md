# daemon-lifecycle

## Sub-features

Background process with no menu bar UI. Prints `keypipe started` on launch.
Stays alive until SIGINT/SIGTERM.

## How to get to it (user POV)

Build and run `keypipe` from a terminal. Expect the start line, then stop it
with Ctrl-C or `kill -TERM`.

## Driving it with verify.sh

V2a-V2f: entrypoint presence, no-menu-bar grep, signal grep, start-line grep,
`swift build`, then launch `.build/debug/keypipe`, assert the start line and
liveness, SIGTERM it. Transcript lands in the evidence dir.

## Gotchas

No swift toolchain on this Linux box means V2e/V2f SKIP as MAC_UNVERIFIED.
Never kill by process name; verify.sh kills only the PID it started.
