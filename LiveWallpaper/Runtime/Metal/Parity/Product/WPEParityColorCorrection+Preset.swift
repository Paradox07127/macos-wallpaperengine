#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

enum WPEParityColorCorrectionPresetError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedType(field: String)
    case unsupportedNumber(field: String)
    case unsupportedPath(field: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedType(field):
            "Unsupported WPE preset type for \(field)"
        case let .unsupportedNumber(field):
            "Unsupported WPE preset number for \(field): expected a finite value from 0 to 100"
        case let .unsupportedPath(field):
            "Unsupported WPE preset path for \(field): expected a safe relative LUT name"
        }
    }
}

extension WPEParityColorCorrection {
    /// A complete preset snapshot, not a property patch. Its raw values feed the existing WPE normalisation;
    /// malformed and unmeasured inputs remain explicit failures instead of inheriting the old additive grading.
    init(presetSnapshot values: [String: WallpaperEngineProjectPropertyValue]) throws(WPEParityColorCorrectionPresetError) {
        func number(_ field: String) throws(WPEParityColorCorrectionPresetError) -> Double? {
            guard let raw = values[field] else { return nil }
            guard case let .number(value) = raw else { throw .unsupportedType(field: field) }
            guard value.isFinite, (0 ... 100).contains(value) else { throw .unsupportedNumber(field: field) }
            return value
        }

        let enabled: Bool?
        if let raw = values["wec_e"] {
            guard case let .bool(value) = raw else { throw .unsupportedType(field: "wec_e") }
            enabled = value
        } else {
            enabled = nil
        }

        let lut: String?
        if let raw = values["wcc_v"] {
            guard case let .string(value) = raw else { throw .unsupportedType(field: "wcc_v") }
            // This is a Mac resource boundary, not a claim about WPE's handling of unsafe paths. Preserve
            // canonical names exactly; extension stripping and Windows separator conversion are unmeasured.
            let components = value.split(separator: "/", omittingEmptySubsequences: false)
            guard value.isEmpty || (!value.hasPrefix("/") && !value.contains(":") && !value.contains("\\")
                && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw .unsupportedPath(field: "wcc_v")
            }
            lut = value
        } else {
            lut = nil
        }

        try self.init(wecE: enabled, wecCon: number("wec_con"), wecBrs: number("wec_brs"),
                      wecSa: number("wec_sa"), wecHue: number("wec_hue"), wccV: lut,
                      wccAmt: number("wcc_amt"))
    }
}
#endif
