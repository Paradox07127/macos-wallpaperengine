import CoreGraphics
import IOKit.graphics

/// What identifies a mode across reconfigurations; CG renumbers mode IDs, so they are never stored.
struct DisplayModeKey: Hashable, Sendable {
    /// Points.
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    /// Hz; 0 when the display does not report a rate.
    let refreshRate: Double
}

extension DisplayModeKey {
    init(_ mode: CGDisplayMode) {
        self.init(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate
        )
    }
}

struct DisplayModeOption: Hashable, Sendable {
    let key: DisplayModeKey
    let isCurrent: Bool
    let isNative: Bool

    var isHiDPI: Bool {
        key.pixelWidth > key.width
    }
}

enum DisplayModes {
    /// One option per key, in first-seen order; a key is native when any of its duplicates carries the flag.
    static func options(from modes: [(key: DisplayModeKey, isNative: Bool)], current: DisplayModeKey?) -> [DisplayModeOption] {
        var order: [DisplayModeKey] = []
        var nativeKeys: Set<DisplayModeKey> = []
        for mode in modes {
            if !order.contains(mode.key) {
                order.append(mode.key)
            }
            if mode.isNative {
                nativeKeys.insert(mode.key)
            }
        }
        return order.map { DisplayModeOption(key: $0, isCurrent: $0 == current, isNative: nativeKeys.contains($0)) }
    }

    static func firstMode<Mode>(matching key: DisplayModeKey, in modes: [Mode], keyOf: (Mode) -> DisplayModeKey) -> Mode? {
        modes.first { keyOf($0) == key }
    }

    static func availableOptions(for display: CGDirectDisplayID) -> [DisplayModeOption] {
        options(
            from: usableModes(for: display).map {
                (DisplayModeKey($0), $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0)
            },
            current: CGDisplayCopyDisplayMode(display).map(DisplayModeKey.init)
        )
    }

    static func apply(_ key: DisplayModeKey, to display: CGDirectDisplayID) throws {
        // Committing the mode the display already runs fails with 1001.
        if CGDisplayCopyDisplayMode(display).map(DisplayModeKey.init) == key {
            return
        }
        guard let mode = firstMode(matching: key, in: usableModes(for: display), keyOf: DisplayModeKey.init) else {
            throw DisplayControlError.modeNotFound
        }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { throw DisplayControlError.windowServer(begin) }
        let configure = CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        guard configure == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayControlError.windowServer(configure)
        }
        let complete = CGCompleteDisplayConfiguration(config, DisplayControl.configurationScope)
        guard complete == .success else { throw DisplayControlError.windowServer(complete) }
    }

    private static func usableModes(for display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
        return modes.filter { $0.isUsableForDesktopGUI() }
    }
}
