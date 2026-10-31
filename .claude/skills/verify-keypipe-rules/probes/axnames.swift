// Throwaway. Frontmost app's focused element: role, every attribute name,
// and the values of marked-text / selection attributes, to see what AX
// exposes for "no focus" and "IME composing".
import ApplicationServices
import AppKit

let app = NSWorkspace.shared.frontmostApplication
print("app=\(app?.bundleIdentifier ?? "nil")")
guard let pid = app?.processIdentifier else { exit(1) }
let axApp = AXUIElementCreateApplication(pid)
var focused: CFTypeRef?
let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
print("focusedErr=\(err.rawValue) isNil=\(focused == nil)")
var win: CFTypeRef?
let werr = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win)
print("focusedWindowErr=\(werr.rawValue) isNil=\(win == nil)")
guard err == .success, let el = focused else { exit(0) }
let elem = el as! AXUIElement
var names: CFArray?
AXUIElementCopyAttributeNames(elem, &names)
let list = (names as? [String]) ?? []
print("attrs=\(list.joined(separator: ","))")
func attr(_ name: String) -> String {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(elem, name as CFString, &v)
    if e != .success { return "<err \(e.rawValue)>" }
    return String(describing: v!)
}
for a in ["AXRole", "AXSubrole", "AXRoleDescription", "AXValue", "AXSelectedTextRange", "AXMarkedRange", "AXInsertionPointLineNumber", "AXFocused", "AXEditable", "AXEnabled", "AXTextInputMarkedRange"] where list.contains(a) {
    print("\(a)=\(attr(a))")
}
if list.contains("AXMarkedRange") { print("hasMarkedRange=true") }
var params: CFArray?
AXUIElementCopyParameterizedAttributeNames(elem, &params)
print("params=\(((params as? [String]) ?? []).joined(separator: ","))")
