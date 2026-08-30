import Foundation
import CoreGraphics

// Reflection helpers for the opaque WallpaperExtensionKit XPC objects
// (contract §3). Everything here is best-effort and returns optionals: a
// layout change on a future OS degrades to nil, never a crash.

enum MirrorProbe {
    /// First UUID anywhere in the object graph — the surface identity carried
    /// by WallpaperIDXPC (`box.rawValue.id`). Depth-bounded to avoid cycles.
    static func firstUUID(in any: Any?, depth: Int = 6) -> UUID? {
        guard let any, depth > 0 else { return nil }
        if let uuid = any as? UUID { return uuid }
        let mirror = Mirror(reflecting: any)
        for child in mirror.children {
            if let found = firstUUID(in: child.value, depth: depth - 1) { return found }
        }
        return nil
    }

    /// Value of the first descendant property named `name`.
    static func value(named name: String, in any: Any?, depth: Int = 6) -> Any? {
        guard let any, depth > 0 else { return nil }
        let mirror = Mirror(reflecting: any)
        for child in mirror.children {
            if child.label == name { return child.value }
            if let nested = value(named: name, in: child.value, depth: depth - 1) { return nested }
        }
        return nil
    }

    /// Enum case *name* of the first descendant property named `name`
    /// (e.g. presentationMode -> "locked"). Mirror reports an enum's case as
    /// the single child label of its `.enum` display style.
    static func enumCaseName(named name: String, in any: Any?) -> String? {
        guard let raw = value(named: name, in: any) else { return nil }
        let mirror = Mirror(reflecting: raw)
        if mirror.displayStyle == .enum, let label = mirror.children.first?.label {
            return label
        }
        // A payload-less enum reflects with no children; fall back to describing.
        let described = String(describing: raw)
        return described.isEmpty ? nil : described
    }

    static func cgSize(named name: String, in any: Any?) -> CGSize? {
        value(named: name, in: any) as? CGSize
    }

    static func cgFloat(named name: String, in any: Any?) -> CGFloat? {
        if let d = value(named: name, in: any) as? CGFloat { return d }
        if let d = value(named: name, in: any) as? Double { return CGFloat(d) }
        return nil
    }

    static func uint32(named name: String, in any: Any?) -> UInt32? {
        if let v = value(named: name, in: any) as? UInt32 { return v }
        if let v = value(named: name, in: any) as? Int { return UInt32(exactly: v) }
        return nil
    }

    static func data(named name: String, in any: Any?) -> Data? {
        value(named: name, in: any) as? Data
    }

    /// Last-resort: parse `identifier: "…"` out of an object's description,
    /// used for the choice-id callbacks that carry no clean Mirror path.
    static func identifierFromDescription(_ any: Any?) -> String? {
        guard let any else { return nil }
        let text = String(describing: any)
        guard let range = text.range(of: "identifier: \"") else { return nil }
        let tail = text[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
    }
}
