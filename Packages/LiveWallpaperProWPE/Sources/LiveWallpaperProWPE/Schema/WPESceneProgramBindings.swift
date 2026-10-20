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

public enum WPESceneAliasName {
    public static let fullFrameBuffer = "_rt_FullFrameBuffer"
}
