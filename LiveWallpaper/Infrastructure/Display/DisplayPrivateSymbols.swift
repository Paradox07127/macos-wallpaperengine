#if !MAS_BUILD
import CoreGraphics
import Darwin

struct DisplayPrivateSymbols: Sendable {
    typealias ConfigureDisplayEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    typealias GetDisplayList = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    typealias SetDisplayRotation = @convention(c) (CGDirectDisplayID, Int32) -> CGError

    /// nil = SkyLight does not export the symbol on this OS.
    let configureDisplayEnabled: ConfigureDisplayEnabled?
    let getDisplayList: GetDisplayList?
    let setDisplayRotation: SetDisplayRotation?
    let isMonitorPanelLoaded: Bool

    static let shared = DisplayPrivateSymbols()

    private init() {
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        configureDisplayEnabled = Self.symbol(named: "SLSConfigureDisplayEnabled", in: skyLight)
        getDisplayList = Self.symbol(named: "SLSGetDisplayList", in: skyLight)
        setDisplayRotation = Self.symbol(named: "SLSSetDisplayRotation", in: skyLight)
        isMonitorPanelLoaded = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil
    }

    private static func symbol<Function>(named name: String, in handle: UnsafeMutableRawPointer?) -> Function? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: Function.self)
    }
}
#endif
