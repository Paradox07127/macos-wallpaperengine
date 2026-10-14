/// One condition-accepted effect file pass, in native record order. Commands and unresolved materials still
/// occupy a record; only a resolved material has a constant owner. The file index selects scene overrides.
public struct WPEParityEffectPassRecord: Sendable, Equatable {
    public let filePassIndex: Int
    public let materialPass: WPEParityMaterialPassKey?
    /// Authored path, including unresolved materials and material-bearing commands; no path normalization.
    public let materialPath: String?

    public init(filePassIndex: Int, materialPass: WPEParityMaterialPassKey?, materialPath: String? = nil) {
        self.filePassIndex = filePassIndex
        self.materialPass = materialPass
        self.materialPath = materialPath
    }
}
