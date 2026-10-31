// Throwaway. Prints the current input source; with an id argument selects it.
import Carbon
func cur() -> String {
    let s = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID)!
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
print("before=\(cur())")
if CommandLine.arguments.count > 1 {
    let want = CommandLine.arguments[1]
    let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    for s in list {
        let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID)!
        let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        if id == want { print("select=\(TISSelectInputSource(s))") }
    }
    print("after=\(cur())")
}
