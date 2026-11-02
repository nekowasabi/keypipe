// voice-switch side of M1 (PR1). Spread over three existing files + one new.
//
// ---- Config.swift ----
//   top level:  "keypipe": {"binary": "/usr/local/bin/keypipe", "config": "~/.config/keypipe/config.json"}
//               (the app's launchd PATH does not find keypipe; read once, each action names only a trigger)
//   action:     {"name": "敬語", "wakeWords": ["けいご"], "keypipe": "@@@keigo", "superwhisperMode": "voice_switch"}
//   Decision (double paste): `superwhisperMode` is REQUIRED on a keypipe action and must name a mode
//   with auto-paste off, checked at config load ("keypipe action needs superwhisperMode"). Otherwise
//   Superwhisper pastes the original and voice-switch pastes the result on top (MacApp.swift:289-291).
//   Decision (M3): a keypipe action still needs a body; wake word alone keeps cancelling (later, with M2).

struct WakeActionDeliverySketch {
    enum Delivery: Equatable {
        case open(ActionURL), post(ActionURL), command(String)
        case keypipe(trigger: String)          // new; exclusive with url / command / tokenEnv / fields / inputParam
    }
}

// ---- Platform.swift ----
extension Platform {
    /// argv without a shell; stdin written then closed; returns status and stdout.
    /// Outer deadline (keypipe has its own shellTimeout).
    static func runCapturing(_ argv: [String], stdin: String, timeout: TimeInterval) async -> (status: Int32, stdout: Data)? {
        fatalError("not implemented")
    }
}

// ---- KeypipeReply.swift (new) ----
/// Mirror of keypipe's report v1. Cross-repo copy on purpose; both repos' tests decode the same
/// golden file (Tests/Fixtures/keypipe-report-v1.jsonl), so drift fails a test.
enum KeypipeOutcome: Equatable, Decodable {
    case replaced(String), delivered, started
    case failed(stage: String, failure: String)
    case noMatch, blocked(String), unreadable(fact: String, reason: String), noInput
    /// v != 1 or unknown outcome -> decoding error -> treated as failed("report", ...); nothing is pasted.
    init(from decoder: Decoder) throws { fatalError("not implemented") }
}

// ---- MacApp.swift: the new branch next to `.command` (MacApp.swift:538) ----
///   replaced(text) -> if the Superwhisper mode switch succeeded: pasteDictation(text, target)
///                     (front-app restore, clipboard save/restore, secure-field exclusion are already there).
///                     Decision (paste failure): when pasteDictation returns false, or the mode switch
///                     failed, put `text` on the clipboard and notify "貼れなかったので clipboard に入れました".
///   delivered / started -> log "dictation delivered: keypipe <name>"
///   failed / unreadable report / non-zero exit -> log + HUD error; paste nothing, never the original text
///   noMatch / blocked / unreadable / noInput -> log "keypipe <outcome>"; paste nothing
func deliverViaKeypipe(_ trigger: String, text: String, target: NSRunningApplication?) async -> KeypipeOutcome {
    fatalError("not implemented")
    // TODO: argv = [cfg.keypipe.binary, "--config", cfg.keypipe.config, "--line", trigger, "--report"]
    //               + (target?.bundleIdentifier.map { ["--app", $0] } ?? [])
    //       env VOICE_SWITCH_APP kept for shells inside keypipe rules.
    //       Decision (voice + url): keypipe's --line path reads no live facts, so `when.url` rules do
    //       not match from voice; the target app is restored only after keypipe returns, which is why.
}
