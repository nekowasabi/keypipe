# Windows port, slice 1: Keypipe.Core + fake desktop (no hooks)

This slice ports the fire procedure into C# (`src/Keypipe.Core`, net8.0) and
reproduces V1–V12 from `verify-keypipe-fire-path` on a fake desktop
(`tests/Keypipe.Core.Tests`). It is covered by
`.claude/skills/verify-keypipe-windows-core/` (run `verify.sh`; green means the
slice holds). The TLA specs under `verify-keypipe-fire-path` stay authoritative
for the model and must remain green if invoked, but C# green does not require TLC.

## What is in this slice

- Fire order, exactly as on Mac: trigger feed, terminal filter, IME composing
  gate, secure gate, deny, candidate rules, front re-check after a slow read,
  erase/read (`runAfterBusy`), background decision, transform, apply.
- `IDesktop` / shell-runner interfaces with fake implementations in tests.
  No hooks, no UIA, no `SendInput`, no live Notepad.
- JSON config keys aligned with Mac (`trigger`, `hotkey`, `when`, `deny`,
  `transform`, `output`, `onFail`, `name`, `label`, `icon`, `shellTimeout`,
  `backgroundTimeout`, `hud`); `when.app` values and `/bin/sh` commands are Mac
  values and are NOT promised to run unmodified on Windows.
- `FireResult` kinds and the `--report` v1 JSON shape, checked against a copy
  of the golden `report-v1.jsonl`.

## What is deferred

- `Keypipe.Windows` (low-level hook, UIA, `SendInput`, process names, toast, HUD).
- IME detection against real apps (IMM/TSF measurement).
- Terminal class table, URL fact reader, background Job Object, PSReadLine bridge.
- Live verification on a real machine (Mac/Windows live runs stay unverified).
- Formal follow-up (`maintain-formal-verification` slice); TLA files untouched.
