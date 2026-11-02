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
                AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString,
                &focused)
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
            if let marked = attribute(field, "AXTextInputMarkedRange"),
                CFGetTypeID(marked) == AXValueGetTypeID()
            {
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
                    guard
                        let event = CGEvent(
                            keyboardEventSource: source, virtualKey: 51, keyDown: down)
                    else { continue }
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
            return AXUIElementSetAttributeValue(
                element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
        }

        func notify(_ text: String) { notifyUser(text) }

        /// Posts the text as tagged Unicode key events, so keypipe's own tap drops them and the
        /// typed text never re-enters the trigger matcher.
        func typeText(_ text: String) -> Bool {
            // Same contract as FakeDesktop: a caret exists in a text field or a terminal, never in a
            // password field or where nothing editable has focus.
            let now = snapshot()
            guard !now.secure, now.focus == .text || now.focus == .terminal else { return false }
            let source = CGEventSource(stateID: .combinedSessionState)
            // Why: one event carries at most 20 UTF-16 units.
            let units = Array(text.utf16)
            var start = 0
            while start < units.count {
                var end = min(start + 20, units.count)
                // Why: never split a surrogate pair (emoji) across two events.
                if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
                let chunk = Array(units[start..<end])
                for down in [true, false] {
                    guard
                        let event = CGEvent(
                            keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    else { return false }
                    chunk.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(
                            stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                    // Why: a hotkey fires while its chord is still held; without this the text would
                    // be typed as ctrl/cmd shortcuts.
                    event.flags = []
                    event.setIntegerValueField(.eventSourceUserData, value: keypipeEventTag)
                    event.post(tap: .cgSessionEventTap)
                }
                usleep(5000)
                start = end
            }
            return true
        }

        func fact(_ name: FactName) -> FactRead {
            switch name {
            case .app:
                return NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(FactRead.value)
                    ?? .absent
            case .url:
                guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                    let script = frontTabURLScript(id)
                else { return .absent }
                // Why: osascript, not NSAppleScript: the engine runs on a background queue, and
                // a process can be killed at the deadline. The first read asks macOS for
                // Automation permission for keypipe; that fire ends unreadable and notifies.
                switch runShell("osascript -e \"$1\"", input: script, env: [:], timeout: 1) {
                case .exited(0, let stdout):
                    // An empty answer is a browser with no window or tab: there is no URL.
                    let url = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    return url.isEmpty ? .absent : .value(url)
                case .exited(let status, _):
                    // The script returns "" only for a missing window or tab, so this is a real failure.
                    return .unreadable(
                        "osascript exit \(status): Automation not allowed, or the browser did not answer"
                    )
                case .timedOut: return .unreadable("timeout")
                }
            }
        }

        func sameField(_ a: Field, _ b: Field) -> Bool {
            guard let x = element(a), let y = element(b) else { return false }
            return CFEqual(x, y)
        }

        func showBusy(near field: Field?) {
            // AX reads stay on the engine queue; only the window work goes to main.
            let point = field.flatMap(element).flatMap(caretPoint) ?? NSEvent.mouseLocation
            DispatchQueue.main.async { BusySpinner.shared.show(at: point) }
        }

        func hideBusy() {
            DispatchQueue.main.async { BusySpinner.shared.hide() }
        }

        /// The caret's right edge in AppKit coordinates, or the field's bottom-left corner when the
        /// app does not report text bounds (Electron often does not).
        private func caretPoint(_ element: AXUIElement) -> NSPoint? {
            let rect = caretRect(element) ?? frameRect(element)
            guard let rect, let primary = NSScreen.screens.first else { return nil }
            // Why: AX measures from the top-left of the primary display, AppKit from its bottom-left.
            return NSPoint(x: rect.maxX, y: primary.frame.height - rect.midY)
        }

        private func caretRect(_ element: AXUIElement) -> CGRect? {
            guard let value = attribute(element, kAXSelectedTextRangeAttribute),
                CFGetTypeID(value) == AXValueGetTypeID()
            else { return nil }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
            // Why: some apps answer an empty range with a zero rect; the character before the
            // caret has a real one.
            let candidates = [
                CFRange(location: range.location, length: 0),
                CFRange(location: max(range.location - 1, 0), length: 1),
            ]
            for var candidate in candidates {
                guard let axRange = AXValueCreate(.cfRange, &candidate) else { continue }
                var bounds: CFTypeRef?
                guard
                    AXUIElementCopyParameterizedAttributeValue(
                        element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange,
                        &bounds) == .success,
                    let bounds, CFGetTypeID(bounds) == AXValueGetTypeID()
                else { continue }
                var rect = CGRect.zero
                if AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 {
                    return rect
                }
            }
            return nil
        }

        private func frameRect(_ element: AXUIElement) -> CGRect? {
            guard let position = attribute(element, kAXPositionAttribute),
                let size = attribute(element, kAXSizeAttribute),
                CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                AXValueGetValue(size as! AXValue, .cgSize, &extent)
            else { return nil }
            // A zero-width rect at the field's left edge, one line high at its bottom.
            let line = min(extent.height, 20)
            return CGRect(x: origin.x, y: origin.y + extent.height - line, width: 0, height: line)
        }

        private func element(_ field: Field) -> AXUIElement? {
            lock.lock()
            defer { lock.unlock() }
            return fields[field.token]
        }

        private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
            else { return nil }
            return value
        }
    }
#endif

/// Browsers whose front tab URL keypipe can read, by the AppleScript dictionary they share.
let chromiumBrowsers: Set = [
    "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
    "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
]
let safariBrowsers: Set = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

/// The AppleScript that returns the front tab's URL of a known browser, or nil for any other app.
func frontTabURLScript(_ bundleID: String) -> String? {
    let query: String
    if chromiumBrowsers.contains(bundleID) {
        query = "URL of active tab of front window"
    } else if safariBrowsers.contains(bundleID) {
        query = "URL of front document"
    } else {
        return nil
    }
    // Only "no such window or tab" (-1728, -1719) means there is no URL. Every other error, a denied
    // Automation permission (-1743) above all, must stay an error: a deny entry has to stop on it.
    return """
        try
        tell application id "\(bundleID)" to return \(query)
        on error m number n
        if n is -1728 or n is -1719 then return ""
        error m number n
        end try
        """
}

#if os(macOS)
    /// A small spinning indicator beside the caret while a fire runs. Main thread only.
    final class BusySpinner {
        static let shared = BusySpinner()
        private let size: CGFloat = 22
        private let arc = CAShapeLayer()
        private lazy var panel: NSPanel = {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // Why: non-activating and mouse-transparent, so the field keeps focus and the
            // replaceInput write still lands in it.
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            // Why: an NSProgressIndicator in this never-activated panel put a window on screen
            // but drew nothing; a Core Animation layer is drawn by the window server itself.
            let view = panel.contentView!
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            view.layer?.cornerRadius = 6
            arc.frame = view.bounds
            arc.path = CGPath(ellipseIn: view.bounds.insetBy(dx: 5, dy: 5), transform: nil)
            arc.fillColor = nil
            arc.strokeColor = NSColor.white.cgColor
            arc.lineWidth = 2
            arc.lineCap = .round
            arc.strokeEnd = 0.75
            view.layer?.addSublayer(arc)
            return panel
        }()

        func show(at point: NSPoint) {
            panel.setFrameOrigin(NSPoint(x: point.x + 4, y: point.y - size / 2))
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.8
            spin.repeatCount = .infinity
            arc.add(spin, forKey: "spin")
            panel.orderFrontRegardless()
        }

        func hide() {
            panel.orderOut(nil)
            arc.removeAnimation(forKey: "spin")
        }
    }

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
            guard
                proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize)
                    == infoSize
            else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if path == "/dev/ptmx" { return true }
        }
        return false
    }
#endif
