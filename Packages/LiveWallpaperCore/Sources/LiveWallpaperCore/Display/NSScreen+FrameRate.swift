import AppKit
import CoreGraphics

public extension NSScreen {
    /// The selected display mode, rather than the panel's highest supported mode.
    /// Variable-refresh modes may report zero; AppKit then supplies the active ceiling.
    var configuredFramesPerSecond: Int {
        let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let rate = displayID.flatMap { CGDisplayCopyDisplayMode($0) }?.refreshRate ?? 0
        return rate.isFinite && rate > 0 ? max(1, Int(rate.rounded())) : max(1, maximumFramesPerSecond)
    }
}
