// Throwaway. Writes TEXT to the focused element's AXValue of the frontmost app
// and polls the readback every 10 ms for up to 2 s, printing when (if) it
// matches. Measures delayed or ignored writes (Chromium, Electron).
import ApplicationServices
import AppKit

// Usage: axwrite <text> [--restore]   (--restore writes the original value back; argv[1] is then the original)
let restoring = CommandLine.arguments.contains("--restore")
var text = CommandLine.arguments.dropFirst().first ?? "HELLO"
guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { exit(1) }
var focused: CFTypeRef?
guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
      let el = focused else { print("no focus"); exit(2) }
let elem = el as! AXUIElement
func value() -> String {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &v)
    return e == .success ? (v as? String ?? "<non-string>") : "<err \(e.rawValue)>"
}
var role: CFTypeRef?
AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &role)
let original = value()
if restoring { text = original + " keypipe-probe" }
print("app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") role=\(role as? String ?? "?") beforeLength=\(original.count)")
let start = ProcessInfo.processInfo.systemUptime
let err = AXUIElementSetAttributeValue(elem, kAXValueAttribute as CFString, text as CFTypeRef)
print("writeErr=\(err.rawValue)")
var matched = false
while ProcessInfo.processInfo.systemUptime - start < 2 {
    if value() == text {
        print(String(format: "matched after %.0f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))
        matched = true
        break
    }
    usleep(10000)
}
if !matched { print("not matched after 2 s, readback=\(value().debugDescription)") }
if restoring {
    _ = AXUIElementSetAttributeValue(elem, kAXValueAttribute as CFString, original as CFTypeRef)
    usleep(100000)
    print("restored=\(value() == original)")
}
