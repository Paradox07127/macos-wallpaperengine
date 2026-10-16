/// One sub-mesh of a `.mdl` model object and the material its MDLM record names; FUN_1402222a0 binds that material
/// (FUN_140155fc0), draws the mesh and unbinds, so each sub-mesh carries its own state.
public struct WPEParitySceneModelMesh: Hashable, Sendable {
    public var material: WPEParitySceneMaterialSource?
    public var shader: String
    public var blend: WPEParitySceneBlend
    public var materialState: WPEParitySceneMaterialState

    public init(material: WPEParitySceneMaterialSource?, shader: String, blend: WPEParitySceneBlend,
                materialState: WPEParitySceneMaterialState = WPEParitySceneMaterialState()) {
        self.material = material
        self.shader = shader
        self.blend = blend
        self.materialState = materialState
    }
}

/// A model object's sub-meshes in file order, the order FUN_1402222a0 draws them.
public struct WPEParitySceneModel: Hashable, Sendable {
    public var meshes: [WPEParitySceneModelMesh]
    /// Object flag 0x800 (castshadow).
    public var castsShadow: Bool

    public init(meshes: [WPEParitySceneModelMesh], castsShadow: Bool = false) {
        self.meshes = meshes
        self.castsShadow = castsShadow
    }

    /// The frame pass that draws sub-mesh `mesh` of `objectID`.
    public static func pass(objectID: String, mesh: Int) -> WPEPassIdentity {
        WPEPassIdentity("\(objectID)/mesh\(mesh)")
    }

    /// The frame pass that draws sub-mesh `mesh` of `objectID` into the shadow atlas.
    public static func shadowPass(objectID: String, mesh: Int) -> WPEPassIdentity {
        WPEPassIdentity("\(objectID)/shadow/mesh\(mesh)")
    }

    /// The sub-mesh index `pass` (a scene or shadow pass) draws, or nil when it is no model pass of `objectID`.
    public static func meshIndex(_ pass: WPEPassIdentity, objectID: String) -> Int? {
        for prefix in ["\(objectID)/mesh", "\(objectID)/shadow/mesh"] where pass.rawValue.hasPrefix(prefix) {
            return Int(pass.rawValue.dropFirst(prefix.count))
        }
        return nil
    }
}
