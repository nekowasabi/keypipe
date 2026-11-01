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
            if ownsPtyMaster(pid) { return Snapshot(app: app?.bundleIdentifier, focus: .terminal) }
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused)
            guard status == .success, let element = focused else {
                return Snapshot(app: app?.bundleIdentifier, focus: .nothing)
            }
            let field = element as! AXUIElement
            // Why: a password field is never read or written. It is reported before the role
            // check so even a focus-any rule stops there (its trigger would be typed into it).
            if attribute(field, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
                return Snapshot(app: app?.bundleIdentifier, focus: .nothing, secure: true)
            }
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

        func notify(_ text: String) { notifyUser(text) }

        func fact(_ name: FactName) -> FactRead {
            switch name {
            case .app:
                return NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(FactRead.value) ?? .absent
            case .url:
                guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                      let script = frontTabURLScript(id) else { return .absent }
                // Why: osascript, not NSAppleScript: the engine runs on a background queue, and
                // a process can be killed at the deadline. The first read asks macOS for
                // Automation permission for keypipe; that fire ends unreadable and notifies.
                switch runShell("osascript -e \"$1\"", input: script, env: [:], timeout: 1) {
                case .exited(0, let stdout):
                    let url = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    return url.isEmpty ? .absent : .value(url)
                case .exited(let status, _): return .unreadable("osascript exit \(status) (allow keypipe under Automation)")
                case .timedOut: return .unreadable("timeout")
                }
            }
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

/// The AppleScript that returns the front tab's URL of a known browser, or nil for any other app.
func frontTabURLScript(_ bundleID: String) -> String? {
    let chromium: Set = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
                         "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser"]
    let safari: Set = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    if chromium.contains(bundleID) { return "tell application id \"\(bundleID)\" to get URL of active tab of front window" }
    if safari.contains(bundleID) { return "tell application id \"\(bundleID)\" to get URL of front document" }
    return nil
}

#if os(macOS)
    /// Whether `pid` has /dev/ptmx open, which is what makes an app a terminal emulator.
    /// Why: a libproc error reads as "not a terminal", the behaviour before this check.
    func ownsPtyMaster(_ pid: pid_t) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard used > 0 else { return false }
        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if path == "/dev/ptmx" { return true }
        }
        return false
    }
#endif
