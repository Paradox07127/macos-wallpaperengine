#if !LITE_BUILD
    import Darwin
    import Foundation
    import LiveWallpaperProWPE
    import Testing
    @testable import LiveWallpaper

    /// WPE authors panels as an alpha-0 "container" image object that draws nothing and
    /// exists only to position and scale its children. `compositesToScene` correctly keeps
    /// that container out of the render graph, which used to leave the per-frame parent
    /// walk in `applyingLayerTransforms` with no transform for it — and that walk fell
    /// back to the child's LOCAL transform, silently dropping the whole ancestor chain.
    /// Scene 3326873240's media panel landed at the scene origin at 2.5x its authored size.
    @Suite("WPE container ancestor transforms")
    struct WPEContainerAncestorTransformTests {

        // Authored values lifted from scene 3326873240 objects 131 / 132 / 140.
        private static let containerOrigin = SIMD3<Double>(183.649_90, 768.382_08, 0)
        private static let containerScale = SIMD3<Double>(0.4, 0.4, 0.75)

        private static func geometry(
            origin: SIMD3<Double>,
            scale: SIMD3<Double>
        ) -> WPERenderLayerGeometry {
            WPERenderLayerGeometry(
                origin: origin,
                scale: scale,
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 512, height: 512),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            )
        }

        private static func layer(
            id: String,
            parent: String?,
            world: WPERenderLayerGeometry,
            local: WPERenderLayerGeometry
        ) -> WPEPreparedRenderLayer {
            WPEPreparedRenderLayer(
                graphLayer: WPERenderLayer(
                    objectID: id,
                    objectName: id,
                    imagePath: "models/util/solidlayer.json",
                    materialPath: nil,
                    parentObjectID: parent,
                    geometry: world,
                    localGeometry: local,
                    compositeA: "_rt_a_\(id)",
                    compositeB: "_rt_b_\(id)",
                    localFBOs: [],
                    passes: []
                ),
                passes: []
            )
        }

        /// 131 (alpha-0 container, not a layer) -> 132 (Holder) -> 140 (Background).
        /// Only 132 and 140 reach the pipeline.
        private static func mediaPanelPipeline() -> WPEPreparedRenderPipeline {
            let holderWorld = geometry(origin: containerOrigin, scale: containerScale)
            let holderLocal = geometry(origin: SIMD3<Double>(0, 0, 0), scale: SIMD3<Double>(1, 1, 1))
            let backgroundLocal = geometry(
                origin: SIMD3<Double>(-256, 0, 0),
                scale: SIMD3<Double>(1, 1, 1)
            )
            let backgroundWorld = geometry(
                origin: SIMD3<Double>(
                    containerOrigin.x - 256 * containerScale.x,
                    containerOrigin.y,
                    0
                ),
                scale: containerScale
            )
            return WPEPreparedRenderPipeline(layers: [
                layer(id: "132", parent: "131", world: holderWorld, local: holderLocal),
                layer(id: "140", parent: "132", world: backgroundWorld, local: backgroundLocal)
            ])
        }

        @Test("An alpha-0 container ancestor still places the subtree it was dropped from")
        func alphaZeroContainerAncestorPlacesItsSubtree() throws {
            let document = try WPESceneDocumentParser.parse(data: Self.mediaPanelSceneJSON)
            let container = try #require(document.imageObjects.first { $0.id == "131" })
            #expect(
                container.alpha == 0,
                "fixture must keep the container's authored alpha-0, which is what drops it"
            )
            #expect(
                !WPERenderGraphBuilder.compositesToScene(container, liveVisibilityIDs: []),
                "an alpha-0 container with no effects must stay out of the render graph"
            )
            #expect(
                document.transformHostObjects.allSatisfy { $0.id != "131" },
                "an image object is never parsed as a transform host, so nothing else covers it"
            )

            // Exactly what the renderer feeds the per-frame walk.
            let hostTransforms = WPEMetalSceneRenderer.ancestorLocalTransforms(in: document)
            let moved = Self.mediaPanelPipeline().applyingLayerTransforms(
                // The container's origin SceneScript republishes its authored origin.
                origins: ["131": Self.containerOrigin],
                scales: ["132": SIMD3<Double>(1, 1, 1)],
                angles: [:],
                parentByID: document.objectParentByID,
                hostTransforms: hostTransforms
            )

            let holder = try #require(moved.layers.first { $0.graphLayer.objectID == "132" }).graphLayer
            #expect(
                holder.geometry.origin == Self.containerOrigin,
                "the Holder must stay at the container's world origin, not collapse to the scene corner"
            )
            #expect(
                holder.geometry.scale == Self.containerScale,
                "the Holder must keep the container's 0.4 scale, not snap back to 1"
            )

            let background = try #require(moved.layers.first { $0.graphLayer.objectID == "140" }).graphLayer
            #expect(
                background.geometry.origin
                    == SIMD3<Double>(Self.containerOrigin.x - 256 * 0.4, Self.containerOrigin.y, 0),
                "a grandchild must compose through the dropped container, not through a bare local origin"
            )
            #expect(background.geometry.scale == Self.containerScale)
        }

        @Test("A resolvable parent chain and a parentless layer are both left alone")
        func ordinaryPlacementIsUnchanged() throws {
            let document = try WPESceneDocumentParser.parse(data: Self.mediaPanelSceneJSON)
            let hostTransforms = WPEMetalSceneRenderer.ancestorLocalTransforms(in: document)

            // Parentless layer: the live origin is its world origin verbatim.
            let solo = WPEPreparedRenderPipeline(layers: [
                Self.layer(
                    id: "118",
                    parent: nil,
                    world: Self.geometry(origin: SIMD3<Double>(1219, 1119, 0), scale: SIMD3<Double>(1, 1, 1)),
                    local: Self.geometry(origin: SIMD3<Double>(1219, 1119, 0), scale: SIMD3<Double>(1, 1, 1))
                )
            ])
            let movedSolo = try #require(solo.applyingLayerTransforms(
                origins: ["118": SIMD3<Double>(500, 600, 0)],
                scales: [:],
                angles: [:],
                parentByID: document.objectParentByID,
                hostTransforms: hostTransforms
            ).layers.first).graphLayer
            #expect(movedSolo.geometry.origin == SIMD3<Double>(500, 600, 0))
            #expect(movedSolo.geometry.scale == SIMD3<Double>(1, 1, 1))

            // Parent present in the pipeline: composition already worked and must not shift.
            let parentWorld = Self.geometry(origin: SIMD3<Double>(1000, 500, 0), scale: SIMD3<Double>(0.5, 0.5, 1))
            let nested = WPEPreparedRenderPipeline(layers: [
                Self.layer(id: "a", parent: nil, world: parentWorld, local: parentWorld),
                Self.layer(
                    id: "b",
                    parent: "a",
                    world: Self.geometry(origin: SIMD3<Double>(1050, 500, 0), scale: SIMD3<Double>(0.5, 0.5, 1)),
                    local: Self.geometry(origin: SIMD3<Double>(100, 0, 0), scale: SIMD3<Double>(1, 1, 1))
                )
            ])
            let movedNested = nested.applyingLayerTransforms(
                origins: ["a": SIMD3<Double>(2000, 500, 0)],
                scales: [:],
                angles: [:],
                parentByID: ["b": "a"],
                hostTransforms: hostTransforms
            )
            let child = try #require(movedNested.layers.first { $0.graphLayer.objectID == "b" }).graphLayer
            #expect(
                child.geometry.origin == SIMD3<Double>(2050, 500, 0),
                "a child of a layer that IS in the pipeline still follows its parent"
            )
            #expect(child.geometry.scale == SIMD3<Double>(0.5, 0.5, 1))
        }

        @Test(
            "Scene 3326873240's real media panel hangs off a dropped alpha-0 container",
            .enabled(if: installedSceneURL != nil)
        )
        func realMediaPanelHangsOffADroppedContainer() throws {
            let folder = try #require(Self.installedSceneURL)
            let data = try #require(try Self.sceneJSON(in: folder), "scene.json not readable from scene.pkg")
            // The panel's own gate; the container's alpha-0 drop is independent of it.
            let document = try WPESceneDocumentParser.parse(
                data: data,
                userValues: ["newproperty67": .bool(true)]
            )

            let container = try #require(
                document.imageObjects.first { $0.id == "131" },
                "object 131 'Media Info (ROUND)' must still be in the installed scene"
            )
            #expect(container.parentObjectID == nil)
            #expect(container.alpha == 0)
            #expect(container.localScale == SIMD3<Double>(0.4, 0.4, 0.75))

            #expect(
                !WPERenderGraphBuilder.compositesToScene(container, liveVisibilityIDs: ["131"]),
                "131 is dropped from the render graph, so nothing else can supply its transform"
            )

            let holder = try #require(document.imageObjects.first { $0.id == "132" })
            #expect(holder.parentObjectID == "131")
            #expect(
                WPERenderGraphBuilder.compositesToScene(holder, liveVisibilityIDs: []),
                "132 IS drawn, so it is the layer that inherits the broken chain"
            )
            // The authored world placement the runtime walk has to reproduce.
            #expect(abs(holder.origin.x - 183.649_90) < 0.001)
            #expect(abs(holder.origin.y - 768.382_08) < 0.001)
            #expect(abs(holder.scale.x - 0.4) < 0.001)

            #expect(
                WPEMetalSceneRenderer.ancestorLocalTransforms(in: document)["131"] != nil,
                "the per-frame parent walk must be able to resolve 131"
            )
        }

        // MARK: - Fixtures

        /// Minimal stand-in for the 131/132/140 subtree: an alpha-0 container that scales
        /// and offsets its children, which is the shape that broke.
        private static let mediaPanelSceneJSON = Data("""
        {
          "camera": {
            "center": "0.00000 0.00000 -1.00000",
            "eye": "0.00000 0.00000 0.00000",
            "up": "0.00000 1.00000 0.00000"
          },
          "general": { "orthogonalprojection": { "width": 3840, "height": 2160 } },
          "objects": [
            {
              "id": 131, "name": "Media Info (ROUND)", "image": "models/util/solidlayer.json",
              "origin": "183.64990 768.38208 0.00000", "scale": "0.40000 0.40000 0.75000",
              "size": "512.00000 512.00000", "alpha": 0.0
            },
            {
              "id": 132, "name": "Holder", "parent": 131,
              "image": "models/workshop/3219510589/corner5.json", "size": "512.00000 512.00000"
            },
            {
              "id": 140, "name": "Background", "parent": 132,
              "image": "models/util/solidlayer.json", "origin": "-256.00000 0.00000 0.00000",
              "size": "1206.00000 512.00000"
            }
          ]
        }
        """.utf8)

        /// Real corpus gate: the sandboxed test host's `NSHomeDirectory()` is the
        /// container, so the Steam path has to come from the passwd entry.
        private static var installedSceneURL: URL? {
            let passwd = getpwuid(getuid())
            let realHome = passwd.map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
            let folder = URL(fileURLWithPath: realHome, isDirectory: true)
                .appendingPathComponent(
                    "Library/Application Support/Steam/steamapps/workshop/content/431960/3326873240",
                    isDirectory: true
                )
            return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
        }

        private static func sceneJSON(in folder: URL) throws -> Data? {
            let loose = folder.appendingPathComponent("scene.json")
            if FileManager.default.fileExists(atPath: loose.path) {
                return try Data(contentsOf: loose)
            }
            let packageURL = folder.appendingPathComponent("scene.pkg")
            guard FileManager.default.fileExists(atPath: packageURL.path) else { return nil }
            let handle = try FileHandle(forReadingFrom: packageURL)
            defer { try? handle.close() }
            let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
            guard let entry = package.nameIndex["scene.json"],
                  entry.dataSize <= 64 * 1024 * 1024 else { return nil }
            try handle.seek(toOffset: package.dataStart + entry.dataOffset)
            return try handle.read(upToCount: Int(entry.dataSize))
        }
    }
#endif
