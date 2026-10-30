import Foundation

#if os(macOS)
    // Future macOS key-tap hook, intentionally not wired in this MVP.
    // Plan: create a CGEventTap for keyDown events, convert each CGEvent to the
    // typed character, and call TriggerMatcher.feed on every keystroke. When feed
    // returns a rule, execute rule.action. This needs Accessibility permission
    // (AXIsProcessTrusted) and only compiles and runs on macOS.
#endif
public let macKeyTapHook =
    "CGEventTap feeds characters into TriggerMatcher.feed; requires Accessibility permission"
