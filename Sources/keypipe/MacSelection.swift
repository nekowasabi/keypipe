#if os(macOS)
    import AppKit
    import ApplicationServices

    /// The pasteboard right after selection-prompt.sh's Cmd+C, and the front app.
    func readSelectionCopy() -> SelectionCopy {
        let board = NSPasteboard.general
        return SelectionCopy(
            app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            text: board.string(forType: .string) ?? "",
            html: board.string(forType: .html),
            sourceURL: board.string(forType: .init("org.chromium.source-url")))
    }

    /// The URLs of the links under the front app's text selection, read through Accessibility.
    /// Why this walk: Chrome's attributed string for the selection carries no AXLink, and its
    /// AXIndexForTextMarker gave Slack's selection a reversed span (4..0), so the selection is
    /// walked marker by marker and each marker's element is climbed to an enclosing AXLink.
    func selectedLinkURLs() -> [String] {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        // Why: Electron and Chromium build the web tree only for a client that asks for it, and
        // the first ask can come back before the tree exists.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var found = webArea(app)
        if found == nil {
            usleep(300_000)
            found = webArea(app)
        }
        guard let web = found, let raw = value(web, "AXSelectedTextMarkerRange"),
            CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID()
        else { return [] }
        func ask(_ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(
                web, name as CFString, argument, &result) == .success ? result : nil
        }
        let selected = raw as! AXTextMarkerRange
        let ends =
            [AXTextMarkerRangeCopyStartMarker(selected), AXTextMarkerRangeCopyEndMarker(selected)]
            as CFArray
        // Why: a selection dragged right to left comes back with its start after its end.
        let range =
            ask("AXTextMarkerRangeForUnorderedTextMarkers", ends).map { $0 as! AXTextMarkerRange }
            ?? selected
        guard let text = ask("AXStringForTextMarkerRange", range) as? String, !text.isEmpty
        else { return [] }
        func bytes(_ marker: AXTextMarker) -> Data {
            Data(bytes: AXTextMarkerGetBytePtr(marker), count: AXTextMarkerGetLength(marker))
        }
        let end = bytes(AXTextMarkerRangeCopyEndMarker(range))
        var marker = AXTextMarkerRangeCopyStartMarker(range)
        var urls: [String] = []
        // Why: about one marker per character (55 for 53 on a test page); walking further picks up
        // links after the selection when the end marker never compares equal.
        for _ in 0..<(text.utf16.count + 2) {
            if let hit = ask("AXUIElementForTextMarker", marker).flatMap(enclosingLinkURL) {
                urls.append(hit)
            }
            guard bytes(marker) != end, let next = ask("AXNextTextMarkerForTextMarker", marker),
                CFGetTypeID(next) == AXTextMarkerGetTypeID()
            else { break }
            marker = next as! AXTextMarker
        }
        return urls
    }

    private func webArea(_ app: AXUIElement) -> AXUIElement? {
        guard let window = value(app, kAXFocusedWindowAttribute) else { return nil }
        var queue = [window as! AXUIElement]
        var visited = 0
        while !queue.isEmpty, visited < 5000 {
            let element = queue.removeFirst()
            visited += 1
            if value(element, kAXRoleAttribute) as? String == "AXWebArea" { return element }
            queue += value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return nil
    }

    private func enclosingLinkURL(_ found: CFTypeRef) -> String? {
        guard CFGetTypeID(found) == AXUIElementGetTypeID() else { return nil }
        var element = found as! AXUIElement
        for _ in 0..<8 {
            if value(element, kAXRoleAttribute) as? String == "AXLink",
                let url = value(element, kAXURLAttribute)
            {
                return (url as? URL)?.absoluteString ?? "\(url)"
            }
            guard let parent = value(element, kAXParentAttribute) else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success
            ? result : nil
    }
#endif
