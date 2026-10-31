#if os(macOS)
    import AppKit
    import ApplicationServices

    /// Marks key events keypipe posts so its own tap can drop them.
    let keypipeEventTag: Int64 = 0x6B70

    final class MacDesktop: Desktop {
        private var fields: [Int: AXUIElement] = [:]
        private var nextToken = 1
        private let lock = NSLock()

        static var trusted: Bool { AXIsProcessTrusted() }

        func snapshot() -> Snapshot {
            let app = NSWorkspace.shared.frontmostApplication
            guard let pid = app?.processIdentifier else { return Snapshot(focus: .nothing) }
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused)
            guard status == .success, let element = focused else {
                return Snapshot(app: app?.bundleIdentifier, focus: .nothing)
            }
            let field = element as! AXUIElement
            let role = attribute(field, kAXRoleAttribute) as? String
            guard role == kAXTextFieldRole || role == kAXTextAreaRole else {
                return Snapshot(app: app?.bundleIdentifier, focus: .nothing)
            }
            if let marked = attribute(field, "AXTextInputMarkedRange"), CFGetTypeID(marked) == AXValueGetTypeID() {
                var range = CFRange()
                if AXValueGetValue(marked as! AXValue, .cfRange, &range), range.length > 0 {
                    return Snapshot(app: app?.bundleIdentifier, focus: .composing)
                }
            }
            lock.lock()
            let token = nextToken
            nextToken += 1
            fields[token] = field
            // Why: one fire is in flight at a time; older handles are dead weight.
            fields = fields.filter { $0.key > token - 4 }
            lock.unlock()
            return Snapshot(app: app?.bundleIdentifier, focus: .text, field: Field(token: token))
        }

        func backspace(_ count: Int) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for _ in 0..<count {
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down) else { continue }
                    event.setIntegerValueField(.eventSourceUserData, value: keypipeEventTag)
                    event.post(tap: .cgSessionEventTap)
                    usleep(5000)
                }
            }
        }

        func text(_ field: Field) -> String? {
            guard let element = element(field) else { return nil }
            return attribute(element, kAXValueAttribute) as? String
        }

        func setText(_ field: Field, _ text: String) -> Bool {
            guard let element = element(field) else { return false }
            return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
        }

        func notify(_ text: String) {
            // Why: the text rides in argv, never in the AppleScript source (R8).
            let script = "osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title \"keypipe\"' -e 'end run' \"$1\""
            _ = runShell(script, input: text, env: [:], timeout: 5)
        }

        private func element(_ field: Field) -> AXUIElement? {
            lock.lock()
            defer { lock.unlock() }
            return fields[field.token]
        }

        private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
    }
#endif
