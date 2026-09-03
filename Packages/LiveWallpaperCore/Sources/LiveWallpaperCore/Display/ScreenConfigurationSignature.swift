import AppKit
import CoreGraphics

/// Quantized snapshot of `NSScreen` geometry for deduping
/// `didChangeScreenParametersNotification` storms.
public struct ScreenConfigurationSignature: Equatable, Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    public let originX: Int
    public let originY: Int
    public let width: Int
    public let height: Int
    public let scale: Int
    /// Part of the signature because frame-rate caps are divisors of it: a panel
    /// switched from 60 Hz to 120 Hz with the same geometry has to re-resolve
    /// every ceiling, and without this field the change dedupes away.
    public let maximumFramesPerSecond: Int

    public init(screen: NSScreen) {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
        let f = screen.frame
        self.displayID = id
        self.originX = Self.quantize(f.origin.x)
        self.originY = Self.quantize(f.origin.y)
        self.width   = Self.quantize(f.width)
        self.height  = Self.quantize(f.height)
        self.scale   = Self.quantize(screen.backingScaleFactor)
        maximumFramesPerSecond = screen.maximumFramesPerSecond
    }

    private static func quantize(_ value: CGFloat) -> Int { Int((value * 1000).rounded()) }

    @MainActor
    public static func currentLayout() -> [CGDirectDisplayID: ScreenConfigurationSignature] {
        Dictionary(uniqueKeysWithValues:
            NSScreen.screens.map { screen -> (CGDirectDisplayID, ScreenConfigurationSignature) in
                let sig = ScreenConfigurationSignature(screen: screen)
                return (sig.displayID, sig)
            }
        )
    }
}
