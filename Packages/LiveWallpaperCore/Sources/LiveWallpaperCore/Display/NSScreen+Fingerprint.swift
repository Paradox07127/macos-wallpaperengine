import AppKit
import CoreGraphics

/// EDID `vendor:model:serial` is the primary key. Panels reporting serial 0 are
/// indistinguishable from an identical unit of the same model, so those fall back to
/// the per-display UUID, which macOS keeps stable across reboots.
public enum DisplayFingerprint {
    public static func make(
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        uuid: @autoclosure () -> String?,
        localizedName: String
    ) -> String {
        if serial != 0, vendor != 0 || model != 0 {
            return edid(vendor: vendor, model: model, serial: serial)
        }
        if let uuid = uuid() {
            return "uuid:\(uuid)"
        }
        if vendor == 0, model == 0, serial == 0 {
            return "unknown:0:0:0:\(localizedName)"
        }
        return edid(vendor: vendor, model: model, serial: serial)
    }

    public static func edid(vendor: UInt32, model: UInt32, serial: UInt32) -> String {
        "\(vendor):\(model):\(serial)"
    }

    /// The key this display used before UUIDs were adopted, when that differs
    /// from the key it uses now. Callers move stored settings across once.
    public static func legacyKey(
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        current: String
    ) -> String? {
        guard vendor != 0 || model != 0 || serial != 0 else { return nil }
        let legacy = edid(vendor: vendor, model: model, serial: serial)
        return legacy == current ? nil : legacy
    }
}

public extension NSScreen {
    var displayFingerprint: String {
        guard let displayID = displayNumber else { return "unknown:\(localizedName)" }
        return DisplayFingerprint.make(
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            serial: CGDisplaySerialNumber(displayID),
            uuid: Self.displayUUID(for: displayID),
            localizedName: localizedName
        )
    }

    var legacyDisplayFingerprint: String? {
        guard let displayID = displayNumber else { return nil }
        return DisplayFingerprint.legacyKey(
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            serial: CGDisplaySerialNumber(displayID),
            current: displayFingerprint
        )
    }

    private var displayNumber: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

public extension String {
    var isUnknownDisplayFingerprint: Bool {
        hasPrefix("unknown:")
    }
}
