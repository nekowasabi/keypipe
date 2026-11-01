// keypipe/Sources/keypipe/Engine.swift (changed in PR1, PR2, PR3; untouched by adding a fact or a sink afterwards)
//
// Decision C (2026-11-01): the fire keeps today's shape. Only three seams change:
//   PR1  fire/run return FireResult; background spawn reports its own failure.
//   PR2  gates gain `secure` and relax `terminal`; rule selection goes through Conditions + FactSheet.
//   PR3  apply() calls Sink.perform instead of switching on BuiltinSink.
// performErase, waitForTrigger, performWrite and the (trigger x focus) 4-way input switch
// are NOT touched. They keep polling desktop.text(_:) as today.

import Foundation

/// What one fire did. Single source for --line's exit code, --smoke-feed's hits,
/// --report's JSON and the voice-switch decision.
enum FireResult: Equatable {
    /// A gate stopped the fire before any rule was looked at: terminal | composing | secure | deny.
    case blocked(String)
    case noMatch
    /// A condition fact could not be read (Automation denied, timeout). Decision ア: the fire stops
    /// here and notifies; it does not fall through to the next rule of the same trigger.
    case unreadable(fact: FactName, reason: String)
    /// Matched but nothing to read (field gone). Counts as a hit, as today (main.swift:92-94).
    case noInput(rule: Int)
    case replaced(rule: Int, text: String, viaFallback: Bool)
    case delivered(rule: Int, viaFallback: Bool)
    /// Detached job spawned. Only when the spawn succeeded (see `background`).
    case started(rule: Int)
    case failed(rule: Int, stage: Stage, Failure)
    enum Stage: String { case transform, output, spawn }
    var isHit: Bool { fatalError("not implemented") }   // !blocked && !noMatch && !unreadable
}

struct Engine {
    // stored properties as today, except:
    /// Returns whether the detached job started. Today's (Job) -> Void hid a failed spawn
    /// behind "started"; a false here becomes .failed(stage: .spawn).
    private let background: (Job) -> Bool
    private(set) var hits = 0   // derived from FireResult.isHit inside fire

    mutating func fire(_ trigger: Trigger) -> FireResult {
        fatalError("not implemented")
        // TODO (order is today's, with the PR2 additions marked):
        // let snapshot = desktop.snapshot()
        // gates, before any rule and before any read of the field:
        //   .composing                      -> emit "keypipe composing <t>"; .blocked("composing")   (today)
        //   .terminal                       -> (M18) stop only the candidates with focus textField;
        //                                      emit "keypipe terminal <t>" when none is left (today's line)
        //   snapshot.secure                 -> (M7)  emit "keypipe secure <t>"; .blocked("secure")
        //   config.deny (Conditions)        -> (M6)  .match -> .blocked("deny"); .unreadable -> .blocked("deny")  (fail safe)
        // let sheet = FactSheet(desktop, snapshot)
        // select: first rule with this trigger, in config order, whose when.evaluate(sheet) is .match;
        //   an .unreadable verdict ends the fire: notify("<t>: cannot read <fact>: <reason>"), return .unreadable
        //   (do not try the next rule). Same trigger, two url rules -> one osascript (memo).
        // guard against decision-ア problem A: re-take snapshot.app right before erasing; if the front
        //   app changed while a slow fact was read, emit "keypipe front-changed <t>" and return .noMatch
        //   without sending Backspace (verify on a real machine whether this window is hit in practice).
        // erase + input: today's 4-way switch, unchanged (performErase polling intact)
        // env = sheet.environment()   // KEYPIPE_APP only in PR2
        // background: emit "keypipe background rule i"; background(job) ? .started : .failed(.spawn)
        // run(rule, input, env, field) -> FireResult
    }

    /// Detached half, unchanged except for the return value. The child indexes the config
    /// bytes carried in JobRequest (see Job.swift note), never the file on disk.
    func run(_ job: Job) -> FireResult { fatalError("not implemented") }

    /// transform -> output -> onFail.output as today. apply is generic over Sink.perform (PR3);
    /// shell outputs go through shellStage as today. No per-sink switch here.
    private func run(_ rule: Rule, _ input: String, _ env: [String: String], _ field: Field?) -> FireResult {
        fatalError("not implemented")
    }
}

/// Job.swift: JobRequest carries `config` (the path, for the jobs.log line "job rule N from <path>",
/// unchanged) AND `configBytes` (what the parent loaded; the daemon keeps them from startup, --line
/// re-reads them). The child decodes configBytes and never re-opens the file, so `rule` always indexes
/// the rules the parent matched. Bytes are never logged. Rejected: a digest check (refuses every
/// background fire after any edit until the daemon restarts, since there is no hot reload).
struct Job: Codable, Equatable {
    var rule: Int
    var input: String
    var environment: [String: String]
}
