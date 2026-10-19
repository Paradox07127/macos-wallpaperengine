/// Authored program bindings shared by parity compilation and shader preflight.
public struct WPERenderUserTextureBindings: Equatable, Sendable {
    public let material: [WPESceneUserTextureBinding]
    public let pass: [WPESceneUserTextureBinding]
    public let override: [WPESceneUserTextureBinding]

    public init(
        material: [WPESceneUserTextureBinding] = [],
        pass: [WPESceneUserTextureBinding] = [],
        override: [WPESceneUserTextureBinding] = []
    ) {
        self.material = material
        self.pass = pass
        self.override = override
    }

    public static let empty = WPERenderUserTextureBindings()

    public var isEmpty: Bool {
        material.isEmpty && pass.isEmpty && override.isEmpty
    }
}

public struct WPERenderEffectPassIdentity: Equatable, Sendable {
    public let stableEffectID: String
    public let stablePassID: String
    public let objectID: String
    public let authoredEffectID: String
    public let authoredEffectPath: String
    public let effectPassIndex: Int
    public let authoredOverrideID: Int?

    public init(
        objectID: String,
        authoredEffectID: String,
        authoredEffectPath: String,
        effectPassIndex: Int,
        authoredOverrideID: Int?
    ) {
        self.objectID = objectID
        self.authoredEffectID = authoredEffectID
        self.authoredEffectPath = authoredEffectPath
        self.effectPassIndex = effectPassIndex
        self.authoredOverrideID = authoredOverrideID
        stableEffectID = "\(objectID):effect:\(authoredEffectID)"
        stablePassID = "\(objectID):effect:\(authoredEffectID):pass:\(effectPassIndex)"
    }
}

public enum WPESceneAliasName {
    public static let fullFrameBuffer = "_rt_FullFrameBuffer"
}
