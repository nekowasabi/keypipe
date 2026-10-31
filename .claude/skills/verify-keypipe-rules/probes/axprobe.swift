// Throwaway. Dumps the focused AX element of the frontmost app and, with
// --write TEXT, tries to set AXValue and reads it back.
import ApplicationServices
import AppKit

let trusted = AXIsProcessTrusted()
print("trusted=\(trusted)")
let app = NSWorkspace.shared.frontmostApplication
print("app=\(app?.bundleIdentifier ?? "nil") pid=\(app?.processIdentifier ?? -1)")
guard let pid = app?.processIdentifier else { exit(1) }
let axApp = AXUIElementCreateApplication(pid)
var focused: CFTypeRef?
let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
print("focusedErr=\(err.rawValue)")
guard err == .success, let el = focused else { exit(2) }
let elem = el as! AXUIElement
func attr(_ name: String) -> String {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(elem, name as CFString, &v)
    if e != .success { return "<err \(e.rawValue)>" }
    return String(describing: v!)
}
for a in ["AXRole", "AXSubrole", "AXRoleDescription", "AXValue", "AXSelectedText", "AXNumberOfCharacters"] {
    print("\(a)=\(attr(a))")
}
var settable: DarwinBoolean = false
AXUIElementIsAttributeSettable(elem, kAXValueAttribute as CFString, &settable)
print("AXValueSettable=\(settable)")
if let i = CommandLine.arguments.firstIndex(of: "--write"), i + 1 < CommandLine.arguments.count {
    let text = CommandLine.arguments[i + 1]
    let w = AXUIElementSetAttributeValue(elem, kAXValueAttribute as CFString, text as CFTypeRef)
    print("writeErr=\(w.rawValue) readback=\(attr("AXValue"))")
}
