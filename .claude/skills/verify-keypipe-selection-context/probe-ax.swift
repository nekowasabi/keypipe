// Reads Slack's current text selection through Accessibility and prints only link URLs
// and attribute names found in it (never the selected text).
import AppKit
import ApplicationServices

// Usage: swift probe-ax.swift [BUNDLE_ID]   (default: Google Chrome; Slack desktop is com.tinyspeck.slackmacgap)
let bundle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.google.Chrome"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
else { print("\(bundle) not running"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
// Why: Electron builds its web accessibility tree only when asked.
AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
usleep(500_000)
print("trusted:", AXIsProcessTrusted())

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
  var v: CFTypeRef?
  return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
// Why: a selection in the message list is not the focused element (the composer is);
// Chromium answers the page's selection on the AXWebArea.
guard let w = attr(ax, "AXFocusedWindow") else { print("no window"); exit(1) }
var queue = [w as! AXUIElement], web: AXUIElement?
var seen = 0
while !queue.isEmpty, web == nil, seen < 5000 {
  let e = queue.removeFirst(); seen += 1
  if attr(e, "AXRole") as? String == "AXWebArea" { web = e; break }
  if let kids = attr(e, "AXChildren") as? [AXUIElement] { queue += kids }
}
guard let focused = web else { print("no AXWebArea after", seen); exit(1) }
print("focused role:", attr(focused, "AXRole") as? String ?? "?")
guard let range = attr(focused, "AXSelectedTextMarkerRange") else { print("no AXSelectedTextMarkerRange"); exit(1) }
var asRef: CFTypeRef?
let e2 = AXUIElementCopyParameterizedAttributeValue(
  focused, "AXAttributedStringForTextMarkerRange" as CFString, range, &asRef)
guard e2 == .success, let s = asRef as? NSAttributedString else { print("no attributed string:", e2.rawValue); exit(1) }
print("selected length:", s.length)
var keys = Set<String>(), urls: [String] = []
s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { a, _, _ in
  for (k, v) in a {
    keys.insert(k.rawValue)
    if k.rawValue == "AXLink", CFGetTypeID(v as CFTypeRef) == AXUIElementGetTypeID() {
      let link = v as! AXUIElement
      if let u = attr(link, "AXURL") { urls.append("\(u)") }
    }
  }
}
print("attributes:", keys.sorted().joined(separator: ", "))
// Why: Chrome's attributed string carries no AXLink (seen 2026-11-06), and on Slack's page
// AXIndexForTextMarker gave an end index before the start (4, 0), so text indices cannot be
// compared. Walk the selection marker by marker instead and climb from each marker's element
// to an enclosing AXLink.
func param(_ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
  var v: CFTypeRef?
  return AXUIElementCopyParameterizedAttributeValue(focused, name as CFString, arg, &v) == .success ? v : nil
}
func bytes(_ m: CFTypeRef) -> Data {
  let t = m as! AXTextMarker
  return Data(bytes: AXTextMarkerGetBytePtr(t), count: AXTextMarkerGetLength(t))
}
let raw = range as! AXTextMarkerRange
// Why: a selection dragged right to left comes back with start after end; this puts them in order.
let pair = [AXTextMarkerRangeCopyStartMarker(raw), AXTextMarkerRangeCopyEndMarker(raw)] as CFArray
let tr = (param("AXTextMarkerRangeForUnorderedTextMarkers", pair) as! AXTextMarkerRange?) ?? raw
let start = AXTextMarkerRangeCopyStartMarker(tr), end = AXTextMarkerRangeCopyEndMarker(tr)
let endBytes = bytes(end)
var m: CFTypeRef = start
var steps = 0, roles = Set<String>()
// Why: about one marker per character (55 for 53 on the test page); walking further would pick
// up links after the selection when the end marker never compares equal.
let limit = s.length + 2
while steps < limit {
  steps += 1
  if var el = param("AXUIElementForTextMarker", m).map({ $0 as! AXUIElement }) {
    for _ in 0..<8 {
      let role = attr(el, "AXRole") as? String ?? "?"
      roles.insert(role)
      if role == "AXLink", let u = attr(el, "AXURL") {
        let s = "\(u)"
        if !urls.contains(s) { urls.append(s) }
        break
      }
      guard let p = attr(el, "AXParent") else { break }
      el = p as! AXUIElement
    }
  }
  if bytes(m) == endBytes { break }
  guard let next = param("AXNextTextMarkerForTextMarker", m) else { break }
  m = next
}
print("markers walked:", steps, "of limit", limit, "reached end:", bytes(m) == endBytes)
print("roles seen:", roles.sorted().joined(separator: ", "))
print("link urls:", urls.isEmpty ? "(none)" : urls.joined(separator: " "))
