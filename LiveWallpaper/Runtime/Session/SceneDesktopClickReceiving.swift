#if !LITE_BUILD
import CoreGraphics

@MainActor protocol SceneDesktopClickReceiving: AnyObject {
    /// false while Interaction is on (native capture owns clicks) or playback is not running.
    var acceptsDesktopClicks: Bool { get }
    /// Points are Cocoa global screen coordinates (bottom-left origin).
    func publishDesktopButton(location: CGPoint, pressLocation: CGPoint, isDown: Bool, gesture: UInt64, dragged: Bool)
}
#endif
