import Foundation

public enum WPEParityTextDepthTest: Sendable {
    case disabled
    case enabled
}

public enum WPEParityTextAnchor: Sendable {
    case none
    case center
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
    case topLeft
}

/// A WPE 2.8.42 text layer as its field table (FUN_140258ca0) reads it from a user-resolved scene object.
/// Origin, scale, angles and parent come from the scene state; only the other base fields the text draw reads are here.
public struct WPEParityTextObject: Equatable, Sendable {
    public var id: String
    public var color = SIMD3<Float>(1, 1, 1)
    public var alpha: Float = 1
    public var brightness: Float = 1
    public var colorBlendMode = 0
    public var visible = true

    public var text = ""
    public var font = "systemfont_arial"
    /// Unclamped; the font chain clamps it to [1, 256].
    public var pointSize: Float = 32
    public var padding = SIMD2<Float>(32, 32)
    public var spacing = SIMD2<Float>.zero
    public var maxWidth: Float = 500
    public var maxRows = 1
    /// The +0x594 bits.
    public var opaqueBackground = false
    public var limitWidth = false
    public var limitRows = false
    public var limitUseEllipsis = false
    public var blockAlign = false
    public var backgroundColor = SIMD3<Float>.zero
    public var backgroundBrightness: Float = 1
    /// The +0x518 bits; any of them switches the glyphs to the MSDF atlas.
    public var msdf = false
    public var outline = false
    public var blur = false
    public var dropShadow = false
    public var outlineThickness: Float = 4
    public var outlineColor = SIMD3<Float>.zero
    public var blurSize: Float = 6
    public var dropShadowSize: Float = 6
    public var dropShadowOpacity: Float = 1
    public var dropShadowColor = SIMD3<Float>.zero
    public var dropShadowOffset = SIMD2<Float>(4, 4)
    public var depthTest = WPEParityTextDepthTest.enabled
    public var horizontalAlign = WPEParityTextHorizontalAlign.center
    public var verticalAlign = WPEParityTextVerticalAlign.center
    public var anchor = WPEParityTextAnchor.none

    public init(json: WPESceneJSONValue) {
        let field = WPEParityTextField(json)
        id = field.id
        field.read("color", into: &color)
        field.read("alpha", into: &alpha)
        field.read("brightness", into: &brightness)
        field.read("colorBlendMode", into: &colorBlendMode)
        field.read("visible", into: &visible)

        field.read("text", into: &text)
        field.read("font", into: &font)
        field.read("pointsize", into: &pointSize)
        field.read("padding", into: &padding)
        field.read("spacing", into: &spacing)
        field.read("maxwidth", into: &maxWidth)
        field.read("maxrows", into: &maxRows)
        field.read("opaquebackground", into: &opaqueBackground)
        field.read("limitwidth", into: &limitWidth)
        field.read("limitrows", into: &limitRows)
        field.read("limituseellipsis", into: &limitUseEllipsis)
        field.read("blockalign", into: &blockAlign)
        field.read("backgroundcolor", into: &backgroundColor)
        field.read("backgroundbrightness", into: &backgroundBrightness)
        field.read("msdf", into: &msdf)
        field.read("outline", into: &outline)
        field.read("blur", into: &blur)
        field.read("dropshadow", into: &dropShadow)
        field.read("outlinethickness", into: &outlineThickness)
        field.read("outlinecolor", into: &outlineColor)
        field.read("blursize", into: &blurSize)
        field.read("dropshadowsize", into: &dropShadowSize)
        field.read("dropshadowopacity", into: &dropShadowOpacity)
        field.read("dropshadowcolor", into: &dropShadowColor)
        field.read("dropshadowoffset", into: &dropShadowOffset)
        field.read("depthtest", into: &depthTest, table: [("disabled", .disabled), ("enabled", .enabled)])
        field.read("horizontalalign", into: &horizontalAlign, table: [("left", .left), ("center", .center),
                                                                      ("right", .right)])
        field.read("verticalalign", into: &verticalAlign, table: [("center", .center), ("top", .top),
                                                                  ("bottom", .bottom)])
        field.read("anchor", into: &anchor, table: [
            ("none", .none), ("center", .center), ("top", .top), ("topright", .topRight), ("right", .right),
            ("bottomright", .bottomRight), ("bottom", .bottom), ("bottomleft", .bottomLeft), ("left", .left),
            ("topleft", .topLeft),
        ])
    }

    /// The text objects of `document` in paint order, classified as the scene parser does.
    public static func textObjects(in document: WPESceneDocument) -> [WPEParityTextObject] {
        document.resolvedObjectsJSON.filter(isTextObject).map(WPEParityTextObject.init(json:))
    }

    static func isTextObject(_ entry: WPESceneJSONValue) -> Bool {
        guard case let .object(fields) = entry else { return false }
        if case let .string(type)? = fields["type"], !type.isEmpty {
            return type.lowercased() == "text"
        }
        func has(_ key: String) -> Bool {
            fields[key].map { $0 != .null } ?? false
        }
        let isShapeQuad = if case let .string(shape)? = fields["shape"] {
            shape.lowercased() == "quad"
        } else {
            false
        }
        return has("text") && !has("image") && !has("model") && !isShapeQuad && !has("sound") && !has("particle")
    }

