// Throwaway. Listen-only tap for N seconds; for every keyDown prints flags,
// keycode, the raw unicode string, the string of a copy with only shift kept,
// and UCKeyTranslate with only the shift state, to pick how a hotkey's key
// character is derived.
import ApplicationServices
import AppKit
import Carbon

let secs = Double(CommandLine.arguments.dropFirst().first ?? "6") ?? 6
print("trusted=\(AXIsProcessTrusted()) listening \(secs)s")

func translate(_ code: CGKeyCode, shift: Bool) -> String {
    let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "<nolayout>" }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    return data.withUnsafeBytes { bytes -> String in
        let layout = bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                                    UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                                    &dead, units.count, &length, &units)
        return status == noErr ? String(utf16CodeUnits: units, count: length) : "<err \(status)>"
    }
}

let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
let cb: CGEventTapCallBack = { _, type, ev, _ in
    guard type == .keyDown else { return Unmanaged.passUnretained(ev) }
    var len = 0
    var buf = [UniChar](repeating: 0, count: 8)
    ev.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
    let raw = String(utf16CodeUnits: buf, count: len)
    let copy = ev.copy()!
    copy.flags = ev.flags.intersection(.maskShift)
    var clen = 0
    var cbuf = [UniChar](repeating: 0, count: 8)
    copy.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &clen, unicodeString: &cbuf)
    let copied = String(utf16CodeUnits: cbuf, count: clen)
    let code = CGKeyCode(ev.getIntegerValueField(.keyboardEventKeycode))
    let shift = ev.flags.contains(.maskShift)
    print("code=\(code) flags=\(String(ev.flags.rawValue, radix: 16)) raw=\(raw.debugDescription) copy=\(copied.debugDescription) uckey=\(translate(code, shift: shift).debugDescription) repeat=\(ev.getIntegerValueField(.keyboardEventAutorepeat))")
    fflush(stdout)
    return Unmanaged.passUnretained(ev)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                  eventsOfInterest: mask, callback: cb, userInfo: nil) else {
    print("tapCreate failed"); exit(3)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
CFRunLoopRun()
