// Throwaway. Listen-only CGEventTap for N seconds; prints every keyDown it
// sees. With --backspace K, posts K Backspace key events after 1s to show
// posting works and whether the tap sees its own posted events.
import ApplicationServices
import AppKit

let secs = Double(CommandLine.arguments.dropFirst().first ?? "6") ?? 6
print("trusted=\(AXIsProcessTrusted()) listening \(secs)s")
var seen = 0
let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
let cb: CGEventTapCallBack = { _, type, ev, _ in
    if type == .keyDown {
        var len = 0
        var buf = [UniChar](repeating: 0, count: 4)
        ev.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        let s = String(utf16CodeUnits: buf, count: len)
        let src = ev.getIntegerValueField(.eventSourceUserData)
        seen += 1
        print("keyDown code=\(ev.getIntegerValueField(.keyboardEventKeycode)) str=\(s.debugDescription) userData=\(src)")
        fflush(stdout)
    } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        print("tap disabled type=\(type.rawValue)")
    }
    return Unmanaged.passUnretained(ev)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                  options: .listenOnly, eventsOfInterest: mask,
                                  callback: cb, userInfo: nil) else {
    print("tapCreate failed (permission?)"); exit(3)
}
let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
if let i = CommandLine.arguments.firstIndex(of: "--backspace"), i + 1 < CommandLine.arguments.count {
    let k = Int(CommandLine.arguments[i + 1]) ?? 1
    let mode = CommandLine.arguments.contains("--hid") ? "hid" : "session"
    let key: CGKeyCode = CommandLine.arguments.contains("--letter") ? 7 : 51
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let s = CGEventSource(stateID: mode == "hid" ? .hidSystemState : .combinedSessionState)
        let loc: CGEventTapLocation = mode == "hid" ? .cghidEventTap : .cgSessionEventTap
        for _ in 0..<k {
            let d = CGEvent(keyboardEventSource: s, virtualKey: key, keyDown: true)
            let u = CGEvent(keyboardEventSource: s, virtualKey: key, keyDown: false)
            d?.setIntegerValueField(.eventSourceUserData, value: 0x6B70)
            u?.setIntegerValueField(.eventSourceUserData, value: 0x6B70)
            d?.post(tap: loc); usleep(5000); u?.post(tap: loc); usleep(5000)
        }
        print("posted \(k) key=\(key) mode=\(mode)"); fflush(stdout)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
    print("seen=\(seen)"); exit(0)
}
CFRunLoopRun()
