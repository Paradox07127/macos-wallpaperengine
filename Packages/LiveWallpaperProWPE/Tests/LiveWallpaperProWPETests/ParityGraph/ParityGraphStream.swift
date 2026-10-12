import LiveWallpaperProWPE

/// Builders for synthetic D3D11-style operation streams.
enum ParityGraphStream {
    static let black = WPEClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    static func transient(_ id: WPEResourceID, mips: Int = 1, samples: Int = 1,
                          format: String = "rgba8unorm") -> WPELogicalResource {
        WPELogicalResource(id: id, width: 64, height: 64, format: format, mipCount: mips, sampleCount: samples,
                           lifetime: .frameTransient)
    }

    static func persistent(_ id: WPEResourceID, format: String = "rgba8unorm") -> WPELogicalResource {
        WPELogicalResource(id: id, width: 64, height: 64, format: format, lifetime: .persistent)
    }

    static func bind(_ colors: WPEResourceID..., depth: WPEResourceID? = nil) -> WPERenderOperation {
        WPERenderOperation(pass: "bind", .setTargets(color: colors.map { WPETextureView($0, mips: 0 ..< 1) },
                                                     depth: depth.map { WPETextureView($0) }))
    }

    static func clear(_ id: WPEResourceID) -> WPERenderOperation {
        WPERenderOperation(pass: "clear", .clearColor(WPETextureView(id, mips: 0 ..< 1), black))
    }

    static func clearDepth(_ id: WPEResourceID) -> WPERenderOperation {
        WPERenderOperation(pass: "clearDepth", .clearDepth(WPETextureView(id), depth: 0))
    }

    static func draw(sampling: [WPEResourceID] = [], readsDestination: Bool = false, overwrites: Bool = false,
                     depthTest: Bool = false, depthWrite: Bool = false) -> WPERenderOperation {
        WPERenderOperation(pass: "draw", .draw(WPEDrawOperation(
            reads: sampling.map { WPETextureView($0) }, readsDestination: readsDestination,
            overwritesTargets: overwrites, depthTest: depthTest, depthWrite: depthWrite
        )))
    }

    static func copy(_ source: WPEResourceID, _ destination: WPEResourceID) -> WPERenderOperation {
        WPERenderOperation(pass: "copy", .copy(source: source, destination: destination))
    }

    static func generateMips(_ id: WPEResourceID) -> WPERenderOperation {
        WPERenderOperation(pass: "mips", .generateMips(id))
    }

    static func resolve(_ source: WPEResourceID, _ destination: WPEResourceID) -> WPERenderOperation {
        WPERenderOperation(pass: "resolve", .resolve(source: source, destination: destination))
    }

    static func compile(_ resources: [WPELogicalResource],
                        _ operations: [WPERenderOperation]) throws -> WPECompiledRenderGraph {
        try WPERenderGraphCompiler.compile(resources: resources, operations: operations)
    }

    static func depends(_ graph: WPECompiledRenderGraph, _ consumer: Int, on producer: Int, _ resource: WPEResourceID,
                        mip: Int = 0, _ hazard: WPEStepDependency.Hazard) -> Bool {
        graph.dependencies.contains {
            $0.producer == producer && $0.consumer == consumer && $0.hazard == hazard
                && $0.subresource == WPESubresource(resource, mip: mip)
        }
    }
}