    /// bit4 (1401e6f50.c:24-29): composited through effectpassthrough.
    private var composesThroughPassthrough: Bool {
        colorBlendMode != 0 && colorBlendMode != 31
    }

    private var usesGlyphEffects: Bool {
        msdf || outline || blur || dropShadow
    }

    public func layoutInput(effectCount: Int) -> WPEParityTextLayoutInput {
        WPEParityTextLayoutInput(
            text: text,
            fontPath: font,
            pointSize: pointSize,
            padding: padding,
            spacing: spacing,
            maxWidth: limitWidth ? maxWidth : 0,
            maxRows: maxRows,
            limitRows: limitRows && maxRows != 0,
            limitUseEllipsis: limitUseEllipsis,
            blockAlign: blockAlign,
            horizontalAlign: horizontalAlign,
            verticalAlign: verticalAlign,
            appliesPadding: effectCount >= 1 || composesThroughPassthrough || opaqueBackground
        )
    }

    /// FUN_140256f20's dirty check (:46-85): only these fields rebuild the mesh.
    public func needsRebuild(from previous: WPEParityTextObject) -> Bool {
        text != previous.text
            || pointSize != previous.pointSize
            || font != previous.font
            || opaqueBackground != previous.opaqueBackground
            || limitWidth != previous.limitWidth
            || limitRows != previous.limitRows
            || limitUseEllipsis != previous.limitUseEllipsis
            || blockAlign != previous.blockAlign
            || horizontalAlign != previous.horizontalAlign
            || verticalAlign != previous.verticalAlign
            || padding != previous.padding
            || spacing != previous.spacing
            || maxWidth != previous.maxWidth
            || maxRows != previous.maxRows
            || depthTest != previous.depthTest
            || usesGlyphEffects != previous.usesGlyphEffects
    }
}

/// WPE's per-type field parsers. A value of the wrong type leaves the field unchanged; an object reads its
/// `value` (bindings are already resolved), except for enums, whose deserialisers never bind.
private struct WPEParityTextField {
    let fields: [String: WPESceneJSONValue]

    init(_ json: WPESceneJSONValue) {
        if case let .object(fields) = json {
            self.fields = fields
        } else {
            fields = [:]
        }
    }

    var id: String {
        switch fields["id"] {
        case let .string(id)?: id
        case let .number(id)?: Int(exactly: id).map(String.init) ?? String(id)
        default: ""
        }
    }

    /// The value itself, or for an object its `value`.
    private func lookup(_ key: String) -> WPESceneJSONValue? {
        if case let .object(bound)? = fields[key] {
            return bound["value"]
        }
        return fields[key]
    }

    /// 1401a4b00: int, uint and real.
    func read(_ key: String, into target: inout Float) {
        if case let .number(value)? = lookup(key) {
            target = Float(value)
        }
    }

    /// 1401a4930: reals truncate.
    func read(_ key: String, into target: inout Int) {
        if case let .number(value)? = lookup(key) {
            target = Int32(exactly: value.rounded(.towardZero)).map(Int.init) ?? Int(Int32.min)
        }
    }

    func read(_ key: String, into target: inout Bool) {
        if case let .bool(value)? = lookup(key) {
            target = value
        }
    }

    func read(_ key: String, into target: inout String) {
        if case let .string(value)? = lookup(key) {
            target = value
        }
    }

    /// 1401a3fc0: a number fills both parts.
    func read(_ key: String, into target: inout SIMD2<Float>) {
        if let parts = lookup(key).flatMap({ Self.parts($0, count: 2) }) {
            target = SIMD2(parts[0], parts[1])
        }
    }

    /// 1401a4230: a number fills all three parts.
    func read(_ key: String, into target: inout SIMD3<Float>) {
        if let parts = lookup(key).flatMap({ Self.parts($0, count: 3) }) {
            target = SIMD3(parts[0], parts[1], parts[2])
        }
    }

    /// 14025b0e0/b450/b7c0/bb30: an exact name match, otherwise (unknown or non-string) the table's first entry.
    func read<Value>(_ key: String, into target: inout Value, table: [(String, Value)]) {
        guard let value = fields[key] else { return }
        let name = if case let .string(name) = value {
            name
        } else {
            ""
        }
        target = table.first { $0.0 == name }?.1 ?? table[0].1
    }

    /// atof on each part; the next part starts after the following run of spaces, and a missing part reads 0.
    private static func parts(_ value: WPESceneJSONValue, count: Int) -> [Float]? {
        switch value {
        case let .number(number):
            return Array(repeating: Float(number), count: count)
        case let .string(string):
            let bytes = Array(string.utf8CString)
            var parts = [Float](repeating: 0, count: count)
            var cursor = 0
            for index in parts.indices {
                if index > 0 {
                    guard let space = bytes[cursor...].firstIndex(of: 0x20) else { break }
                    cursor = bytes[space...].firstIndex { $0 != 0x20 } ?? cursor
                }
                parts[index] = Float(atof(Array(bytes[cursor...])))
            }
            return parts
        default:
            return nil
        }
    }
}
