// keypipe/Sources/keypipe/Report.swift (new; PR1) + main.swift changes.
//
// --line keeps its contract byte for byte: stdout = the new line, exit 0 hit / 2 miss / 1 config.
// It becomes a projection of FireResult: exit(result.isHit ? 0 : 2); stdout = desktop.line ?? input.
//
// New (M1): `keypipe --line <trigger> --report [--app <bundle id>]`
//   stdin = the text, stdout = exactly one JSON line, exit 0 whenever a report was written,
//   exit 1 for a bad config / usage (stderr only). The transcript stays on stderr.
//
//   {"v":1,"outcome":"replaced","text":"..."}                      replaceInput wrote the virtual line
//   {"v":1,"outcome":"delivered"}                                   none / notify / shell / typeText succeeded
//   {"v":1,"outcome":"started"}                                     background job spawned (spawn verified)
//   {"v":1,"outcome":"failed","stage":"transform","failure":"exit 1"}
//   {"v":1,"outcome":"failed","stage":"output","failure":"unsupported"}   e.g. typeText via --line
//   {"v":1,"outcome":"nomatch"}
//   {"v":1,"outcome":"blocked","reason":"deny"}
//   {"v":1,"outcome":"unreadable","fact":"url","reason":"..."}       (PR2)
//   {"v":1,"outcome":"noinput"}
//   viaFallback adds "fallback":true to replaced/delivered.
//
// Decision (golden lines): Tests/keypipeTests/Fixtures/report-v1.jsonl holds one line per outcome.
// ReportTests asserts keypipe renders exactly those lines; voice-switch keeps a copy of the same
// file and its test decodes every line. The copy is synced by hand; a drift fails one side's test.
// "v" changes only on a breaking change; additions keep v=1.

import Foundation

extension FireResult {
    /// The only place the report schema is written down on the keypipe side.
    var reportJSON: String { fatalError("not implemented") }
}

// main.swift, --line branch (sketch):
//   let result = engine.fire(.text(trigger))
//   if args.contains("--report") { write(result.reportJSON + "\n"); exit(0) }
//   guard result.isHit else { exit(2) }
//   write(desktop.line ?? input); exit(0)
// --smoke-feed: unchanged; Engine.hits is now incremented from FireResult.isHit inside fire.
