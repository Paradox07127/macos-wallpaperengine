/// One condition-accepted effect file pass, in native record order. Commands and unresolved materials still
/// occupy a record; only a resolved material has a constant owner. The file index selects scene overrides.
public struct WPEParityEffectPassRecord: Sendable, Equatable {
    public let filePassIndex: Int
    public let materialPass: WPEParityMaterialPassKey?

    public init(filePassIndex: Int, materialPass: WPEParityMaterialPassKey?) {
        self.filePassIndex = filePassIndex
        self.materialPass = materialPass
    }
}
