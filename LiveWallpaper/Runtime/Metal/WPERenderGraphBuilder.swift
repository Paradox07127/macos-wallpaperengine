#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import simd

private func isImplicitFBOTextureName(_ name: String) -> Bool {
    name.hasPrefix("_") && !name.hasPrefix("__")
}

struct WPERenderGraphBuilder: Sendable {
    private let resolver: WPEMultiRootResourceResolver

    /// Uses hierarchy-composed MDAT bind points for split-puppet attachments.
    /// Disable with `defaults write com.loomscreen.pro WPEPuppetAttachmentBindAnchor -bool NO`.
    private static var useAttachmentBindAnchor: Bool {
        WPEMetalRenderExecutor.puppetDefaultsFlagOptional("WPEPuppetAttachmentBindAnchor") ?? true
    }

    /// Forwards the executor's frozen `puppetClipCompositeEnabled` so builder and
    /// executor cannot disagree (mask injected but never composited, or vice versa).
    private static let puppetClipCompositeEnabled = WPEMetalRenderExecutor.puppetClipCompositeEnabled

    init(
        cacheRootURL: URL,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.resolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
    }

    init(
        primaryProvider: any WPESceneAssetProvider,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.resolver = WPEMultiRootResourceResolver(
            primaryProvider: primaryProvider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
    }

    func build(document: WPESceneDocument) throws -> WPERenderGraph {
        var objectByID: [String: WPESceneImageObject] = [:]
        var originalIndexByID: [String: Int] = [:]
        for (index, object) in document.imageObjects.enumerated() where objectByID[object.id] == nil {
            objectByID[object.id] = object
            // Use the GLOBAL scene paint index so layer tie-breaks stay consistent with where
            // particles interleave; fall back to the image-filtered index when absent.
            originalIndexByID[object.id] = document.objectPaintOrder[object.id] ?? index
        }

        let liveVisibilityIDs = Self.userToggleableVisibilityIDs(in: document)
            .union(Self.layerScriptControlledVisibilityIDs(in: document))
        let dynamicCreatedLayerTemplateIDs = Self.createLayerImageTemplateIDs(in: document)
        // Drop particle-only compose wrappers (3462491575), empty compose
        // hotspots, and identity fullscreen/project passthroughs (3470764447).
        let noOpFullFrameDrops = Self.noOpFullFramePassthroughIDs(in: document)
        let composeWrappersToDrop = Self.particleOnlyComposeWrapperIDs(
            in: document
        ).union(Self.emptyComposeWrapperIDs(in: document, objectByID: objectByID))
         .union(noOpFullFrameDrops)
        let visibleLayerIDs = Set(document.imageObjects
            .filter { !composeWrappersToDrop.contains($0.id) }
            .filter { !Self.hasHiddenAncestor($0, objectByID: objectByID, liveVisibilityIDs: liveVisibilityIDs) }
            .filter {
                Self.compositesToScene($0, liveVisibilityIDs: liveVisibilityIDs)
                    || Self.hasLiveToggleableHiddenAncestor($0, objectByID: objectByID, liveVisibilityIDs: liveVisibilityIDs)
            }
            .map(\.id))
        var layerIDsToBuild = visibleLayerIDs.union(dynamicCreatedLayerTemplateIDs)
        var pendingIDs = Array(layerIDsToBuild)
        var layerIDsRequiredAsComposite = Set<String>()

        while let id = pendingIDs.popLast(), let object = objectByID[id] {
            for dependencyID in Self.referencedLayerIDs(in: object) where objectByID[dependencyID] != nil {
                layerIDsRequiredAsComposite.insert(dependencyID)
                if layerIDsToBuild.insert(dependencyID).inserted {
                    pendingIDs.append(dependencyID)
                }
            }
        }

        let orderedLayerIDs = Self.topologicallyOrderedLayerIDs(
            layerIDsToBuild,
            objectByID: objectByID,
            originalIndexByID: originalIndexByID
        )

        let rawLayers = try orderedLayerIDs
            .compactMap { objectByID[$0] }
            .map { object in
                try buildLayer(
                    object: object,
                    finalUntargetedPassToScene: visibleLayerIDs.contains(object.id),
                    preserveFinalCompositeForScene: layerIDsRequiredAsComposite.contains(object.id)
                        || WPETextLayerSynthesis.isOffscreenPath(object.imageRelativePath),
                    sortIndex: document.objectPaintOrder[object.id] ?? 0
                )
            }
        let parallaxAligned = Self.propagatingParallaxDepthThroughParents(
            rawLayers,
            objectParentByID: document.objectParentByID,
            hostDepthByObjectID: Self.authoredParallaxDepthByObjectID(document)
        )
        let attachmentAligned = applyAttachmentAnchorOffsets(to: parallaxAligned)
        // Load-time UTF-8 nativization; last stop before the per-frame path.
        return WPERenderGraph(layers: applyComposelayerGroups(
            to: attachmentAligned,
            objectParentByID: document.objectParentByID
        )).nativized()
    }

    private func applyComposelayerGroups(
        to layers: [WPERenderLayer],
        objectParentByID: [String: String]
    ) -> [WPERenderLayer] {
        let layerIDs = Set(layers.map(\.objectID))
        let parentByID = objectParentByID
        let candidateGroups = Set(layers.compactMap { layer in
            Self.isComposelayerModelPath(layer.imagePath) ? layer.objectID : nil
        })
        guard !candidateGroups.isEmpty else { return layers }

        var groupIDs = Set<String>()
        for layerID in layerIDs {
            var current = parentByID[layerID]
            var seen: Set<String> = []
            while let id = current, seen.insert(id).inserted {
                if candidateGroups.contains(id) {
                    groupIDs.insert(id)
                    break
                }
                current = parentByID[id]
            }
        }
        guard !groupIDs.isEmpty else { return layers }

        let layersByID = Dictionary(layers.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
        var nearestGroupByLayer: [String: String] = [:]
        for layer in layers {
            // No in-graph descendant: empty composite, and rerouting as a child
            // writes an ancestor buffer that does not exist yet (3554161528).
            if candidateGroups.contains(layer.objectID), !groupIDs.contains(layer.objectID) {
                continue
            }
            if let groupID = nearestComposelayerGroup(
                for: layer.objectID,
                parentByID: parentByID,
                groupIDs: groupIDs
            ) {
                nearestGroupByLayer[layer.objectID] = groupID
            }
        }
        guard !nearestGroupByLayer.isEmpty else { return layers }

        let transformed = layers.map { layer -> WPERenderLayer in
            if groupIDs.contains(layer.objectID) {
                let groupTarget = WPERenderTargetNames.LayerGroup.make(objectID: layer.objectID)
                let groupSize = layer.geometry.size
                let fbo = WPERenderFBO(
                    name: groupTarget,
                    scale: 1,
                    format: "rgba8888",
                    pixelSize: groupSize
                )
                var localFBOs = layer.localFBOs
                if !localFBOs.contains(where: { $0.name == groupTarget }) {
                    localFBOs.append(fbo)
                }
                // `materialRespectingCopyBackground` may have already rewritten
                // `_rt_FullFrameBuffer` to `.previous`; map both to the group
                // buffer or a scene-targeting pass paints PiP (3470764447 layer 249).
                let composited = layer
                    .replacingLocalFBOs(localFBOs)
                    .replacingPasses(layer.passes.enumerated().map { index, pass in
                        let aliased = pass.replacingSceneAliasReferences(with: .fbo(groupTarget))
                        return index == 0
                            ? aliased.replacingPreviousReferences(with: .fbo(groupTarget))
                            : aliased
                    })
                    .withGroupCompositeSource(groupTarget)

                guard let ancestorID = nearestGroupByLayer[layer.objectID],
                      let ancestor = layersByID[ancestorID] else {
                    return composited
                }
                return reroutingSceneOutput(
                    of: composited,
                    into: ancestor,
                    layerGeometry: layer.geometry
                )
            }

            guard let groupID = nearestGroupByLayer[layer.objectID],
                  let group = layersByID[groupID] else {
                return layer
            }
            return reroutingSceneOutput(of: layer, into: group, layerGeometry: layer.geometry)
        }

        return Self.reorderedForComposelayerGroups(
            transformed,
            groupIDs: groupIDs,
            nearestGroupByLayer: nearestGroupByLayer
        )
    }

    private func reroutingSceneOutput(
        of layer: WPERenderLayer,
        into group: WPERenderLayer,
        layerGeometry: WPERenderLayerGeometry
    ) -> WPERenderLayer {
        let groupTarget = WPERenderTargetNames.LayerGroup.make(objectID: group.objectID)
        let groupGeometry = Self.groupLocalGeometry(for: layerGeometry, in: group.geometry)
        return layer
            .replacingPasses(layer.passes.map { pass in
                pass.target == .scene ? pass.replacingTarget(.fbo(name: groupTarget)) : pass
            })
            .withGroupRenderTarget(groupTarget, localGeometry: groupGeometry)
    }

    private func nearestComposelayerGroup(
        for objectID: String,
        parentByID: [String: String],
        groupIDs: Set<String>
    ) -> String? {
        var current = parentByID[objectID]
        var seen: Set<String> = []
        while let id = current, seen.insert(id).inserted {
            if groupIDs.contains(id) { return id }
            current = parentByID[id]
        }
        return nil
    }

    private static func reorderedForComposelayerGroups(
        _ layers: [WPERenderLayer],
        groupIDs: Set<String>,
        nearestGroupByLayer: [String: String]
    ) -> [WPERenderLayer] {
        var lastDescendantIndexByGroup: [String: Int] = [:]
        for (index, layer) in layers.enumerated() {
            guard let groupID = nearestGroupByLayer[layer.objectID] else { continue }
            lastDescendantIndexByGroup[groupID] = max(lastDescendantIndexByGroup[groupID] ?? index, index)
        }
        let groupLayerByID = Dictionary(
            layers.filter { groupIDs.contains($0.objectID) }.map { ($0.objectID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var pendingGroups = groupIDs
        var emitted: [WPERenderLayer] = []

        for (index, layer) in layers.enumerated() {
            if groupIDs.contains(layer.objectID) {
                continue
            }
            emitted.append(layer)
            guard let groupID = nearestGroupByLayer[layer.objectID],
                  lastDescendantIndexByGroup[groupID] == index,
                  pendingGroups.remove(groupID) != nil,
                  let groupLayer = groupLayerByID[groupID] else {
                continue
            }
            emitted.append(groupLayer)
        }

        // Groups left pending here had a group as their own last descendant (skipped
        // inline above); emit deeper groups first so an inner buffer renders before
        // the ancestor group that samples it.
        var depthByGroup: [String: Int] = [:]
        func nestingDepth(_ id: String) -> Int {
            if let cached = depthByGroup[id] { return cached }
            var depth = 0
            var current = nearestGroupByLayer[id]
            var seen: Set<String> = []
            while let ancestor = current, seen.insert(ancestor).inserted {
                depth += 1
                current = nearestGroupByLayer[ancestor]
            }
            depthByGroup[id] = depth
            return depth
        }
        let trailing = layers.enumerated()
            .filter { pendingGroups.contains($0.element.objectID) }
            .sorted { lhs, rhs in
                let lhsDepth = nestingDepth(lhs.element.objectID)
                let rhsDepth = nestingDepth(rhs.element.objectID)
                return lhsDepth != rhsDepth ? lhsDepth > rhsDepth : lhs.offset < rhs.offset
            }
        for entry in trailing where pendingGroups.remove(entry.element.objectID) != nil {
            emitted.append(entry.element)
        }
        return emitted
    }

    private static func groupLocalGeometry(
        for child: WPERenderLayerGeometry,
        in group: WPERenderLayerGeometry
    ) -> WPERenderLayerGeometry {
        let targetSize = group.size ?? child.size ?? CGSize(width: 1, height: 1)
        let delta = SIMD2<Double>(
            child.origin.x - group.origin.x,
            child.origin.y - group.origin.y
        )
        let cosine = cos(-group.angles.z)
        let sine = sin(-group.angles.z)
        let unrotated = SIMD2<Double>(
            delta.x * cosine - delta.y * sine,
            delta.x * sine + delta.y * cosine
        )
        let scaleX = abs(group.scale.x) > 0.0001 ? group.scale.x : 1
        let scaleY = abs(group.scale.y) > 0.0001 ? group.scale.y : 1
        let localOrigin = SIMD3<Double>(
            unrotated.x / scaleX + Double(targetSize.width) * 0.5,
            unrotated.y / scaleY + Double(targetSize.height) * 0.5,
            child.origin.z - group.origin.z
        )
        return WPERenderLayerGeometry(
            origin: localOrigin,
            scale: SIMD3<Double>(
                child.scale.x / scaleX,
                child.scale.y / scaleY,
                child.scale.z / (abs(group.scale.z) > 0.0001 ? group.scale.z : 1)
            ),
            angles: child.angles - group.angles,
            alignment: child.alignment,
            size: child.size,
            puppetMeshCenter: child.puppetMeshCenter,
            alpha: child.alpha,
            alphaAnimation: child.alphaAnimation,
            color: child.color,
            colorAnimation: child.colorAnimation,
            brightness: child.brightness
        )
    }

    /// Authored depths for every object, groups included. Absent-key is zero,
    /// and Windows ignores an authored child value when an ancestor exists.
    static func authoredParallaxDepthByObjectID(
        _ document: WPESceneDocument
    ) -> [String: SIMD2<Double>] {
        var depths: [String: SIMD2<Double>] = [:]
        for object in document.imageObjects { depths[object.id] = object.parallaxDepth }
        for object in document.textObjects { depths[object.id] = object.parallaxDepth }
        for object in document.particleObjects { depths[object.id] = object.parallaxDepth }
        for object in document.transformHostObjects { depths[object.id] = object.parallaxDepth }
        return depths
    }

    /// Windows pin: 3719111841 parent/child MVPs share one vector; 3448877775
    /// clock texts all shift (5.31, 7.97) px = top GROUP -0.408 (5.31/11.97 =
    /// 0.408/0.92 vs -0.92 bg) while leaves author -0.7 / 0 / 1.0, ignored.
    /// Non-zero, not topmost: a key-less root parses to zero, and zeroing 93
    /// corpus objects under those roots (3151551777, 3351072238) is a regression.
    static func parallaxAnchorNodeID(
        of id: String,
        parentByID: [String: String],
        depthByID: [String: SIMD2<Double>]
    ) -> String {
        var current = id
        var anchor = id
        var seen: Set<String> = []
        while seen.insert(current).inserted {
            if let depth = depthByID[current], depth != SIMD2<Double>(0, 0) {
                anchor = current
            }
            guard let parent = parentByID[current], depthByID[parent] != nil else { break }
            current = parent
        }
        return anchor
    }

    static func propagatingParallaxDepthThroughParents(
        _ layers: [WPERenderLayer],
        objectParentByID: [String: String] = [:],
        hostDepthByObjectID: [String: SIMD2<Double>] = [:]
    ) -> [WPERenderLayer] {
        guard layers.contains(where: { $0.parentObjectID != nil }) else { return layers }
        var depthByID = hostDepthByObjectID
        for layer in layers where depthByID[layer.objectID] == nil {
            depthByID[layer.objectID] = layer.parallaxDepth
        }
        var parentByID = objectParentByID
        if parentByID.isEmpty {
            parentByID = Dictionary(
                layers.compactMap { layer in layer.parentObjectID.map { (layer.objectID, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return layers.map { layer in
            guard layer.parentObjectID != nil else { return layer }
            let anchor = Self.parallaxAnchorNodeID(
                of: layer.objectID, parentByID: parentByID, depthByID: depthByID
            )
            guard anchor != layer.objectID, let inherited = depthByID[anchor] else { return layer }
            return inherited == layer.parallaxDepth ? layer : layer.withParallaxDepth(inherited)
        }
    }

    private func applyAttachmentAnchorOffsets(to layers: [WPERenderLayer]) -> [WPERenderLayer] {
        guard layers.contains(where: { $0.attachment != nil && $0.parentObjectID != nil }) else {
            return layers
        }
        let layersByID = Dictionary(layers.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
        var modelCache: [String: WPEPuppetModel?] = [:]
        func parentModel(forPuppetPath path: String) -> WPEPuppetModel? {
            if let cached = modelCache[path] { return cached }
            let model = (try? resolver.data(relativePath: path)).flatMap { try? WPEMdlParser.parse(data: $0) }
            modelCache[path] = model
            return model
        }
        return layers.map { layer in
            guard let attachmentName = layer.attachment,
                  let parentID = layer.parentObjectID,
                  let parent = layersByID[parentID],
                  let puppetPath = parent.puppetPath,
                  let model = parentModel(forPuppetPath: puppetPath),
                  let offset = Self.staticAttachmentOffset(
                      attachmentName: attachmentName,
                      parentGeometry: parent.geometry,
                      parentModel: model
                  ) else {
                return layer
            }
            return layer.replacingGeometryOrigin(addingSceneOffset: offset)
        }
    }

    private static func staticAttachmentOffset(
        attachmentName: String,
        parentGeometry: WPERenderLayerGeometry,
        parentModel: WPEPuppetModel
    ) -> SIMD3<Double>? {
        guard let attachment = parentModel.attachments.first(where: { $0.name == attachmentName }) else {
            return nil
        }
        // The hierarchy-composed bind-world transform plus MDAT matrix locates the joint;
        // the skin-weighted centroid is only a fallback when bind data is unavailable.
        let anchorPoint: SIMD2<Double>
        // Character-sheet puppets (MDLV0019/0020) MUST use the bind-anchor pivot: their mesh vertices
        // are the exploded source sheet, so the skin-weighted centroid fallback is meaningless. The
        // assembled anchor comes from the frame-0 pose inside `assembledBindWorldByBone`. Pre-assembled
        // puppets use the default-on flag; `-bool NO` restores the centroid path.
        let isCharacterSheet = parentModel.version >= 19 && parentModel.version <= 20
        if useAttachmentBindAnchor || isCharacterSheet,
           let bindAnchor = bindAnchorPoint(for: attachment, model: parentModel) {
            anchorPoint = bindAnchor
        } else if let joint = skinnedJoint(of: attachment.boneIndex, in: parentModel.meshes) {
            anchorPoint = joint
        } else {
            return nil
        }
        // The puppet mesh draws model→scene with no Y flip, so map the anchor with a +Y sign; subtract
        // the parent mesh center so the offset is in the same composite frame the vertex shader uses.
        let local = SIMD2<Double>(
            abs(parentGeometry.scale.x) * (anchorPoint.x - parentGeometry.puppetMeshCenter.x),
            abs(parentGeometry.scale.y) * (anchorPoint.y - parentGeometry.puppetMeshCenter.y)
        )
        let cosine = cos(parentGeometry.angles.z)
        let sine = sin(parentGeometry.angles.z)
        guard local.x.isFinite, local.y.isFinite else { return nil }
        return SIMD3<Double>(
            cosine * local.x - sine * local.y,
            sine * local.x + cosine * local.y,
            0
        )
    }

    private static func skinnedJoint(of boneIndex: Int, in meshes: [WPEPuppetMesh]) -> SIMD2<Double>? {
        var sumX = 0.0
        var sumY = 0.0
        var sumW = 0.0
        for mesh in meshes {
            for vertex in mesh.vertices {
                let indices = vertex.skinBlendIndices
                let weights = vertex.skinBlendWeights
                func accumulate(_ index: Int32, _ weight: Float) {
                    guard Int(index) == boneIndex, weight > 0, weight.isFinite else { return }
                    sumX += Double(weight) * Double(vertex.position.x)
                    sumY += Double(weight) * Double(vertex.position.y)
                    sumW += Double(weight)
                }
                accumulate(indices.x, weights.x)
                accumulate(indices.y, weights.y)
                accumulate(indices.z, weights.z)
                accumulate(indices.w, weights.w)
            }
        }
        guard sumW > 0 else { return nil }
        return SIMD2<Double>(sumX / sumW, sumY / sumW)
    }

    private static func bindAnchorPoint(
        for attachment: WPEPuppetAttachment,
        model: WPEPuppetModel
    ) -> SIMD2<Double>? {
        guard let boneWorld = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(model: model)[attachment.boneIndex] else {
            return nil
        }
        let anchor = boneWorld * attachment.matrix
        let p = anchor.columns.3
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return SIMD2<Double>(Double(p.x), Double(p.y))
    }

    static func compositesToScene(_ object: WPESceneImageObject, liveVisibilityIDs: Set<String>) -> Bool {
        // Alpha-0 base with no alpha animation is a no-op UNLESS a visible
        // effect draws its own content (3719111841 alpha-0 `audioline`).
        let hasVisibleEffect = object.effects.contains { $0.visible }
        if !object.copyBackground,
           isComposelayerModelPath(object.imageRelativePath),
           hasVisibleEffect,
           object.effects.filter(\.visible).allSatisfy(isInputOnlyScrollEffect) {
            return false
        }
        guard object.alpha > 0.001 || object.alphaAnimation != nil || hasVisibleEffect else {
            return false
        }
        return object.visible || liveVisibilityIDs.contains(object.id)
    }

    private static func isInputOnlyScrollEffect(_ effect: WPESceneImageEffect) -> Bool {
        let normalizedFile = effect.fileRelativePath
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        return effect.name.lowercased() == "scroll"
            || normalizedFile.hasSuffix("/scroll/effect.json")
            || normalizedFile.contains("/effects/scroll/effect.json")
    }

    static func hasHiddenAncestor(
        _ object: WPESceneImageObject,
        objectByID: [String: WPESceneImageObject],
        liveVisibilityIDs: Set<String>
    ) -> Bool {
        var seen: Set<String> = []
        var current = object.parentObjectID
        while let id = current, seen.insert(id).inserted, let parent = objectByID[id] {
            if !parent.visible && !liveVisibilityIDs.contains(parent.id) { return true }
            current = parent.parentObjectID
        }
        return false
    }

    static func hasLiveToggleableHiddenAncestor(
        _ object: WPESceneImageObject,
        objectByID: [String: WPESceneImageObject],
        liveVisibilityIDs: Set<String>
    ) -> Bool {
        var seen: Set<String> = []
        var current = object.parentObjectID
        while let id = current, seen.insert(id).inserted, let parent = objectByID[id] {
            if !parent.visible && liveVisibilityIDs.contains(parent.id) { return true }
            current = parent.parentObjectID
        }
        return false
    }

    private static func userToggleableVisibilityIDs(in document: WPESceneDocument) -> Set<String> {
        var ids = Set<String>()
        for bindings in document.propertyBindings.values {
            for binding in bindings
            where binding.kind == .visible && binding.action == .incremental {
                switch binding.target {
                case .imageObject(let id), .textObject(let id):
                    ids.insert(id)
                default:
                    break
                }
            }
        }
        return ids
    }

    /// `getLayer` args are usually variables, so match any script string literal
    /// against a layer name; names never mentioned still prune (3226487183).
    private static func layerScriptControlledVisibilityIDs(in document: WPESceneDocument) -> Set<String> {
        // Script hosts are non-renderable script containers that still drive other
        // layers via getLayer(); mirror createLayerImageTemplateIDs and consult them.
        let scripts = document.imageObjects.compactMap(\.visibleScript)
            + document.scriptHostObjects.map(\.visibleScript)
        guard !scripts.isEmpty else { return [] }
        let combined = scripts.joined(separator: "\n")
        var ids = Set<String>()
        for object in document.imageObjects {
            // Own visible-script objects stay even when authored hidden:
            // 2955378002 seeds 143 calendar sprites `visible:false`.
            if object.visibleScript != nil {
                ids.insert(object.id)
                continue
            }
            let name = object.name
            guard !name.isEmpty else { continue }
            if combined.contains("\"\(name)\"") || combined.contains("'\(name)'") {
                ids.insert(object.id)
            }
        }
        return ids
    }

    private static func createLayerImageTemplateIDs(in document: WPESceneDocument) -> Set<String> {
        let scripts = document.imageObjects.compactMap(\.visibleScript)
            + document.scriptHostObjects.map(\.visibleScript)
        guard !scripts.isEmpty else { return [] }

        var imagePaths = Set<String>()
        for script in scripts where script.contains("createLayer") {
            imagePaths.formUnion(createLayerImagePaths(in: script))
        }
        guard !imagePaths.isEmpty else { return [] }

        return Set(document.imageObjects.compactMap { object in
            imagePaths.contains(object.imageRelativePath) ? object.id : nil
        })
    }

    private static func createLayerImagePaths(in script: String) -> Set<String> {
        let pattern = #"(?:["']image["']|\bimage\b)\s*:\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var paths = Set<String>()
        var searchStart = script.startIndex
        while let createRange = script.range(of: "createLayer", range: searchStart..<script.endIndex) {
            let windowEnd = script.index(createRange.upperBound, offsetBy: 4096, limitedBy: script.endIndex)
                ?? script.endIndex
            let chunk = String(script[createRange.upperBound..<windowEnd])
            let nsRange = NSRange(chunk.startIndex..<chunk.endIndex, in: chunk)
            for match in regex.matches(in: chunk, range: nsRange) where match.numberOfRanges > 1 {
                guard let range = Range(match.range(at: 1), in: chunk) else { continue }
                paths.insert(String(chunk[range]))
            }
            searchStart = createRange.upperBound
        }
        return paths
    }

        /// Hidden-but-scripted effects stay gated: dropping them also drops the
        /// producer that opens the gate (3151551777 `Night (Cycle)` / `shared.shownight`).
        static func scriptVisibilityGate(for effect: WPESceneImageEffect) -> WPEPassVisibilityGate? {
            guard !effect.visible, let script = effect.visibleScript else { return nil }
            return WPEPassVisibilityGate(script: script, initialVisible: effect.visible)
        }

        static func buildsIntoGraph(_ effect: WPESceneImageEffect) -> Bool {
            effect.visible || scriptVisibilityGate(for: effect) != nil
        }

    private static func referencedLayerIDs(in object: WPESceneImageObject) -> Set<String> {
        // Ghost edge: every authored effect is out of the graph, so nothing
        // samples the producer, yet the edge still reorders paint (3151551777
        // triangle-date covered the weekday it "depended" on). No-effect
        // objects keep their edges — the material is the consumer.
        let ghostDependencies = !object.effects.isEmpty
            && !object.effects.contains(where: Self.buildsIntoGraph)
        var ids = ghostDependencies ? [] : Set(object.dependencies)
            for effect in object.effects where Self.buildsIntoGraph(effect) {
            for passOverride in effect.passOverrides {
                for texture in passOverride.textures.values {
                    if let id = WPERenderTargetNames.ImageLayerComposite.layerID(from: texture) {
                        ids.insert(id)
                    }
                }
            }
        }
        return ids
    }

    /// Consumers often author ahead of the producer they sample; first frame
    /// has no named-texture bootstrap, so a late producer is `missingTexture(.fbo)`.
    private static func topologicallyOrderedLayerIDs(
        _ layerIDs: Set<String>,
        objectByID: [String: WPESceneImageObject],
        originalIndexByID: [String: Int]
    ) -> [String] {
        func originalIndex(_ id: String) -> Int {
            originalIndexByID[id] ?? Int.max
        }

        func originalOrder(_ lhs: String, _ rhs: String) -> Bool {
            let left = originalIndex(lhs)
            let right = originalIndex(rhs)
            if left != right { return left < right }
            return lhs < rhs
        }

        let orderedIDs = layerIDs.sorted(by: originalOrder)
        var inDegree = Dictionary(uniqueKeysWithValues: orderedIDs.map { ($0, 0) })
        var dependentsByID: [String: Set<String>] = [:]

        for consumerID in orderedIDs {
            guard let consumer = objectByID[consumerID] else { continue }
            for dependencyID in referencedLayerIDs(in: consumer)
            where dependencyID != consumerID
                && layerIDs.contains(dependencyID)
                && objectByID[dependencyID] != nil {
                if dependentsByID[dependencyID, default: []].insert(consumerID).inserted {
                    inDegree[consumerID, default: 0] += 1
                }
            }
        }

        var ready = orderedIDs.filter { inDegree[$0, default: 0] == 0 }
        var emitted: [String] = []
        var emittedIDs = Set<String>()

        while !ready.isEmpty {
            ready.sort(by: originalOrder)
            let id = ready.removeFirst()
            guard emittedIDs.insert(id).inserted else { continue }
            emitted.append(id)

            let dependents = (dependentsByID[id] ?? []).sorted(by: originalOrder)
            for dependentID in dependents {
                let nextDegree = max((inDegree[dependentID] ?? 0) - 1, 0)
                inDegree[dependentID] = nextDegree
                if nextDegree == 0 {
                    ready.append(dependentID)
                }
            }
        }

        if emitted.count < orderedIDs.count {
            let cyclicRemainder = orderedIDs.filter { !emittedIDs.contains($0) }
            logCompositeDependencyCycle(cyclicRemainder)
            emitted.append(contentsOf: cyclicRemainder)
        }

        return emitted
    }

    private static func logCompositeDependencyCycle(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let detail = ids.joined(separator: ", ")
        let message = "WPE render graph composite dependency cycle; preserving scene order for: \(detail)"
        Logger.warning(message, category: .wpeRender)
        WPESceneDebugArtifacts.shared.appendLog(
            "[graph.cycle] \(message)",
            level: .warning
        )
    }

    private static func isComposelayerModelPath(_ path: String) -> Bool {
        WPEUtilityModelKind.classify(path) == .composeLayer
    }

    private static func particleOnlyComposeWrapperIDs(
        in document: WPESceneDocument
    ) -> Set<String> {
        let composeLayerIDs = Set(
            document.imageObjects
                .filter { isComposelayerModelPath($0.imageRelativePath) }
                .map(\.id)
        )
        guard !composeLayerIDs.isEmpty else { return [] }
        let parentByID = document.objectParentByID
        // ALL compose ancestors (not just the nearest): a particle nested under `outer -> inner`
        // must drop BOTH wrappers, else `outer` survives with no built child and still draws the
        // full-frame passthrough.
        func composeAncestors(of startID: String) -> Set<String> {
            var result: Set<String> = []
            var current = parentByID[startID]
            var seen: Set<String> = []
            while let id = current, seen.insert(id).inserted {
                if composeLayerIDs.contains(id) { result.insert(id) }
                current = parentByID[id]
            }
            return result
        }
        var wrappersWithParticle: Set<String> = []
        for particle in document.particleObjects {
            wrappersWithParticle.formUnion(composeAncestors(of: particle.id))
        }
        guard !wrappersWithParticle.isEmpty else { return [] }
        var wrappersWithImageChild: Set<String> = []
        for image in document.imageObjects where !composeLayerIDs.contains(image.id) {
            wrappersWithImageChild.formUnion(composeAncestors(of: image.id))
        }
        return wrappersWithParticle.subtracting(wrappersWithImageChild)
    }

    private static func emptyComposeWrapperIDs(
        in document: WPESceneDocument,
        objectByID: [String: WPESceneImageObject]
    ) -> Set<String> {
        let composeLayerIDs = Set(
            document.imageObjects
                .filter { isComposelayerModelPath($0.imageRelativePath) }
                .map(\.id)
        )
        guard !composeLayerIDs.isEmpty else { return [] }
        let parentByID = document.objectParentByID
        func composeAncestors(of startID: String) -> Set<String> {
            var result: Set<String> = []
            var current = parentByID[startID]
            var seen: Set<String> = []
            while let id = current, seen.insert(id).inserted {
                if composeLayerIDs.contains(id) { result.insert(id) }
                current = parentByID[id]
            }
            return result
        }
        var nonEmpty: Set<String> = []
        for image in document.imageObjects where !composeLayerIDs.contains(image.id) {
            nonEmpty.formUnion(composeAncestors(of: image.id))
        }
        for id in composeLayerIDs {
            guard let compose = objectByID[id] else { continue }
            if referencedLayerIDs(in: compose).contains(where: { $0 != id && objectByID[$0] != nil }) {
                nonEmpty.insert(id)
            }
        }
        for particle in document.particleObjects {
            nonEmpty.formUnion(composeAncestors(of: particle.id))
        }
        return composeLayerIDs.subtracting(nonEmpty)
    }

    private static func isFullFramePassthroughUtilityPath(_ path: String) -> Bool {
        // Exhaustive switch, NOT array-contains: composelayer must stay excluded
        // (it can become a group/particle wrapper; these two cannot).
        switch WPEUtilityModelKind.classify(path) {
        case .projectLayer, .fullScreenLayer: return true
        case .composeLayer, nil: return false
        }
    }

    /// Identity `_rt_FullFrameBuffer`→scene copy re-injects the persistent pool
    /// snapshot as nested PiP (3470764447). A fullscreenlayer with a visible
    /// effect (DoF, 3479521040) is a real post-process and stays.
    private static func noOpFullFramePassthroughIDs(
        in document: WPESceneDocument
    ) -> Set<String> {
        Set(
            document.imageObjects
                .filter { isFullFramePassthroughUtilityPath($0.imageRelativePath) }
                    .filter { !$0.effects.contains(where: Self.buildsIntoGraph) }
                .map(\.id)
        )
    }

    private func buildLayer(
        object: WPESceneImageObject,
        finalUntargetedPassToScene: Bool,
        preserveFinalCompositeForScene: Bool,
        sortIndex: Int
    ) throws -> WPERenderLayer {
        let model = try resolveModelDescriptor(for: object)
        let materialPath = model.materialPath
        let composite = WPERenderTargetNames.ImageLayerComposite.make(objectID: object.id)
        let compositeA = composite.a
        let compositeB = composite.b

        var context = LayerBuildContext(
            object: object,
            model: model,
            compositeA: compositeA,
            compositeB: compositeB,
            nextComposite: compositeA,
            source: .image(object.imageRelativePath)
        )

        if let materialPath {
            let loadedMaterial = try builtinMaterial(path: materialPath, object: object) ?? loadMaterial(path: materialPath)
            let material = Self.materialRespectingCopyBackground(loadedMaterial, object: object)
            let materialOverride = object.materialInstance.map {
                WPESceneEffectPassOverride(
                    id: $0.id,
                    combos: $0.combos,
                    constants: [:],
                    textures: $0.textures,
                    userTextures: $0.userTextures
                )
            }
            if let overriddenSource = materialOverride?.textures[0] {
                context.source = textureReference(overriddenSource, ownerPath: object.imageRelativePath)
            } else {
                context.source = material.initialTextureSource(fallback: context.source)
            }
            try appendMaterialPasses(
                material.passes,
                phase: .material,
                override: materialOverride,
                materialUserTextures: material.userTextures,
                overrideOwnerPath: object.imageRelativePath,
                binds: [:],
                explicitTarget: nil,
                to: &context
            )
        }

            for effect in object.effects where Self.buildsIntoGraph(effect) {
                let visibilityGate = Self.scriptVisibilityGate(for: effect)
            let asset = try loadEffect(path: effect.fileRelativePath)
            context.localFBOs.append(contentsOf: asset.fbos)
            let effectDeclaredFBONames = Set(asset.fbos.map(\.name))
            var overrideIndex = 0
            for effectPass in asset.passes {
                let override = overrideIndex < effect.passOverrides.count
                    ? effect.passOverrides[overrideIndex]
                    : nil
                overrideIndex += 1

                switch effectPass.kind {
                case .material(let materialPath):
                    let material = try loadMaterial(path: materialPath)
                    try appendMaterialPasses(
                        material.passes,
                        phase: .effect(file: effect.fileRelativePath),
                        override: override,
                        materialUserTextures: material.userTextures,
                        overrideOwnerPath: effect.fileRelativePath,
                        overrideDeclaredFBONames: effectDeclaredFBONames,
                        binds: effectPass.binds,
                        explicitTarget: effectPass.target.map { .fbo(name: $0) },
                            visibilityGate: visibilityGate,
                        to: &context
                    )
                case .command(let command, let source, let target):
                    let virtualPass = WPEMaterialPass(
                        shader: "commands/\(command)",
                        textures: [0: source ?? .previous],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                    try appendMaterialPasses(
                        [virtualPass],
                        phase: .command(file: effect.fileRelativePath),
                        override: override,
                        overrideOwnerPath: effect.fileRelativePath,
                        overrideDeclaredFBONames: effectDeclaredFBONames,
                        binds: effectPass.binds,
                        explicitTarget: target.map { .fbo(name: $0) },
                            visibilityGate: visibilityGate,
                        to: &context
                    )
                }
            }
        }

        let puppetMeshCenter = resolvedPuppetMeshCenter(for: model, object: object)
        let puppetOriginOffset = Self.puppetMeshOriginOffset(
            center: puppetMeshCenter,
            scale: object.scale,
            angles: object.angles
        )
        let localPuppetOriginOffset = Self.puppetMeshOriginOffset(
            center: puppetMeshCenter,
            scale: object.localScale,
            angles: object.localAngles
        )

        return WPERenderLayer(
            objectID: object.id,
            objectName: object.name,
            visible: object.visible,
            imagePath: object.imageRelativePath,
            materialPath: materialPath,
            puppetPath: model.puppetPath,
            parentObjectID: object.parentObjectID,
            attachment: object.attachment,
            animationLayers: object.animationLayers,
            geometry: WPERenderLayerGeometry(
                origin: object.origin + puppetOriginOffset,
                scale: object.scale,
                angles: object.angles,
                alignment: object.alignment,
                size: object.size,
                puppetMeshCenter: puppetMeshCenter,
                alpha: object.alpha,
                alphaAnimation: object.alphaAnimation,
                color: object.color,
                colorAnimation: object.colorAnimation,
                brightness: object.brightness,
                shapePoints: object.shapePoints
            ),
            localGeometry: WPERenderLayerGeometry(
                origin: object.localOrigin + localPuppetOriginOffset,
                scale: object.localScale,
                angles: object.localAngles,
                alignment: object.alignment,
                size: object.size,
                puppetMeshCenter: puppetMeshCenter,
                alpha: object.alpha,
                alphaAnimation: object.alphaAnimation,
                color: object.color,
                colorAnimation: object.colorAnimation,
                brightness: object.brightness,
                shapePoints: object.shapePoints
            ),
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: context.localFBOs,
            passes: context.finalizedPasses(
                finalUntargetedPassToScene: finalUntargetedPassToScene,
                preserveFinalCompositeForScene: preserveFinalCompositeForScene
                    || model.requiresFinalSceneComposite
                    || object.usesProgrammableBlend
            ),
            parallaxDepth: object.parallaxDepth,
            sortIndex: sortIndex
        )
    }

    /// `copybackground: false` composelayers seed `.previous` instead of the
    /// scene snapshot. `applyComposelayerGroups` must map that base-pass
    /// `.previous` to the group buffer or it paints PiP (3470764447 layer 249).
    private static func materialRespectingCopyBackground(
        _ material: WPEMaterialAsset,
        object: WPESceneImageObject
    ) -> WPEMaterialAsset {
        guard !object.copyBackground,
              isComposelayerModelPath(object.imageRelativePath),
              let firstPass = material.passes.first,
              firstPass.textures[0] == .fbo("_rt_FullFrameBuffer") else {
            return material
        }
        var passes = material.passes
        var textures = firstPass.textures
        textures[0] = .previous
        passes[0] = firstPass.replacingTextures(textures)
        return WPEMaterialAsset(
            path: material.path,
            passes: passes,
            userTextures: material.userTextures
        )
    }

    private func resolvedPuppetMeshCenter(
        for model: WPEModelDescriptor,
        object: WPESceneImageObject
    ) -> SIMD2<Double> {
        guard model.autosize,
              model.cropOffset != nil,
              let puppetPath = model.puppetPath,
              let size = object.size,
              let data = try? resolver.data(relativePath: puppetPath),
              let puppetModel = try? WPEMdlParser.parse(data: data),
              let bounds = Self.puppetMeshBounds(in: puppetModel) else {
            return SIMD2<Double>(0, 0)
        }

        let halfSize = SIMD2<Double>(
            max(Double(size.width) * 0.5, 0.5),
            max(Double(size.height) * 0.5, 0.5)
        )
        if bounds.intersects(center: SIMD2<Double>(0, 0), halfSize: halfSize) {
            return SIMD2<Double>(0, 0)
        }
        guard bounds.width <= Double(size.width) + 0.5,
              bounds.height <= Double(size.height) + 0.5 else {
            return SIMD2<Double>(0, 0)
        }
        return bounds.center
    }

    private static func puppetMeshOriginOffset(
        center: SIMD2<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>
    ) -> SIMD3<Double> {
        guard center.x != 0 || center.y != 0 else {
            return SIMD3<Double>(0, 0, 0)
        }
        let local = SIMD2<Double>(
            center.x * abs(scale.x),
            center.y * abs(scale.y)
        )
        let cosine = cos(angles.z)
        let sine = sin(angles.z)
        guard local.x.isFinite, local.y.isFinite, cosine.isFinite, sine.isFinite else {
            return SIMD3<Double>(0, 0, 0)
        }
        return SIMD3<Double>(
            cosine * local.x - sine * local.y,
            sine * local.x + cosine * local.y,
            0
        )
    }

    private static func puppetMeshBounds(in model: WPEPuppetModel) -> WPEPuppetMeshBounds? {
        var bounds: WPEPuppetMeshBounds?
        for mesh in model.meshes {
            for vertex in mesh.vertices {
                bounds = bounds.map { $0.including(vertex.position) }
                    ?? WPEPuppetMeshBounds(vertex.position)
            }
        }
        return bounds
    }

    private func appendMaterialPasses(
        _ passes: [WPEMaterialPass],
        phase: WPERenderPassPhase,
        override: WPESceneEffectPassOverride?,
        materialUserTextures: [WPESceneUserTextureBinding] = [],
        overrideOwnerPath: String = "",
        overrideDeclaredFBONames: Set<String> = [],
        binds: [Int: WPETextureReference],
        explicitTarget: WPERenderTarget?,
            visibilityGate: WPEPassVisibilityGate? = nil,
        to context: inout LayerBuildContext
    ) throws {
        for materialPass in passes {
            let target = explicitTarget ?? .layerComposite(name: context.nextComposite)
            var merged = materialPass.merging(override: override) { path in
                self.textureReference(
                    path,
                    ownerPath: overrideOwnerPath,
                    declaredFBONames: overrideDeclaredFBONames
                )
            }
            merged = materialPassWithPuppetClipCompositeIfNeeded(merged, phase: phase, context: &context)
            let passID = "\(context.object.id).\(context.passes.count)"
            context.passes.append(WPERenderPass(
                id: passID,
                phase: phase,
                shader: merged.shader,
                source: context.source,
                target: target,
                textures: merged.textures,
                binds: binds,
                constants: merged.constants,
                combos: merged.combos,
                userTextureBindings: WPERenderUserTextureBindings(
                    material: materialUserTextures,
                    pass: materialPass.userTextures,
                    override: override?.userTextures ?? []
                ),
                blending: merged.blending.premultipliedRenderTargetBlendMode,
                cullMode: merged.cullMode,
                depthTest: merged.depthTest,
                depthWrite: merged.depthWrite,
                    constantScripts: override?.constantScripts ?? [:],
                    visibilityGate: visibilityGate
            ))
            context.passTargetsWereExplicit.append(explicitTarget != nil)

            if explicitTarget == nil {
                context.source = .fbo(context.nextComposite)
                context.nextComposite = context.nextComposite == context.compositeA
                    ? context.compositeB
                    : context.compositeA
            }
        }
    }

    private func resolveModelDescriptor(for object: WPESceneImageObject) throws -> WPEModelDescriptor {
        let explicitMaterial = object.materialRelativePath?.isEmpty == false
            ? object.materialRelativePath
            : nil
        if Self.builtinSolidLayerDepthTest(forModelPath: object.imageRelativePath) != nil {
            return WPEModelDescriptor(materialPath: explicitMaterial ?? object.imageRelativePath, puppetPath: nil)
        }
        let extensionName = (object.imageRelativePath as NSString).pathExtension.lowercased()
        if extensionName == "mdl" {
            let model = try WPEMdlParser.parse(data: resolver.data(relativePath: object.imageRelativePath))
            guard let material = explicitMaterial ?? model.meshes.first(where: { !$0.materialPath.isEmpty })?.materialPath else {
                throw WPERenderGraphError.materialUnresolved(object.imageRelativePath)
            }
            let clipMaskNames = (Self.puppetClipCompositeEnabled ? object.imageRelativePath : nil)
                .map(loadPuppetClipMaskNames(path:)) ?? []
            return WPEModelDescriptor(
                materialPath: material,
                puppetPath: object.imageRelativePath,
                rendersAsSceneModel: true,
                puppetClipMaskNames: clipMaskNames
            )
        }
        guard extensionName == "json" else {
            return WPEModelDescriptor(materialPath: explicitMaterial, puppetPath: nil)
        }

        let dict: [String: Any]
        do {
            dict = try readJSONObject(path: object.imageRelativePath)
        } catch {
            guard let explicitMaterial else { throw error }
            return WPEModelDescriptor(materialPath: explicitMaterial, puppetPath: nil)
        }

        guard let material = explicitMaterial ?? (dict["material"] as? String),
              !material.isEmpty else {
            throw WPERenderGraphError.materialUnresolved(object.imageRelativePath)
        }
        let puppetPath = (dict["puppet"] as? String)
            .flatMap { $0.isEmpty ? nil : inheritDependencyPrefix($0, from: object.imageRelativePath) }
        let clipMaskNames = (Self.puppetClipCompositeEnabled ? puppetPath : nil)
            .map(loadPuppetClipMaskNames(path:)) ?? []
        return WPEModelDescriptor(
            materialPath: inheritDependencyPrefix(material, from: object.imageRelativePath),
            puppetPath: puppetPath,
            autosize: dict["autosize"] as? Bool ?? false,
            cropOffset: Self.parseModelCropOffset(dict["cropoffset"]),
            puppetClipMaskNames: clipMaskNames
        )
    }

    private static func parseModelCropOffset(_ raw: Any?) -> SIMD2<Double>? {
        guard let vector = WPESceneDocumentParser.parseVector3(raw) else { return nil }
        return SIMD2<Double>(vector.x, vector.y)
    }

    private func loadPuppetClipMaskNames(path: String) -> [String] {
        guard let data = try? resolver.data(relativePath: path),
              let model = try? WPEMdlParser.parse(data: data) else {
            return []
        }
        // The executor indexes bindings by authored group position, so duplicates must be retained.
        // The clip path itself only accepts one renderable mesh; mirror that selection here.
        if let mesh = model.meshes.first(where: {
            !$0.vertices.isEmpty && !$0.indices.isEmpty && !$0.clipGroups.isEmpty
        }) {
            return mesh.clipGroups.map(\.maskName)
        }
        return model.meshes.lazy
            .filter { !$0.vertices.isEmpty && !$0.indices.isEmpty }
            .compactMap(\.clipMaskName)
            .first
            .map { [$0] } ?? []
    }

    private func materialPassWithPuppetClipCompositeIfNeeded(
        _ pass: WPEMaterialPass,
        phase: WPERenderPassPhase,
        context: inout LayerBuildContext
    ) -> WPEMaterialPass {
        // Only the base material phase drives the clip composite; effect-chain genericimage4 passes
        // must not receive the clip bindings (the executor clip path only handles `.material`).
        guard case .material = phase,
              Self.puppetClipCompositeEnabled,
              context.model.requiresFinalSceneComposite,
              !context.model.puppetClipMaskNames.isEmpty,
              WPEBuiltinShaderKind(normalizing: pass.shader) == .genericImage4,
              pass.textures[8] == nil else {
            return pass
        }
        // Shared name so the executor's defer routing matches this exact injected RT (no format drift).
        let clipTargetName = WPERenderTargetNames.PuppetClip.make(objectID: context.object.id)
        if !context.localFBOs.contains(where: { $0.name == clipTargetName }) {
            // Half-res clip mask RT, matching WPE (1920×1080 for a 3840×2160 capture).
            context.localFBOs.append(WPERenderFBO(name: clipTargetName, scale: 2, format: "rgba8888"))
        }
        var textures = pass.textures
        // Internal slots keep clip masks out of the authored genericimage4 sampler namespace. The
        // resolver still applies the normal `materials/` root and `.tex` extension.
        for (groupIndex, maskName) in context.model.puppetClipMaskNames.enumerated() {
            let slot = WPERenderTargetNames.PuppetClip.maskBindingSlot(groupIndex: groupIndex)
            textures[slot] = textureReference(maskName, ownerPath: context.object.imageRelativePath)
        }
        textures[8] = .fbo(clipTargetName)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "WPESceneDebugArtifactsEnabled") {
            Logger.info(
                "[WPE clip] builder injected clip-composite bindings for \(context.model.puppetPath ?? "?") "
                    + "(masks=\(context.model.puppetClipMaskNames), rt=\(clipTargetName))",
                category: .wpeRender
            )
        }
        #endif
        return pass.replacingTextures(textures)
    }

    /// The two bundled solid-layer models (`solidlayer.json` and its depth-test
    /// variant) are both `"solidlayer": true`; they differ only in depth-test state.
    private static func builtinSolidLayerDepthTest(forModelPath path: String) -> String? {
        switch path.lowercased() {
        case "models/util/solidlayer.json":
            return "disabled"
        case "models/util/solidlayer_depthtest.json":
            return "enabled"
        default:
            return nil
        }
    }

    private func builtinMaterial(path: String, object: WPESceneImageObject) throws -> WPEMaterialAsset? {
        if let textTarget = Self.builtinTextTargetMaterial(path: path) {
            return textTarget
        }
        guard let depthTest = Self.builtinSolidLayerDepthTest(forModelPath: path) else {
            return nil
        }

        let color = object.color * object.brightness
        return WPEMaterialAsset(
            path: path,
            passes: [
                WPEMaterialPass(
                    // `solidlayer` is premultiplied (rgb*alpha); `solidcolor` is
                    // straight and blew 3719111841's audio-line base to opaque white.
                    shader: WPEBuiltinShaderKind.solidLayer.rawValue,
                    textures: [:],
                    constants: [
                        "g_Color": .vector([color.x, color.y, color.z, object.alpha])
                    ],
                    combos: [:],
                    blending: object.blendMode.rawValue,
                    cullMode: "nocull",
                    depthTest: depthTest,
                    depthWrite: "disabled"
                )
            ]
        )
    }

    private static func builtinTextTargetMaterial(path: String) -> WPEMaterialAsset? {
        guard WPETextLayerSynthesis.isTargetPath(path) else { return nil }
        return WPEMaterialAsset(
            path: path,
            passes: [
                WPEMaterialPass(
                    shader: WPETextLayerSynthesis.glyphPassShader,
                    textures: [:],
                    constants: [:],
                    combos: [:],
                    blending: "premultipliednormal",
                    cullMode: "nocull",
                    depthTest: "disabled",
                    depthWrite: "disabled"
                )
            ]
        )
    }

    private func loadMaterial(path: String) throws -> WPEMaterialAsset {
        let dict = try readJSONObject(path: path)
        guard let rawPasses = dict["passes"] as? [Any] else {
            throw WPERenderGraphError.malformedMaterial(path)
        }
        let passes = rawPasses.compactMap { parseMaterialPass($0, ownerPath: path) }
        guard !passes.isEmpty else {
            throw WPERenderGraphError.malformedMaterial(path)
        }
        return WPEMaterialAsset(
            path: path,
            passes: passes,
            userTextures: parseUserTextureBindings(dict["usertextures"])
        )
    }

    private func loadEffect(path: String) throws -> WPEEffectAsset {
        let dict = try readJSONObject(path: path)
        let fbos = ((dict["fbos"] as? [Any]) ?? []).compactMap(parseFBO)
        let declaredFBONames = Set(fbos.map(\.name))
        guard let rawPasses = dict["passes"] as? [Any] else {
            throw WPERenderGraphError.malformedEffect(path)
        }
        let passes = rawPasses.compactMap {
            parseEffectPass($0, ownerPath: path, declaredFBONames: declaredFBONames)
        }
        guard !passes.isEmpty else {
            throw WPERenderGraphError.malformedEffect(path)
        }
        return WPEEffectAsset(path: path, passes: passes, fbos: fbos)
    }

    private func readJSONObject(path: String) throws -> [String: Any] {
        let data: Data
        do {
            data = try resolver.data(relativePath: path)
        } catch {
            throw WPERenderGraphError.fileMissing(path)
        }
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WPERenderGraphError.invalidJSON(path)
            }
            return dict
        } catch let error as WPERenderGraphError {
            throw error
        } catch {
            throw WPERenderGraphError.invalidJSON(path)
        }
    }

    private func parseMaterialPass(_ raw: Any, ownerPath: String) -> WPEMaterialPass? {
        guard let dict = raw as? [String: Any],
              let shader = dict["shader"] as? String,
              !shader.isEmpty else {
            return nil
        }
        return WPEMaterialPass(
            shader: shader,
            textures: parseTextureArray(dict["textures"], ownerPath: ownerPath),
            constants: parseShaderConstants(dict["constantshadervalues"]),
            combos: parseComboMap(dict["combos"]),
            userTextures: parseUserTextureBindings(dict["usertextures"]),
            blending: (dict["blending"] as? String) ?? "normal",
            cullMode: (dict["cullmode"] as? String) ?? "nocull",
            depthTest: (dict["depthtest"] as? String) ?? "disabled",
            depthWrite: (dict["depthwrite"] as? String) ?? "disabled"
        )
    }

    private func parseEffectPass(
        _ raw: Any,
        ownerPath: String,
        declaredFBONames: Set<String>
    ) -> WPEEffectPass? {
        guard let dict = raw as? [String: Any] else { return nil }
        let binds = parseBinds(
            dict["bind"],
            ownerPath: ownerPath,
            declaredFBONames: declaredFBONames
        )
        let target = dict["target"] as? String
        if let material = dict["material"] as? String, !material.isEmpty {
            return WPEEffectPass(
                kind: .material(inheritDependencyPrefix(material, from: ownerPath)),
                binds: binds,
                target: target
            )
        }
        if let command = dict["command"] as? String, !command.isEmpty {
            return WPEEffectPass(
                kind: .command(
                    command,
                    source: (dict["source"] as? String).map {
                        textureReference($0, ownerPath: ownerPath, declaredFBONames: declaredFBONames)
                    },
                    target: target
                ),
                binds: binds,
                target: target
            )
        }
        return nil
    }

    private func parseFBO(_ raw: Any) -> WPERenderFBO? {
        guard let dict = raw as? [String: Any],
              let name = dict["name"] as? String,
              !name.isEmpty else {
            return nil
        }
        return WPERenderFBO(
            name: name,
            scale: parseDouble(dict["scale"]) ?? 1,
            fit: parseDouble(dict["fit"]),
            format: (dict["format"] as? String) ?? "rgba8888",
            unique: parseBool(dict["unique"]) ?? false
        )
    }

    private func parseBinds(
        _ raw: Any?,
        ownerPath: String,
        declaredFBONames: Set<String> = []
    ) -> [Int: WPETextureReference] {
        guard let array = raw as? [Any] else { return [:] }
        var result: [Int: WPETextureReference] = [:]
        for entry in array {
            guard let dict = entry as? [String: Any],
                  let index = parseInt(dict["index"]),
                  let name = dict["name"] as? String,
                  !name.isEmpty else {
                continue
            }
            result[index] = textureReference(name, ownerPath: ownerPath, declaredFBONames: declaredFBONames)
        }
        return result
    }

    private func parseTextureArray(_ raw: Any?, ownerPath: String) -> [Int: WPETextureReference] {
        guard let array = raw as? [Any] else { return [:] }
        var result: [Int: WPETextureReference] = [:]
        for (index, value) in array.enumerated() {
            if let name = Self.parseTexturePath(value) {
                result[index] = textureReference(name, ownerPath: ownerPath)
            }
        }
        return result
    }

    /// The array index is the overridden texture slot, so the `null` holes must be
    /// counted, not compacted away.
    private func parseUserTextureBindings(_ raw: Any?) -> [WPESceneUserTextureBinding] {
        (raw as? [Any] ?? []).enumerated().compactMap { slot, raw in
            if let name = raw as? String, !name.isEmpty {
                return WPESceneUserTextureBinding(name: name, slot: slot)
            }
            guard let entry = raw as? [String: Any],
                  let name = entry["name"] as? String,
                  !name.isEmpty else { return nil }
            let type = (entry["type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WPESceneUserTextureBinding(name: name, type: type, slot: slot)
        }
    }

    /// Texture arrays mix plain path strings with structured entries
    /// (`{"name": "masks/…"}`, how per-instance effect masks are declared).
    static func parseTexturePath(_ raw: Any?) -> String? {
        if let string = raw as? String {
            // Preserve nonblank names verbatim because package entries can legitimately
            // end in whitespace and asset lookup is byte-sensitive.
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
        }
        guard let dict = raw as? [String: Any] else { return nil }
        for key in ["value", "name", "texture", "path", "file"] {
            if let parsed = parseTexturePath(dict[key]) {
                return parsed
            }
        }
        return nil
    }

    private func textureReference(
        _ name: String,
        ownerPath: String,
        declaredFBONames: Set<String> = []
    ) -> WPETextureReference {
        if name == "previous" {
            return .previous
        }
        if declaredFBONames.contains(name) {
            return .fbo(name)
        }
        if isImplicitFBOTextureName(name) {
            return .fbo(name)
        }
        return .asset(inheritDependencyPrefix(name, from: ownerPath))
    }

    private func inheritDependencyPrefix(_ path: String, from ownerPath: String) -> String {
        guard !path.hasPrefix("../"),
              let prefix = dependencyPrefix(in: ownerPath) else {
            return path
        }
        return "\(prefix)/\(path)"
    }

    private func dependencyPrefix(in path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == ".." else { return nil }
        return "../\(parts[1])"
    }

    private func parseShaderConstants(_ raw: Any?) -> [String: WPESceneShaderConstantValue] {
        WPEValueParser.shaderConstants(raw, boolAsNumber: true)
    }

    private func parseComboMap(_ raw: Any?) -> [String: Int] {
        WPEValueParser.comboMap(raw, boolAsNumber: true)
    }

    private func parseDouble(_ raw: Any?) -> Double? {
        WPEValueParser.double(raw, boolAsNumber: true)
    }

    private func parseBool(_ raw: Any?) -> Bool? {
        WPEValueParser.bool(raw)
    }

    private func parseInt(_ raw: Any?) -> Int? {
        WPEValueParser.int(raw, boolAsNumber: true)
    }
}

private struct LayerBuildContext {
    let object: WPESceneImageObject
    let model: WPEModelDescriptor
    let compositeA: String
    let compositeB: String
    var nextComposite: String
    var source: WPETextureReference
    var localFBOs: [WPERenderFBO] = []
    var passes: [WPERenderPass] = []
    var passTargetsWereExplicit: [Bool] = []

    /// Destination-reading blend samples the layer plus `_rt_FullFrameBuffer`
    /// at slot 4 (`g_Texture4`). RenderDoc-confirmed on 3448877775 pass 41.
    func sceneCompositePass(
        index: Int,
        source: WPETextureReference,
        fallbackBlending: String
    ) -> WPERenderPass {
        let programmable = object.usesProgrammableBlend
        let shader = programmable
            ? WPEBuiltinShaderKind.blendComposite.rawValue
            : WPERenderPassPhase.sceneCopyCommandFile
        var textures: [Int: WPETextureReference] = [0: source]
        if programmable {
            // Slot 4 = `g_Texture4`; the executor snapshots a COPY so this is
            // not a feedback loop.
            textures[4] = .fbo(WPESceneAliasName.fullFrameBuffer)
        }
        return WPERenderPass(
            id: "\(object.id).\(index)",
            phase: .command(file: WPERenderPassPhase.sceneCopyCommandFile),
            shader: shader,
            source: source,
            target: .scene,
            textures: textures,
            binds: [:],
            constants: programmable ? ["g_BlendMode": .number(Double(object.colorBlendMode))] : [:],
            combos: [:],
            // ApplyBlending has already folded the destination in, so the state
            // is a plain premultiplied over — never the authored mode.
            blending: programmable ? "premultiplied" : fallbackBlending,
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
    }

    func finalizedPasses(
        finalUntargetedPassToScene: Bool,
        preserveFinalCompositeForScene: Bool
    ) -> [WPERenderPass] {
        // A programmable blend is applied inside the composite fragment; leaving
        // the authored mode on the pass would double-apply it.
        let finalSceneBlendMode = (object.blendMode == .normal || object.usesProgrammableBlend)
            ? nil
            : object.blendMode.rawValue.premultipliedRenderTargetBlendMode

        func appendingCanonicalCompositeCopyIfNeeded(
            to finalized: [WPERenderPass],
            finalSource: WPETextureReference
        ) -> [WPERenderPass] {
            guard preserveFinalCompositeForScene,
                  finalSource != .fbo(compositeA) else {
                return finalized
            }
            guard case .fbo = finalSource else {
                return finalized
            }
            return finalized + [WPERenderPass(
                id: "\(object.id).\(finalized.count)",
                phase: .command(file: WPERenderPassPhase.sceneCopyCommandFile),
                shader: WPERenderPassPhase.sceneCopyCommandFile,
                source: finalSource,
                target: .layerComposite(name: compositeA),
                textures: [0: finalSource],
                binds: [:],
                constants: [:],
                combos: [:],
                blending: "premultipliedDisabled",
                cullMode: "nocull",
                depthTest: "disabled",
                depthWrite: "disabled"
            )]
        }

        guard let lastPass = passes.last,
              finalUntargetedPassToScene,
              passTargetsWereExplicit.indices.contains(passes.count - 1),
              passTargetsWereExplicit[passes.count - 1] == false else {
            return appendingCanonicalCompositeCopyIfNeeded(
                to: passes.movingFirstBlendModeToFinalPass(),
                finalSource: source
            )
        }

        // Ordinary effects finish in layer space; promoting the last one to
        // `.scene` changes viewport/texel size. `shape:quad` DIRECTDRAW is
        // already scene geometry — do not warp it a second time.
        let hasLayerResolutionEffect = object.shapePoints == nil && passes.contains { pass in
            switch pass.phase {
            case .effect:
                return true
            case .command(let file):
                return file != WPERenderPassPhase.sceneCopyCommandFile
            case .material:
                return false
            }
        }
        let lastPassIsWorkshopEffect = lastPass.shader.contains("workshop/")
        // A script-gated pass must never BE the scene draw: closing the gate would
        // leave the layer undrawn entirely instead of merely un-effected. Force the
        // separate composite→scene copy so the gate only ever removes the effect.
        let lastPassIsGated = lastPass.visibilityGate != nil
        if preserveFinalCompositeForScene || hasLayerResolutionEffect
            || lastPassIsWorkshopEffect || lastPassIsGated,
           let lastSource = lastPass.target.textureReference {
            let finalSource = preserveFinalCompositeForScene ? source : lastSource
            var finalized = appendingCanonicalCompositeCopyIfNeeded(to: passes, finalSource: finalSource)
            let sceneSource = preserveFinalCompositeForScene && finalSource != .fbo(compositeA)
                ? WPETextureReference.fbo(compositeA)
                : finalSource
            finalized.append(sceneCompositePass(index: finalized.count, source: sceneSource, fallbackBlending: lastPass.blending))
            return finalized.movingFirstBlendModeToFinalPass(finalBlendMode: finalSceneBlendMode)
        }

        var finalized = passes
        finalized[finalized.count - 1] = lastPass.replacingTarget(.scene)
        return finalized.movingFirstBlendModeToFinalPass(finalBlendMode: finalSceneBlendMode)
    }
}

private struct WPEModelDescriptor {
    let materialPath: String?
    let puppetPath: String?
    let rendersAsSceneModel: Bool
    let autosize: Bool
    let cropOffset: SIMD2<Double>?
    let puppetClipMaskNames: [String]
    var requiresFinalSceneComposite: Bool { puppetPath != nil && !rendersAsSceneModel }

    init(
        materialPath: String?,
        puppetPath: String?,
        rendersAsSceneModel: Bool = false,
        autosize: Bool = false,
        cropOffset: SIMD2<Double>? = nil,
        puppetClipMaskNames: [String] = []
    ) {
        self.materialPath = materialPath
        self.puppetPath = puppetPath
        self.rendersAsSceneModel = rendersAsSceneModel
        self.autosize = autosize
        self.cropOffset = cropOffset
        self.puppetClipMaskNames = puppetClipMaskNames
    }
}

private struct WPEPuppetMeshBounds {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double

    init(_ position: SIMD3<Float>) {
        let x = Double(position.x)
        let y = Double(position.y)
        self.minX = x
        self.maxX = x
        self.minY = y
        self.maxY = y
    }

    private init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var center: SIMD2<Double> {
        SIMD2<Double>((minX + maxX) * 0.5, (minY + maxY) * 0.5)
    }

    func including(_ position: SIMD3<Float>) -> WPEPuppetMeshBounds {
        let x = Double(position.x)
        let y = Double(position.y)
        return WPEPuppetMeshBounds(
            minX: min(minX, x),
            maxX: max(maxX, x),
            minY: min(minY, y),
            maxY: max(maxY, y)
        )
    }

    func intersects(center: SIMD2<Double>, halfSize: SIMD2<Double>) -> Bool {
        maxX >= center.x - halfSize.x
            && minX <= center.x + halfSize.x
            && maxY >= center.y - halfSize.y
            && minY <= center.y + halfSize.y
    }
}

private extension WPERenderLayer {
    func replacingLocalFBOs(_ localFBOs: [WPERenderFBO]) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: geometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    func replacingPasses(_ passes: [WPERenderPass]) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: geometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    func withGroupRenderTarget(_ target: String, localGeometry: WPERenderLayerGeometry) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: geometry,
            localGeometry: self.localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: target,
            groupLocalGeometry: localGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    func withGroupCompositeSource(_ source: String) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: geometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: source,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    func replacingGeometryOrigin(addingSceneOffset offset: SIMD3<Double>) -> WPERenderLayer {
        let g = geometry
        let newGeometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(g.origin.x + offset.x, g.origin.y + offset.y, g.origin.z + offset.z),
            scale: g.scale,
            angles: g.angles,
            alignment: g.alignment,
            size: g.size,
            puppetMeshCenter: g.puppetMeshCenter,
            alpha: g.alpha,
            alphaAnimation: g.alphaAnimation,
            color: g.color,
            colorAnimation: g.colorAnimation,
            brightness: g.brightness,
            shapePoints: g.shapePoints
        )
        return WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: newGeometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    func withParallaxDepth(_ depth: SIMD2<Double>) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: geometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: depth,
            sortIndex: sortIndex
        )
    }
}

private extension WPERenderPass {
    func replacingSceneAliasReferences(with replacement: WPETextureReference) -> WPERenderPass {
        let newSource = source.replacingSceneAlias(with: replacement)
        let newTextures = textures.mapValues { $0.replacingSceneAlias(with: replacement) }
        return WPERenderPass(
            id: id,
            phase: phase,
            shader: shader,
            source: newSource,
            target: target,
            textures: newTextures,
            binds: binds,
            constants: constants,
            combos: combos,
            userTextureBindings: userTextureBindings,
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite,
            constantScripts: constantScripts
        )
    }

    func replacingPreviousReferences(with replacement: WPETextureReference) -> WPERenderPass {
        let newSource = source == .previous ? replacement : source
        let newTextures = textures.mapValues { $0 == .previous ? replacement : $0 }
        return WPERenderPass(
            id: id,
            phase: phase,
            shader: shader,
            source: newSource,
            target: target,
            textures: newTextures,
            binds: binds,
            constants: constants,
            combos: combos,
            userTextureBindings: userTextureBindings,
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite,
            constantScripts: constantScripts
        )
    }
}

private extension WPETextureReference {
    func replacingSceneAlias(with replacement: WPETextureReference) -> WPETextureReference {
        guard case .fbo(let name) = self,
              Self.isSceneAliasName(name) else {
            return self
        }
        return replacement
    }
}

private extension WPERenderTarget {
    var textureReference: WPETextureReference? {
        switch self {
        case .layerComposite(let name), .fbo(let name):
            return .fbo(name)
        case .scene:
            return nil
        }
    }
}

private extension String {
    var premultipliedRenderTargetBlendMode: String {
        switch normalizedBlendModeKey {
        case "premultiplied",
             "premultipliednormal",
             "premultipliedtranslucent",
             "premultipliednormalmapped",
             "premultipliedadditive",
             "premultiplieddisabled",
             "premultipliedmultiply",
             "premultipliedscreen":
            return self
        case "disabled":
            return "premultipliedDisabled"
        case "add", "additive", "oneone", "oneoneone":
            return "premultipliedAdditive"
        case "multiply":
            return "premultipliedMultiply"
        case "screen":
            return "premultipliedScreen"
        default:
            return "premultiplied"
        }
    }

    var premultipliedIntermediateBlendMode: String {
        switch normalizedBlendModeKey {
        case "disabled", "premultiplieddisabled":
            return "premultipliedDisabled"
        default:
            return "premultiplied"
        }
    }

    private var normalizedBlendModeKey: String {
        lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private extension Array where Element == WPERenderPass {
    func movingFirstBlendModeToFinalPass(finalBlendMode: String? = nil) -> [WPERenderPass] {
        guard let first = first,
              let last = last else {
            return self
        }

        // Single-pass layer: the base draw IS the scene draw, so an authored
        // object blend (additive/screen/multiply) must still land on it.
        if count == 1 {
            guard let finalBlendMode else { return self }
            var result = self
            result[0] = first.replacingBlending(finalBlendMode)
            return result
        }

        var result = self
        result[0] = first.replacingBlending(first.blending.premultipliedIntermediateBlendMode)
        result[result.count - 1] = last.replacingBlending(finalBlendMode ?? first.blending)
        return result
    }
}

private struct WPEMaterialAsset {
    let path: String
    let passes: [WPEMaterialPass]
    let userTextures: [WPESceneUserTextureBinding]

    init(
        path: String,
        passes: [WPEMaterialPass],
        userTextures: [WPESceneUserTextureBinding] = []
    ) {
        self.path = path
        self.passes = passes
        self.userTextures = userTextures
    }

    func initialTextureSource(fallback: WPETextureReference) -> WPETextureReference {
        passes.first?.textures[0] ?? fallback
    }
}

private struct WPEEffectAsset {
    let path: String
    let passes: [WPEEffectPass]
    let fbos: [WPERenderFBO]
}

private struct WPEEffectPass {
    let kind: Kind
    let binds: [Int: WPETextureReference]
    let target: String?

    enum Kind {
        case material(String)
        case command(String, source: WPETextureReference?, target: String?)
    }
}

private struct WPEMaterialPass {
    let shader: String
    let textures: [Int: WPETextureReference]
    let constants: [String: WPESceneShaderConstantValue]
    let combos: [String: Int]
    let userTextures: [WPESceneUserTextureBinding]
    let blending: String
    let cullMode: String
    let depthTest: String
    let depthWrite: String

    init(
        shader: String,
        textures: [Int: WPETextureReference],
        constants: [String: WPESceneShaderConstantValue],
        combos: [String: Int],
        userTextures: [WPESceneUserTextureBinding] = [],
        blending: String,
        cullMode: String,
        depthTest: String,
        depthWrite: String
    ) {
        self.shader = shader
        self.textures = textures
        self.constants = constants
        self.combos = combos
        self.userTextures = userTextures
        self.blending = blending
        self.cullMode = cullMode
        self.depthTest = depthTest
        self.depthWrite = depthWrite
    }

    func merging(
        override: WPESceneEffectPassOverride?,
        resolveTexture: (String) -> WPETextureReference
    ) -> WPEMaterialPass {
        guard let override else { return self }
        var mergedTextures = textures
        for (index, path) in override.textures {
            mergedTextures[index] = resolveTexture(path)
        }

        return WPEMaterialPass(
            shader: shader,
            textures: mergedTextures,
            constants: constants.merging(override.constants) { _, new in new },
            combos: combos.merging(override.combos) { _, new in new },
            userTextures: userTextures,
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite
        )
    }

    func replacingTextures(_ textures: [Int: WPETextureReference]) -> WPEMaterialPass {
        WPEMaterialPass(
            shader: shader,
            textures: textures,
            constants: constants,
            combos: combos,
            userTextures: userTextures,
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite
        )
    }
}
#endif
