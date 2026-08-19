import Foundation
import QuartzCore
import os.log

// Thin wrapper over the private remote CAContext (contract §4). A remote
// context hosts a layer tree inside WallpaperAgent's CALayerHost; only
// IOSurface-backed content composites across that boundary (contract §5).
final class RemoteContextBridge {
    let rootLayer = CALayer()
    private var caContext: NSObject?

    /// Returns the remote contextId to hand back to the Agent, or nil.
    func makeContext(displayID: UInt32?, size: CGSize, scale: CGFloat) -> UInt32? {
        guard let caContextClass = NSClassFromString("CAContext") as? NSObject.Type else {
            wpxLog.error("CAContext class missing")
            return nil
        }

        let context: NSObject?
        if let displayID {
            let sel = NSSelectorFromString("remoteContextWithOptions:")
            guard caContextClass.responds(to: sel) else {
                wpxLog.error("remoteContextWithOptions: unavailable")
                return nil
            }
            context = caContextClass.perform(sel, with: ["displayId": displayID])?
                .takeUnretainedValue() as? NSObject
        } else {
            let sel = NSSelectorFromString("remoteContext")
            context = caContextClass.perform(sel)?.takeUnretainedValue() as? NSObject
        }
        guard let context else {
            wpxLog.error("remote context creation returned nil")
            return nil
        }
        self.caContext = context

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = CGRect(origin: .zero, size: size)
        rootLayer.contentsScale = scale
        rootLayer.contentsGravity = .resizeAspectFill
        rootLayer.isOpaque = true
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        context.setValue(rootLayer, forKey: "layer")
        CATransaction.commit()
        CATransaction.flush()

        let contextId = (context.value(forKey: "contextId") as? NSNumber)?.uint32Value ?? 0
        guard contextId != 0 else {
            wpxLog.error("contextId is 0")
            return nil
        }
        return contextId
    }

    func reframe(size: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = CGRect(origin: .zero, size: size)
        rootLayer.contentsScale = scale
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Dropping the Swift ref is not enough — the render server pins the layer
    /// tree until an explicit invalidate (contract §4), else composite cost
    /// climbs until `killall WallpaperAgent`.
    func invalidate() {
        guard let caContext else { return }
        let sel = NSSelectorFromString("invalidate")
        if caContext.responds(to: sel) {
            caContext.perform(sel)
        }
        self.caContext = nil
    }
}
