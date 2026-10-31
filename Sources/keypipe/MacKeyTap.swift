#if os(macOS)
    import ApplicationServices
    import Carbon
    import Foundation

    /// Listen-only CGEventTap. Each key event is handed to `onInput` on the
    /// tap's thread; the callback must return quickly, so callers enqueue.
    /// The app in front receives every event regardless: keypipe never consumes.
    final class MacKeyTap {
        private var tap: CFMachPort?
        private let onInput: (Input) -> Void

        init?(onInput: @escaping (Input) -> Void) {
            self.onInput = onInput
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, info in
                    Unmanaged<MacKeyTap>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
            else { return nil }
            self.tap = tap
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        private func handle(_ type: CGEventType, _ event: CGEvent) {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
                fputs("keypipe tap re-enabled after \(type.rawValue)\n", stderr)
                return
            }
            guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != keypipeEventTag else { return }
            let key = keyString(event)
            var modifiers = Set<Modifier>()
            if event.flags.contains(.maskControl) { modifiers.insert(.ctrl) }
            if event.flags.contains(.maskAlternate) { modifiers.insert(.alt) }
            if event.flags.contains(.maskCommand) { modifiers.insert(.cmd) }
            if modifiers.isEmpty {
                for character in key { onInput(.char(character)) }
            } else if key.count == 1, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onInput(.hotkey(Hotkey(modifiers: modifiers, key: key)))
            }
        }

        /// The character the current layout produces for the key with only
        /// shift applied. Why: a synthetic event's stored string ignores shift
        /// (shift+1 arrives as "1") and a control chord stores a control code;
        /// apps translate from keycode and flags, so keypipe does the same.
        private func keyString(_ event: CGEvent) -> String {
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
            if let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
                let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
                let translated = data.withUnsafeBytes { bytes -> String? in
                    let layout = bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
                    var dead: UInt32 = 0
                    var length = 0
                    var units = [UniChar](repeating: 0, count: 8)
                    let shift = event.flags.contains(.maskShift) ? UInt32(shiftKey >> 8) & 0xFF : 0
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), shift, UInt32(LMGetKbdType()),
                                                UInt32(kUCKeyTranslateNoDeadKeysMask), &dead, units.count, &length, &units)
                    return status == noErr && length > 0 ? String(utf16CodeUnits: units, count: length) : nil
                }
                if let translated { return translated }
            }
            var length = 0
            var units = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
            return String(utf16CodeUnits: units, count: length)
        }
    }
#endif
