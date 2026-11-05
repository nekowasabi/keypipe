# Feature map: Windows core fake-desktop fire path (slice 1)

Slice 1 ports the fire procedure into C# `Keypipe.Core` and reproduces V1–V12 on a fake
desktop. No hooks, UIA, `SendInput`, or live Notepad. Each file answers, from the caller's
point of view: what the capability is, how to reach it, how to drive it, and what proves it.

- [fire-order.md](fire-order.md) — the 11-step fire order and the V1–V12 gate checklist.
- [fake-desktop.md](fake-desktop.md) — fake-desktop capabilities (the port of `FakeDesktop`).
- [erase-transform-apply.md](erase-transform-apply.md) — erase readback, transform/`onFail`, apply.
- [trigger-matching.md](trigger-matching.md) — longest-suffix match and buffer reset.
- [check-docs.md](check-docs.md) — the CI docs gate (`scripts/check-doc-symbols.sh`).

Out of scope for this slice (do not gate here): hooks/LL keyboard, UIA read/write, IME
measurement, terminal-class table, URL facts, HUD rendering, background Job Object, `herdr`,
zsh/PSReadLine bridge, clipboard. MAC/Windows live stays unverified until those land.
