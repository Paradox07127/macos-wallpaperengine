import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

@Suite("WPE camera parallax")
struct WPECameraParallaxTests {

    private func parse(_ payload: [String: Any]) throws -> WPESceneDocument {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try WPESceneDocumentParser.parse(data: data)
    }

    private func minimalScene(general: [String: Any]) -> [String: Any] {
        [
            "camera": ["center": "0 0 0"],
            "general": general,
            "objects": [[
                "id": "1", "name": "Solid", "type": "image",
                "image": "models/util/solidlayer.json", "visible": true
            ]]
        ]
    }

    private func parsedImageDepth(_ raw: Any) throws -> SIMD2<Double> {
        let doc = try parse([
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100, "auto": true]],
            "objects": [[
                "id": "1", "name": "Solid", "type": "image",
                "image": "models/util/solidlayer.json", "visible": true,
                "parallaxDepth": raw
            ]]
        ])
        return try #require(doc.imageObjects.first).parallaxDepth
    }

    // MARK: - Parser

    @Test("Parses camera parallax settings")
    func parsesSettings() throws {
        let doc = try parse(minimalScene(general: [
            "orthogonalprojection": ["width": 2560, "height": 1440, "auto": true],
            "cameraparallax": true,
            "cameraparallaxamount": 0.8,
            "cameraparallaxdelay": 0.2,
            "cameraparallaxmouseinfluence": 0.4
        ]))
        let p = doc.general.cameraParallax
        #expect(p.enabled == true)
        #expect(abs(p.amount - 0.8) < 1e-9)
        #expect(abs(p.delay - 0.2) < 1e-9)
        #expect(abs(p.mouseInfluence - 0.4) < 1e-9)
    }

    @Test("Defaults to disabled with WPE default scalars when absent")
    func defaultsWhenAbsent() throws {
        let doc = try parse(minimalScene(general: [
            "orthogonalprojection": ["width": 2560, "height": 1440, "auto": true]
        ]))
        #expect(doc.general.cameraParallax == .disabled)
        #expect(doc.general.cameraParallax.enabled == false)
        #expect(abs(doc.general.cameraParallax.amount - 0.5) < 1e-9)
    }

    @Test("Negative mouseinfluence inverts parallax instead of disabling it")
    func negativeMouseInfluenceInvertsParallax() {
        // Asserted on the resolved SHIFT: `mouseinfluence` weights the mouse
        // term inside `pixelOffset`, so `smoothed` (the raw cursor offset) is
        // identical for both signs by design.
        func shift(influence: Double) -> SIMD2<Float> {
            var smoother = WPECameraParallaxSmoother()
            let settings = WPESceneCameraParallaxSettings(
                enabled: true, amount: 0.5, delay: 0, mouseInfluence: influence
            )
            return smoother.frame(
                settings: settings,
                pointerPosition: SIMD2<Double>(1, 1),
                time: 0
            ).pixelOffset(
                objectCenter: .zero,
                depth: SIMD2<Double>(1, 1),
                sceneSize: CGSize(width: 1000, height: 1000)
            )
        }
        let positive = shift(influence: 0.5)
        let negative = shift(influence: -0.5)
        #expect(positive != SIMD2<Float>(0, 0), "sanity: positive influence parallaxes")
        #expect(negative != SIMD2<Float>(0, 0), "negative influence must NOT be treated as off")
        #expect(negative == -positive, "negative influence mirrors the shift")
    }

    // MARK: - pixelOffset

    @Test("pixelOffset is zero for depth 0")
    func pixelOffsetDepthZero() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.5, 0.5), amount: 1, influence: 1)
        #expect(frame.pixelOffset(objectCenter: .zero, depth: SIMD2<Double>(0, 0), sceneSize: CGSize(width: 2560, height: 1440)) == SIMD2<Float>(0, 0))
    }

    @Test("pixelOffset sign: both axes negated; magnitude scales with depth × gain")
    func pixelOffsetSign() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.2, 0.2), amount: 1, influence: 1)
        let off = frame.pixelOffset(objectCenter: .zero, depth: SIMD2<Double>(1, 1), sceneSize: CGSize(width: 1000, height: 1000))
        #expect(abs(off.x - (-200)) < 1e-3)
        #expect(abs(off.y - (-200)) < 1e-3)
    }

    /// The reference clamps nothing (`WPShaderValueUpdater.cpp`): a deep layer
    /// is MEANT to travel far. 2780710296 parks its clock behind the character
    /// and needs 831 scene px of travel to clear it; the old ±0.2-of-scene
    /// ceiling stopped it at 512 and saturated after 10% of cursor travel.
    @Test("pixelOffset does not clamp: deep layers travel as far as WPE moves them")
    func pixelOffsetIsUnclamped() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.5, -0.5), amount: 1, influence: 1)
        let off = frame.pixelOffset(objectCenter: .zero, depth: SIMD2<Double>(10, 10), sceneSize: CGSize(width: 1000, height: 1000))
        #expect(abs(off.x - (-5000)) < 1e-3)
        #expect(abs(off.y - 5000) < 1e-3)
    }

    /// End-to-end against the two RenderDoc captures of 2780710296 (ortho
    /// 2560×1440, `cameraparallaxamount` 0.5, `mouseinfluence` 0.5, the clock's
    /// `parallaxDepth` "4 0"): sliding the cursor right must carry the text
    /// left by `Δpointer × 2560` scene px. The captures differ by 831 px, which
    /// the old formula could not reach at ANY cursor position.
    @Test("2780710296: reference travel per cursor unit is ortho × influence × amount × depth")
    func referenceTravelMatchesCapture() {
        var smoother = WPECameraParallaxSmoother()
        let settings = WPESceneCameraParallaxSettings(
            enabled: true, amount: 0.5, delay: 0, mouseInfluence: 0.5
        )
        let scene = CGSize(width: 2560, height: 1440)
        let depth = SIMD2<Double>(4, 0)
        func offset(at pointerX: Double) -> Float {
            smoother.reset()
            return smoother
                .frame(settings: settings, pointerPosition: SIMD2<Double>(pointerX, 0.5), time: 0, gain: 1)
                .pixelOffset(objectCenter: .zero, depth: depth, sceneSize: scene).x
        }
        // Cursor dead centre parks the layer at its authored origin.
        #expect(abs(offset(at: 0.5)) < 1e-3)
        // Full-width sweep = half the scene each way (WPE: (0.5-p) × ortho).
        #expect(abs(offset(at: 1.0) - (-1280)) < 0.5)
        #expect(abs(offset(at: 0.0) - 1280) < 0.5)
        // The measured 831 px separation is reachable, and needs ~32% of travel.
        #expect(abs((offset(at: 0.287) - offset(at: 0.612)) - 831) < 5)
        // The static `nodePos - camPos` term parks the clock off-scene at rest:
        // origin x 1763.9 in a 2560-wide scene → +967.8 px, i.e. x=2731.7.
        smoother.reset()
        let atRest = smoother
            .frame(settings: settings, pointerPosition: SIMD2<Double>(0.5, 0.5), time: 0, gain: 1)
            .pixelOffset(
                objectCenter: SIMD2<Double>(1763.895 - 1280, 1087.566 - 720),
                depth: depth, sceneSize: scene
            )
        #expect(abs(atRest.x - 967.8) < 0.5, "the character must hide the clock at rest")
        // Cursor at the right edge (the capture solves to 0.999) brings it back
        // to the left of the authored origin — beside the character, not across
        // the whole screen.
        smoother.reset()
        let revealed = smoother
            .frame(settings: settings, pointerPosition: SIMD2<Double>(1.0, 0.5), time: 0, gain: 1)
            .pixelOffset(
                objectCenter: SIMD2<Double>(1763.895 - 1280, 1087.566 - 720),
                depth: depth, sceneSize: scene
            )
        #expect(abs(revealed.x - (967.8 - 1280)) < 0.5)
        #expect(1763.895 + Double(revealed.x) > 1400, "revealed clock stays on the right half")

        // Depth "4 0" stays horizontal.
        smoother.reset()
        let vertical = smoother
            .frame(settings: settings, pointerPosition: SIMD2<Double>(0.5, 1.0), time: 0, gain: 1)
            .pixelOffset(objectCenter: .zero, depth: depth, sceneSize: scene).y
        #expect(vertical == 0)
    }

    @Test("gain scales the shift; a custom gain overrides the default")
    func pixelOffsetGain() {
        let scene = CGSize(width: 1000, height: 1000)
        let base = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.1, 0.1), amount: 1, influence: 1)
        let strong = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.1, 0.1), amount: 1, influence: 1, gain: 2.0)
        let b = base.pixelOffset(objectCenter: .zero, depth: SIMD2<Double>(1, 1), sceneSize: scene)
        let s = strong.pixelOffset(objectCenter: .zero, depth: SIMD2<Double>(1, 1), sceneSize: scene)
        #expect(abs(s.x - 2 * b.x) < 1e-3)
    }

    @Test("clampedGain: absent/non-finite → default; 0 honored (off); negatives→0; capped")
    func clampedGainResolution() {
        let dflt = WPECameraParallaxFrame.defaultGain
        #expect(WPECameraParallaxFrame.clampedGain(nil) == dflt)
        #expect(WPECameraParallaxFrame.clampedGain(.nan) == dflt)
        #expect(WPECameraParallaxFrame.clampedGain(.infinity) == dflt)
        #expect(WPECameraParallaxFrame.clampedGain(0) == 0)
        #expect(WPECameraParallaxFrame.clampedGain(-3) == 0)
        #expect(WPECameraParallaxFrame.clampedGain(0.8) == 0.8)
        #expect(WPECameraParallaxFrame.clampedGain(1000) == WPECameraParallaxFrame.maxGain)
    }

    @Test("pixelOffset honors per-axis depth: '1 0' horizontal-only, '0 1' vertical-only")
    func pixelOffsetPerAxis() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.3, 0.3), amount: 1, influence: 1)
        let scene = CGSize(width: 1000, height: 1000)
        let horizontalOnly = frame.pixelOffset(objectCenter: .zero, depth: SIMD2<Double>(1, 0), sceneSize: scene)
        #expect(abs(horizontalOnly.x - (-300)) < 1e-3)
        #expect(horizontalOnly.y == 0)
        let verticalOnly = frame.pixelOffset(objectCenter: .zero, depth: SIMD2<Double>(0, 1), sceneSize: scene)
        #expect(verticalOnly.x == 0)
        #expect(abs(verticalOnly.y - (-300)) < 1e-3)
    }

    // MARK: - Smoother

    /// Asserted on the resolved SHIFT rather than on `== .neutral`: the frame
    /// keeps tracking the cursor and carries the authored `mouseinfluence` even
    /// when parallax is off, so `g_ParallaxPosition` still drives `depthparallax`.
    @Test("Disabled / amount 0 produce no layer shift at all")
    func smootherNoOp() {
        var s = WPECameraParallaxSmoother()
        let cursor = SIMD2<Double>(1, 1)
        func shift(_ frame: WPECameraParallaxFrame) -> SIMD2<Float> {
            frame.pixelOffset(
                objectCenter: SIMD2<Double>(800, 600),
                depth: SIMD2<Double>(1, 1),
                sceneSize: CGSize(width: 2560, height: 1440)
            )
        }
        #expect(shift(s.frame(settings: .disabled, pointerPosition: cursor, time: 0)) == SIMD2<Float>(0, 0))
        s.reset()
        #expect(shift(s.frame(settings: .init(enabled: true, amount: 0, delay: 0.1, mouseInfluence: 0.5),
                              pointerPosition: cursor, time: 0)) == SIMD2<Float>(0, 0))
        // `mouseinfluence == 0` is NOT a no-op: it silences the cursor term and
        // leaves the static `(nodePos − camPos)` half, so the layer sits at its
        // parallaxed rest position.
        s.reset()
        #expect(shift(s.frame(settings: .init(enabled: true, amount: 0.5, delay: 0.1, mouseInfluence: 0),
                              pointerPosition: cursor, time: 0)) == SIMD2<Float>(400, 300))
    }

    /// `smoothed` is the RAW cursor offset; `amount`/`mouseinfluence` are
    /// applied per-term inside `pixelOffset`, as the reference does.
    @Test("First frame snaps to the calibrated cursor target")
    func smootherFirstFrameSnap() {
        var s = WPECameraParallaxSmoother()
        let frame = s.frame(settings: .init(enabled: true, amount: 0.5, delay: 0.1, mouseInfluence: 0.5),
                            pointerPosition: SIMD2<Double>(1.0, 0.5), time: 0)
        #expect(abs(frame.smoothed.x - 0.5) < 1e-5)
        #expect(abs(frame.smoothed.y - 0.0) < 1e-5)
    }

    @Test("Smoothing converges to the same offset at 30 vs 144 FPS over equal elapsed time")
    func smootherFrameRateIndependent() {
        let settings = WPESceneCameraParallaxSettings(enabled: true, amount: 0.5, delay: 0.2, mouseInfluence: 0.5)
        let cursor = SIMD2<Double>(1.0, 0.5)
        func run(fps: Double) -> SIMD2<Float> {
            var s = WPECameraParallaxSmoother()
            let dt = 1.0 / fps
            _ = s.frame(settings: settings, pointerPosition: SIMD2<Double>(0.5, 0.5), time: 0)
            var t = 0.0
            while t < 1.0 { t += dt; _ = s.frame(settings: settings, pointerPosition: cursor, time: t) }
            return s.smoothed
        }
        let a = run(fps: 30)
        let b = run(fps: 144)
        #expect(abs(a.x - b.x) < 0.02)
        #expect(abs(a.y - b.y) < 0.02)
    }

    // MARK: - parallaxDepth parsing (the "viewpoint never moves" root cause)

    @Test("parallaxDepth parses WPE's per-axis vector string (not 0)")
    func parsesVectorStringDepth() throws {
        #expect(try parsedImageDepth("1.000 1.000") == SIMD2<Double>(1, 1))
        #expect(try parsedImageDepth("0.50000 0.50000") == SIMD2<Double>(0.5, 0.5))
        #expect(try parsedImageDepth("0.00000 0.00000") == SIMD2<Double>(0, 0))
    }

    @Test("parallaxDepth keeps per-axis values and accepts a dict-wrapped vector")
    func parsesPerAxisAndWrappedDepth() throws {
        #expect(try parsedImageDepth("1 0") == SIMD2<Double>(1, 0))
        #expect(try parsedImageDepth("0 1") == SIMD2<Double>(0, 1))
        #expect(try parsedImageDepth("-0.5 0.25") == SIMD2<Double>(-0.5, 0.25))
        #expect(try parsedImageDepth(["user": "p0", "value": "0.5 0.5"]) == SIMD2<Double>(0.5, 0.5))
    }

    @Test("parallaxDepth still accepts a bare scalar and defaults to 0 when absent")
    func parsesScalarAndAbsentDepth() throws {
        #expect(try parsedImageDepth(2.0) == SIMD2<Double>(2, 2))
        #expect(try parsedImageDepth("3") == SIMD2<Double>(3, 3))
        let doc = try parse(minimalScene(general: [
            "orthogonalprojection": ["width": 100, "height": 100, "auto": true]
        ]))
        #expect(try #require(doc.imageObjects.first).parallaxDepth == SIMD2<Double>(0, 0))
    }

    // MARK: - Depth inheritance

    private func layer(
        _ id: String,
        depth: SIMD2<Double>,
        parent: String? = nil,
        attachment: String? = nil,
        origin: SIMD2<Double>? = nil
    ) -> WPERenderLayer {
        let geometry = origin.map {
            WPERenderLayerGeometry(
                origin: SIMD3<Double>($0.x, $0.y, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 100, height: 100),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            )
        } ?? .identity
        return WPERenderLayer(
            objectID: id, objectName: id, imagePath: "models/util/solidlayer.json",
            materialPath: nil, parentObjectID: parent, attachment: attachment,
            geometry: geometry, compositeA: "_a", compositeB: "_b",
            localFBOs: [], passes: [], parallaxDepth: depth
        )
    }

    @Test("Whole parented rig inherits the root's per-axis depth (3719111841 shape)")
    func parentedRigInheritsRootDepth() {
        let pinned = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents([
            layer("hairRoot", depth: SIMD2<Double>(0.41, -0.36)),
            layer("body", depth: SIMD2<Double>(0, 0), parent: "hairRoot"),
            layer("head", depth: SIMD2<Double>(0, 0), parent: "body", attachment: "头部"),
            layer("eye", depth: SIMD2<Double>(0, 0), parent: "head", attachment: "眼"),
            layer("bg", depth: SIMD2<Double>(-0.17, -0.17))
        ])
        let byID = Dictionary(uniqueKeysWithValues: pinned.map { ($0.objectID, $0.parallaxDepth) })
        #expect(byID["hairRoot"] == SIMD2<Double>(0.41, -0.36))
        #expect(byID["body"] == SIMD2<Double>(0.41, -0.36))
        #expect(byID["head"] == SIMD2<Double>(0.41, -0.36))
        #expect(byID["eye"] == SIMD2<Double>(0.41, -0.36))
        #expect(byID["bg"] == SIMD2<Double>(-0.17, -0.17))
    }

    @Test("Pinning overwrites an intermediate/child's own nonzero depth (rigid-unit policy)")
    func inheritanceOverwritesOwnDepth() {
        let out = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents([
            layer("root", depth: SIMD2<Double>(0.4, 0.4)),
            layer("mid", depth: SIMD2<Double>(0.9, 0.9), parent: "root"),
            layer("leaf", depth: SIMD2<Double>(0, 0), parent: "mid")
        ])
        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0.objectID, $0.parallaxDepth) })
        #expect(byID["root"] == SIMD2<Double>(0.4, 0.4))
        #expect(byID["mid"] == SIMD2<Double>(0.4, 0.4))
        #expect(byID["leaf"] == SIMD2<Double>(0.4, 0.4))
    }

    @Test("A depth-0 root pins its children to 0 (Clock/Day/Date stay put)")
    func zeroDepthRootKeepsChildrenStill() {
        let out = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents([
            layer("clock", depth: SIMD2<Double>(0, 0)),
            layer("day", depth: SIMD2<Double>(0, 0), parent: "clock"),
            layer("date", depth: SIMD2<Double>(0, 0), parent: "clock")
        ])
        #expect(out.allSatisfy { $0.parallaxDepth == SIMD2<Double>(0, 0) })
    }

    @Test("No parented layers → input returned unchanged")
    func noParentsNoOp() {
        let input = [layer("a", depth: SIMD2<Double>(1, 1)), layer("b", depth: SIMD2<Double>(0.5, 0.5))]
        let out = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents(input)
        #expect(out == input)
    }

    @Test("A parent missing from the graph stops the walk at the last resolvable node")
    func danglingParentStopsWalk() {
        let out = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents([
            layer("child", depth: SIMD2<Double>(0, 0), parent: "ghost")
        ])
        #expect(out.first?.parallaxDepth == SIMD2<Double>(0, 0))
    }

    // MARK: - Static-term anchor (one offset per parallax root)

    /// 3719111841's ortho, `cameraparallaxamount` and rig, with the cursor dead
    /// centre so only the static `(nodePos - camPos)` term is live.
    private static let rigScene = CGSize(width: 3840, height: 2160)
    private static let rigDepth = SIMD2<Double>(0.41, -0.36)

    private func rigFrame() -> WPECameraParallaxFrame {
        var smoother = WPECameraParallaxSmoother()
        return smoother.frame(
            settings: WPESceneCameraParallaxSettings(
                enabled: true, amount: 0.34999999, delay: 0, mouseInfluence: 0.25
            ),
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            time: 0,
            gain: 1
        )
    }

    /// Exactly what `objectQuadUniforms` does: the parallax-root centre when the
    /// layer has one, its own anchor otherwise.
    private func resolvedShift(
        _ layer: WPERenderLayer,
        centers: [String: SIMD2<Float>]
    ) -> SIMD2<Float> {
        let scene = Self.rigScene
        let centre = centers[layer.objectID]
            ?? WPEMetalRenderExecutor.centeredOrigin(of: layer.geometry, sceneSize: scene)
        return rigFrame().pixelOffset(
            objectCenter: SIMD2<Double>(Double(centre.x), Double(centre.y)),
            depth: layer.parallaxDepth,
            sceneSize: scene
        )
    }

    /// WPE shifts a parented subtree by ONE vector — its root's. Ground truth:
    /// both 3719111841 RenderDoc captures put the `g_ModelViewProjectionMatrix`
    /// translation of the root (475 长发3) and of its child (91 主体) the same
    /// distance from their authored origins, agreeing to 3.5e-5 scene px.
    ///
    /// Evaluating the static term per child instead scales the whole subtree
    /// about the scene centre by `(1 + depth·amount)` = (1.1435, 0.8740) here —
    /// a 12.6% vertical squash of the character, measured on the live capture as
    /// a (+109.87, -145.13) px tear between the ear and the hair root.
    @Test("3719111841: every layer of a parented rig gets the ROOT's parallax shift")
    func parentedRigSharesTheRootsShift() {
        // Origins as the executor sees them at t=49.93: the root's authored
        // origin, and the ear's attachment-driven live anchor from the capture.
        let layers = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents([
            layer("475", depth: Self.rigDepth, origin: SIMD2<Double>(1238.14209, 704.67969)),
            layer("91", depth: .zero, parent: "475", origin: SIMD2<Double>(1967.3861, 919.1593)),
            layer("303", depth: .zero, parent: "91", attachment: "头",
                  origin: SIMD2<Double>(2003.8204, 1856.5045)),
            layer("209", depth: .zero, origin: SIMD2<Double>(3504.84229, 1434.96655))
        ])
        let centers = WPEMetalRenderExecutor.parallaxRootCenters(
            for: layers, sceneSize: Self.rigScene
        )
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.objectID, $0) })
        let rootShift = resolvedShift(byID["475"]!, centers: centers)

        // The root's own shift is the reference value, unchanged by this rule.
        #expect(abs(rootShift.x - (-97.8466)) < 0.01)
        #expect(abs(rootShift.y - 47.2904) < 0.01)
        // Both descendants ride it exactly — no tear, at any depth of nesting.
        #expect(resolvedShift(byID["91"]!, centers: centers) == rootShift)
        #expect(resolvedShift(byID["303"]!, centers: centers) == rootShift)
        // An unparented depth-0 object stays put.
        #expect(resolvedShift(byID["209"]!, centers: centers) == SIMD2<Float>(0, 0))
    }

    @Test("parallaxRootCenters: roots keep their own anchor; dangling parents and cycles terminate")
    func parallaxRootCentersScope() {
        let centers = WPEMetalRenderExecutor.parallaxRootCenters(
            for: [
                layer("root", depth: SIMD2<Double>(1, 1), origin: SIMD2<Double>(1000, 800)),
                layer("child", depth: .zero, parent: "root", origin: SIMD2<Double>(1500, 900)),
                layer("orphan", depth: .zero, parent: "ghost", origin: SIMD2<Double>(200, 200)),
                layer("loopA", depth: .zero, parent: "loopB", origin: SIMD2<Double>(10, 10)),
                layer("loopB", depth: .zero, parent: "loopA", origin: SIMD2<Double>(20, 20))
            ],
            sceneSize: Self.rigScene
        )
        // A root is absent from the map and falls back to its own anchor.
        #expect(centers["root"] == nil)
        #expect(centers["child"] == SIMD2<Float>(1000 - 1920, 800 - 1080))
        // A parent outside the graph leaves the layer as its own root.
        #expect(centers["orphan"] == nil)
        // A cycle walks back to where it started, so each node stays its own
        // root — no entry, and no hang.
        #expect(centers["loopA"] == nil)
        #expect(centers["loopB"] == nil)
    }

    // MARK: - Rigid subtree across group hosts (3448877775)

    /// Windows ground truth (fidelity-3448877775_1/_2): every text in the clock
    /// assembly shifts by the same (5.31, 7.97) px — the GROUP's depth -0.408 —
    /// while the leaves author -0.7 / 0 / 1.0. The chain to that group runs
    /// through non-drawn hosts, so the walk must cross them.
    @Test("Depth propagation crosses non-drawn group hosts, and the root wins")
    func depthPropagationCrossesGroupHosts() {
        let out = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents(
            [
                layer("clockText", depth: SIMD2<Double>(-0.70, -0.70), parent: "clockGroup"),
                layer("dayText", depth: SIMD2<Double>(0, 0), parent: "dayGroup"),
                layer("bg", depth: SIMD2<Double>(-0.92, -0.92))
            ],
            objectParentByID: [
                "clockText": "clockGroup", "clockGroup": "assembly",
                "dayText": "dayGroup", "dayGroup": "assembly"
            ],
            hostDepthByObjectID: [
                "clockGroup": SIMD2<Double>(0, 0),
                "dayGroup": SIMD2<Double>(0, 0),
                "assembly": SIMD2<Double>(-0.408, -0.408)
            ]
        )
        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0.objectID, $0.parallaxDepth) })
        // The authored leaf depths are provably ignored on Windows — even 0.
        #expect(byID["clockText"] == SIMD2<Double>(-0.408, -0.408))
        #expect(byID["dayText"] == SIMD2<Double>(-0.408, -0.408))
        #expect(byID["bg"] == SIMD2<Double>(-0.92, -0.92))
    }

    @Test("Root centers cross group hosts and anchor at the host's origin")
    func rootCentersCrossGroupHosts() {
        let centers = WPEMetalRenderExecutor.parallaxRootCenters(
            for: [
                layer("clockText", depth: SIMD2<Double>(-0.408, -0.408), parent: "clockGroup",
                      origin: SIMD2<Double>(3352, 1189)),
                layer("dayText", depth: SIMD2<Double>(-0.408, -0.408), parent: "dayGroup",
                      origin: SIMD2<Double>(1920, 1080))
            ],
            sceneSize: CGSize(width: 3840, height: 2160),
            objectParentByID: [
                "clockText": "clockGroup", "clockGroup": "assembly",
                "dayText": "dayGroup", "dayGroup": "assembly"
            ],
            hostDepthByObjectID: [
                "clockGroup": SIMD2<Double>(0, 0),
                "dayGroup": SIMD2<Double>(0, 0),
                "assembly": SIMD2<Double>(-0.408, -0.408)
            ],
            hostOriginByObjectID: [
                "clockGroup": SIMD2<Double>(2408, 971),
                "dayGroup": SIMD2<Double>(1920, 1080),
                "assembly": SIMD2<Double>(1920, 1080)
            ]
        )
        // BOTH leaves anchor at the assembly root, so their static terms agree
        // and the assembly stays rigid at rest.
        #expect(centers["clockText"] == SIMD2<Float>(0, 0))
        #expect(centers["dayText"] == SIMD2<Float>(0, 0))
    }

    /// The captures only prove that an authored ancestor value wins. A topmost
    /// group that authored NO depth parses to zero — zeroing its children on
    /// that basis would kill 93 corpus objects (3151551777 birds, 3351072238's
    /// FPS triangles) with no evidence, so the anchor is the root-most
    /// NON-ZERO node on the path, the leaf itself when the path is flat.
    @Test("A key-less group root does not zero its children's authored depth")
    func keylessGroupRootKeepsChildDepth() {
        let out = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents(
            [layer("fpsTriangle", depth: SIMD2<Double>(-0.7, -0.7), parent: "fpsGroup")],
            objectParentByID: ["fpsTriangle": "fpsGroup", "fpsGroup": "panel"],
            hostDepthByObjectID: [
                "fpsGroup": SIMD2<Double>(0, 0),
                "panel": SIMD2<Double>(0, 0)
            ]
        )
        #expect(out.first?.parallaxDepth == SIMD2<Double>(-0.7, -0.7))
    }

    @Test("A group host parses its authored parallaxDepth, envelope included")
    func transformHostParsesParallaxDepth() throws {
        let doc = try parse([
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160, "auto": true]],
            "objects": [
                [
                    "id": "4995", "name": "assembly", "visible": true,
                    "origin": "1920 1080 0",
                    "parallaxDepth": ["user": "newproperty1", "value": "-0.40800 -0.40800"]
                ],
                [
                    "id": "394", "name": "Clock", "type": "text", "visible": true,
                    "text": "12:34", "parent": "4995", "origin": "100 100 0",
                    "parallaxDepth": "-0.70000 -0.70000"
                ]
            ]
        ])
        let host = try #require(doc.transformHostObjects.first { $0.id == "4995" })
        #expect(host.parallaxDepth == SIMD2<Double>(-0.408, -0.408))
        let text = try #require(doc.textObjects.first { $0.id == "394" })
        #expect(text.parallaxDepth == SIMD2<Double>(-0.7, -0.7))
    }

    // MARK: - Axis conventions

    @Test("The cursor term opposes the cursor on BOTH axes, not just x")
    func mouseTermOpposesCursorOnBothAxes() {
        // `WPShaderValueUpdater.cpp` builds the cursor term in the scene's +y-up
        // world (`Scaling(1,-1) * (0.5 - mouse)`, mouse y-down); the object quad
        // lives in top-left y-down scene pixels, so the world y has to be negated
        // on the way in. Keeping it made every parallaxed layer chase the cursor
        // vertically while opposing it horizontally.
        let frame = WPECameraParallaxFrame(
            smoothed: SIMD2<Float>(0.25, 0.25), amount: 1, influence: 1
        )
        let shift = frame.pixelOffset(
            objectCenter: .zero,
            depth: SIMD2<Double>(1, 1),
            sceneSize: CGSize(width: 1000, height: 1000)
        )
        #expect(shift.x == -250)
        #expect(shift.y == -250)
    }

    @Test("A disabled camera parallax still reports mouseinfluence")
    func disabledParallaxStillReportsInfluence() {
        // The reference computes `g_ParallaxPosition` from `mouseinfluence`
        // unconditionally — only the per-layer translation is gated on `enable`.
        // Zeroing influence here silently pinned every `depthparallax` effect.
        var smoother = WPECameraParallaxSmoother()
        let frame = smoother.frame(
            settings: WPESceneCameraParallaxSettings(
                enabled: false, amount: 0.15, delay: 0, mouseInfluence: 0.31
            ),
            pointerPosition: SIMD2<Double>(1, 1),
            time: 0
        )
        #expect(frame.amount == 0)
        #expect(abs(frame.influence - 0.31) < 1e-9)
    }

    @Test("g_ParallaxPosition is the influence-scaled, y-flipped offset about 0.5")
    func parallaxPositionUniformFollowsReference() {
        // Built from the SMOOTHED cursor, like every other parallax consumer:
        // the reference feeds `m_mousePos` to both the per-layer translation and
        // this uniform. Reading the raw pointer here let the `depthparallax`
        // layer snap instantly to full deflection while its neighbours crawled
        // behind a 2 s `cameraparallaxdelay` — the layer that "came unstuck".
        func value(smoothed: SIMD2<Float>, influence: Double) -> [Double] {
            var uniforms = WPEMetalRuntimeUniforms(
                time: 0, daytime: 0, brightness: 1,
                // Deliberately far from `smoothed`: the raw pointer must not leak in.
                pointerPosition: SIMD2<Double>(1, 1)
            )
            uniforms.cameraParallax = WPECameraParallaxFrame(
                smoothed: smoothed, amount: 0.1, influence: influence
            )
            guard case let .vector(v)? = uniforms.uniformValues["g_ParallaxPosition"] else {
                return []
            }
            return v
        }
        // `depthparallax.vert` reads `g_ParallaxPosition * 2 - 1`, so 0.5 is the
        // neutral centre — and it stays neutral at any influence.
        #expect(value(smoothed: SIMD2<Float>(0, 0), influence: 0.31) == [0.5, 0.5])
        // Amplitude is `mouseinfluence`. Feeding the raw pointer (we did until
        // now) drove the effect 1/influence too hard — 3.2x on 3462279189.
        let right = value(smoothed: SIMD2<Float>(0.5, 0), influence: 0.31)
        #expect(abs(right[0] - (0.5 + 0.5 * 0.31)) < 1e-9)
        // Our pointer is y-down; the shader's parallax axis is y-up.
        let bottom = value(smoothed: SIMD2<Float>(0, 0.5), influence: 0.31)
        #expect(abs(bottom[1] - (0.5 - 0.5 * 0.31)) < 1e-9)
    }

    // MARK: - Delay model

    /// `cameraparallaxdelay` is a ramp on the lerp factor, not an exponential
    /// time constant (`WPShaderValueUpdater.cpp` FrameBegin/MouseInput): idle
    /// time accumulates to `delay`, `t = idle / delay`, and each cursor event
    /// knocks the accumulator back by the gap since the previous one. So a
    /// settled cursor lands EXACTLY on target within `delay`, where our
    /// exponential was still ~37% short of it and kept undershooting — the
    /// "other layers barely move" half of the disconnect.
    @Test("A settled cursor reaches the full offset within cameraparallaxdelay")
    func settledCursorConvergesExactly() {
        var smoother = WPECameraParallaxSmoother()
        let settings = WPESceneCameraParallaxSettings(
            enabled: true, amount: 0.1, delay: 2, mouseInfluence: 0.31
        )
        let step = 1.0 / 60.0
        var time = 0.0
        // Frame 0 seeds at centre, then the cursor jumps to the corner and stays.
        _ = smoother.frame(settings: settings, pointerPosition: SIMD2<Double>(0.5, 0.5), time: time)
        for _ in 0..<Int(2.0 / step) + 2 {
            time += step
            _ = smoother.frame(settings: settings, pointerPosition: SIMD2<Double>(1, 1), time: time)
        }
        #expect(smoother.smoothed == SIMD2<Float>(0.5, 0.5))
    }

    @Test("mouseInfluence 0 silences the cursor term but keeps the static one")
    func zeroInfluenceKeepsAmount() {
        // The reference gates the whole translation on `enable` alone; zeroing
        // `amount` here also deleted the `(nodePos - camPos)` term.
        var smoother = WPECameraParallaxSmoother()
        let frame = smoother.frame(
            settings: WPESceneCameraParallaxSettings(
                enabled: true, amount: 0.5, delay: 0, mouseInfluence: 0
            ),
            pointerPosition: SIMD2<Double>(1, 1),
            time: 0
        )
        #expect(frame.amount == 0.5)
        #expect(frame.influence == 0)
    }
}
