#if os(macOS)
    import ApplicationServices
    import Foundation

    /// Listen-only CGEventTap. Each typed character is handed to `onKey` on the
    /// tap's thread; the callback must return quickly, so callers enqueue.
    final class MacKeyTap {
        private var tap: CFMachPort?
        private let onKey: (Character) -> Void

        init?(onKey: @escaping (Character) -> Void) {
            self.onKey = onKey
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
            guard type == .keyDown,
                  event.getIntegerValueField(.eventSourceUserData) != keypipeEventTag,
                  !event.flags.contains(.maskCommand) else { return }
            var length = 0
            var units = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
            for character in String(utf16CodeUnits: units, count: length) { onKey(character) }
        }
    }
#endif
