import Foundation
import LiveWallpaperProWPE
@testable import LiveWallpaper
import Testing

/// `lib.sceneScript.d.ts` declares both hooks with the same contract:
///
///     init?(value: Number|Boolean|String|Vec2|Vec3|Vec4|Mat4|Mat3): Number|…|Vec4;
///
/// documented as "The modified value to be applied to the property", with
/// `update()` marked "entirely optional". We called `init` and threw its return
/// away at all three runtimes, so a module exporting only `init` was a no-op.
/// 13 of the 54 installed scenes carry at least one such script.
@Suite(.serialized)
@MainActor
struct WPESceneScriptInitReturnTests {
    private let isolatedGovernor = WPESceneScriptExecutionGovernor(limit: 4)

    private func transform(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        seed: SIMD3<Double>,
        valueShape: WPEScriptValueShape = .vector3,
        canvasSize: SIMD2<Double> = SIMD2(1920, 1080),
        ownLayerName: String? = nil,
        ownObjectID: String? = nil,
        shared: WPESharedScriptState? = nil
    ) throws -> WPEDynamicTransformScriptInstance {
        try WPEDynamicTransformScriptInstance(
            script: script,
            scriptProperties: scriptProperties,
            seed: seed,
            valueShape: valueShape,
            canvasSize: canvasSize,
            ownLayerName: ownLayerName,
            ownObjectID: ownObjectID,
            shared: shared,
            setupBudget: 2,
            tickBudget: 0.5,
            governor: isolatedGovernor
        )
    }

    private func text(
        script: String,
        initialValue: String,
        shared: WPESharedScriptState? = nil
    ) throws -> WPESceneScriptInstance {
        try WPESceneScriptInstance(
            script: script,
            initialValue: initialValue,
            shared: shared,
            setupBudget: 2,
            tickBudget: 0.5,
            governor: isolatedGovernor
        )
    }

    // MARK: - Real scene reproduction

    private enum OriginScriptFixture {
        static let objectID = "131"
        static let layerName = "Media Info (ROUND)"
        /// `origin.value` as authored, on this scene's 3840x2160 canvas.
        static let authoredOrigin = SIMD3<Double>(183.649_90, 768.382_08, 0)
        static let canvas = SIMD2<Double>(3840, 2160)
        static let scriptProperties: [String: WPESceneScriptPropertyValue] = ["isMovable": .bool(true)]
        /// Copied verbatim out of the installed package's `scene.json`
        /// (`objects[id=131].origin.script`), so the body under test is the
        /// author's rather than a paraphrase. Kept inline because
        /// `LiveWallpaperTests/Fixtures/*` is gitignored (.gitignore:124) and a
        /// file there would not survive a clean checkout.
        static let script = #"""
        'use strict';
        // Please note: Do not remove this line or asset references may break.
        export let __workshopId = '3219510589';

        export var scriptProperties = createScriptProperties()
            .addCheckbox({
                name: 'isMovable',
                label: 'Is movable',
                value: false
            })
            .finish();

        const storageName = "storedPosRoundMIC";
        let isDragging = false, dragOffset, timer;

        export function cursorDown(event) {
            timer = Date.now();
            isDragging = true;
            dragOffset = thisLayer.origin.subtract(event.worldPosition);
        }

        export function cursorUp(event) {
            isDragging = false;
            localStorage.set(storageName, thisLayer.origin);
        }

        export function cursorMove(event) {
            const overClick = Date.now() - timer > 50;
            if (!overClick) dragOffset = thisLayer.origin.subtract(event.worldPosition);

            if (isDragging && scriptProperties.isMovable && shared.miDragable && overClick) {
                thisLayer.origin = event.worldPosition.add(dragOffset);
            }
        }

        export function init() {
            shared.miDragable = localStorage.get("miDragable");
            shared.miDragable = shared.miDragable == undefined ? scriptProperties.isMovable : shared.miDragable;
            return localStorage.get(storageName) || thisLayer.origin;
        }
        """#
    }

    /// Scene 3326873240's `Media Info (ROUND)` (id 131) binds an origin script
    /// exporting `cursorDown`/`cursorUp`/`cursorMove`/`init` and NO `update`.
    /// Its `init` ends `return localStorage.get(storageName) || thisLayer.origin`,
    /// so with empty storage it returns the authored origin. Dropping that return
    /// left the panel at the baked fallback — on screen the whole media panel
    /// collapsed to roughly (0,0), dragging Song Title, Artist Name and its
    /// Background off the canvas with it.
    @Test("The real init-only origin script yields the authored origin, not nil")
    func realSceneOriginScriptYieldsAuthoredOrigin() throws {
        let authored = OriginScriptFixture.authoredOrigin
        let shared = WPESharedScriptState(layers: [
            WPESceneScriptLayerInfo(
                id: OriginScriptFixture.objectID,
                name: OriginScriptFixture.layerName,
                size: SIMD2(512, 512),
                origin: SIMD2(authored.x, authored.y),
                originZ: authored.z,
                scale: SIMD3(0.4, 0.4, 0.75),
                index: 0,
                parentName: nil
            ),
        ])

        let instance = try transform(
            script: OriginScriptFixture.script,
            scriptProperties: OriginScriptFixture.scriptProperties,
            seed: .zero, // the renderer's fallback when the script yields nothing
            canvasSize: OriginScriptFixture.canvas,
            ownLayerName: OriginScriptFixture.layerName,
            shared: shared
        )

        let ticked = try #require(
            instance.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0),
            "init returned thisLayer.origin; the property must receive it instead of nil"
        )
        #expect(abs(ticked.x - authored.x) < 0.001, "x was \(ticked.x), authored \(authored.x)")
        #expect(abs(ticked.y - authored.y) < 0.001, "y was \(ticked.y), authored \(authored.y)")
    }

    // MARK: - Part 1 contract

    @Test("An init-only script's returned value reaches the transform property")
    func initOnlyTransformValueReachesProperty() throws {
        let instance = try transform(
            script: "export function init(value) { return {x: 7, y: 8, z: 9}; }",
            seed: SIMD3(1, 2, 3)
        )
        #expect(instance.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0) == SIMD3(7, 8, 9))
    }

    @Test("An init-only script's returned value reaches the text property")
    func initOnlyTextValueReachesProperty() throws {
        let instance = try text(
            script: "export function init(value) { return 'from-init'; }",
            initialValue: "authored"
        )
        #expect(instance.lastValue == "from-init")
        #expect(instance.batchTickString(runtimeSeconds: 0).value == "from-init")
    }

    /// `init` receives the authored value as its argument — the audio-response
    /// templates stash it as `initialValue` and multiply by it every frame.
    @Test("init still receives the authored value as its argument")
    func initReceivesAuthoredValue() throws {
        let instance = try text(
            script: "export function init(value) { return 'saw:' + value; }",
            initialValue: "authored"
        )
        #expect(instance.lastValue == "saw:authored")

        let vector = try transform(
            script: "export function init(value) { return {x: value.x * 2, y: value.y * 2, z: value.z}; }",
            seed: SIMD3(1.5, 2.5, 3.5)
        )
        #expect(vector.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0) == SIMD3(3, 5, 3.5))
    }

    /// The common case: nearly every authored `init` only primes module state.
    @Test("An init returning nothing leaves the authored value untouched")
    func initReturningUndefinedLeavesAuthoredValueIntact() throws {
        let instance = try text(
            script: "export function init(value) { let unused = 1; }",
            initialValue: "authored"
        )
        #expect(instance.lastValue == "authored", "a void init must not blank the property")

        let vector = try transform(
            script: "export function init(value) { let unused = 1; }",
            seed: SIMD3(4, 5, 6)
        )
        #expect(
            vector.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0) == nil,
            "a void init must not fabricate a value; the caller keeps the baked transform"
        )
    }

    /// Guard on the common case: `init` for setup + `update` per frame must be
    /// exactly what it was — update's argument and return both unchanged.
    @Test("An init plus update script behaves exactly as before")
    func initPlusUpdateUnchanged() throws {
        let instance = try text(
            script: """
            let base = '';
            export function init(value) { base = value; }
            export function update(value) { return base + '/ticked'; }
            """,
            initialValue: "authored"
        )
        #expect(instance.lastValue == "authored", "before any tick the property is the authored value")
        #expect(instance.tickString(runtimeSeconds: 0) == "authored/ticked")

        let vector = try transform(
            script: """
            export function init(value) { }
            export function update(value) { return {x: value.x + 1, y: value.y, z: value.z}; }
            """,
            seed: SIMD3(1, 2, 3)
        )
        #expect(vector.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0) == SIMD3(2, 2, 3))
        #expect(vector.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 1) == SIMD3(3, 2, 3))
    }

    /// An `init` return seeds the property, and `update` then ticks from it.
    @Test("update receives the value init returned")
    func updateTicksFromInitResult() throws {
        let instance = try transform(
            script: """
            export function init(value) { return {x: 10, y: 10, z: 10}; }
            export function update(value) { return {x: value.x + 1, y: value.y, z: value.z}; }
            """,
            seed: SIMD3(0, 0, 0)
        )
        #expect(instance.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0) == SIMD3(11, 10, 10))
    }

    /// An init-only module has nothing to run per frame. It must hold its value
    /// without ever scheduling a batch job — and holding matters for correctness,
    /// not just cost: a scheduled tick would publish nil and snap the layer back.
    @Test("An init-only script is not forced onto a per-frame tick")
    func initOnlyScriptSchedulesNoPerFrameWork() throws {
        let instance = try transform(
            script: "export function init(value) { return {x: 7, y: 8, z: 9}; }",
            seed: SIMD3(1, 2, 3)
        )
        for frame in 0 ..< 4 {
            let (value, job) = instance.batchTick(
                pointerPosition: SIMD2(0.5, 0.5),
                runtimeSeconds: Double(frame)
            )
            #expect(job == nil, "frame \(frame) scheduled a JS job for a script with no update()")
            #expect(value == SIMD3(7, 8, 9), "frame \(frame) lost the value init returned")
        }
    }

    @Test("A script with update still schedules its per-frame job")
    func updateScriptStillSchedulesWork() throws {
        let instance = try transform(
            script: "export function update(value) { return value; }",
            seed: SIMD3(1, 2, 3)
        )
        let (_, job) = instance.batchTick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0)
        #expect(job != nil, "a script exporting update must still be ticked")
    }

    // MARK: - Layer runtime

    @Test("An init-only visible script's returned boolean hides the layer")
    func initOnlyVisibleReturnDrivesVisibility() throws {
        let instance = try WPELayerScriptInstance(
            script: "export function init() { return false; }",
            outputMode: .layerState,
            initialVisible: true,
            governor: isolatedGovernor
        )
        #expect(instance.initialOutput.own.visible == false)
    }

    @Test("An init-only alpha script's returned number sets the layer alpha")
    func initOnlyAlphaReturnDrivesAlpha() throws {
        let instance = try WPELayerScriptInstance(
            script: "export function init() { return 0.25; }",
            outputMode: .returnedAlpha(initialValue: 1),
            governor: isolatedGovernor
        )
        #expect(abs(instance.initialOutput.own.alpha - 0.25) < 0.0001)
    }

    @Test("A layer init returning nothing leaves the authored state intact")
    func layerInitReturningUndefinedLeavesStateIntact() throws {
        let instance = try WPELayerScriptInstance(
            script: "export function init() { }",
            outputMode: .layerState,
            initialVisible: true,
            governor: isolatedGovernor
        )
        #expect(instance.initialOutput.own.visible == true)
    }

    // MARK: - Part 2 pin: name collisions

    /// `WPESharedScriptState.layerTransform(named:)` resolves with
    /// `layers.first(where: { $0.name == name })`. Scene 3326873240 has `Clock`
    /// six times and `Date` four times, so this is not hypothetical: the second
    /// and later rows are unreachable and silently answer with the first row's
    /// transform. Pinned as current behaviour, not endorsed.
    @Test("A duplicate layer name resolves to the first row, shadowing the rest")
    func duplicateLayerNameResolvesToFirstRow() throws {
        let shared = WPESharedScriptState(layers: [
            WPESceneScriptLayerInfo(
                id: "first", name: "Clock", size: SIMD2(10, 10),
                origin: SIMD2(100, 200), index: 0, parentName: nil
            ),
            WPESceneScriptLayerInfo(
                id: "second", name: "Clock", size: SIMD2(20, 20),
                origin: SIMD2(900, 800), index: 1, parentName: nil
            ),
        ])
        #expect(shared.layerTransform(named: "Clock")?.info.id == "first")

        // And a script naming it gets the first row's origin, whichever it meant.
        let instance = try transform(
            script: "export function init(value) { return thisScene.getLayer('Clock').origin; }",
            seed: .zero,
            ownLayerName: "Clock",
            shared: shared
        )
        #expect(instance.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0) == SIMD3(100, 200, 0))
    }

    /// `layerHandle(named:)` answers an unknown name with the neutral stub, so a
    /// script naming a particle/sound layer (absent from `scriptLayerTable`) or
    /// simply misspelling one reads origin (0,0,0) rather than failing.
    @Test("An unknown layer name yields the neutral zero-origin handle")
    func unknownLayerNameYieldsNeutralHandle() throws {
        let shared = WPESharedScriptState(layers: [
            WPESceneScriptLayerInfo(
                id: "only", name: "Background", size: SIMD2(10, 10),
                origin: SIMD2(100, 200), index: 0, parentName: nil
            ),
        ])
        #expect(shared.layerTransform(named: "NoSuchLayer") == nil)

        let instance = try transform(
            script: "export function init(value) { return thisScene.getLayer('NoSuchLayer').origin; }",
            seed: SIMD3(5, 5, 5),
            ownLayerName: "Background",
            shared: shared
        )
        #expect(instance.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0) == SIMD3(0, 0, 0))
    }

    // MARK: - Part 3: unnamed own layer resolves by object ID

    /// Scene 3554161528's clock (object 398, `name: ""`) is the movable-widget
    /// template: init-only, ending `return thisLayer.origin`. The name-keyed
    /// bridge cannot see an unnamed layer, so `thisLayer` fell back to the
    /// sandbox stub whose `x`/`y`/`z` read 0 — and once init returns are applied,
    /// that (0,0,0) was published every frame, pinning the clock to the scene
    /// corner. Own identity must resolve by OBJECT ID, which every object has.
    @Test("An unnamed own layer resolves thisLayer by object ID")
    func unnamedOwnLayerResolvesByObjectID() throws {
        let authored = SIMD3<Double>(1195.38159, 1337.07593, 0)
        let shared = WPESharedScriptState(layers: [
            WPESceneScriptLayerInfo(
                id: "398", name: "", size: SIMD2(500, 100),
                origin: SIMD2(authored.x, authored.y), index: 0, parentName: nil
            ),
        ])
        let script = "export function init(value) { return thisLayer.origin; }"

        let instance = try transform(
            script: script,
            seed: authored,
            ownLayerName: "",
            ownObjectID: "398",
            shared: shared
        )
        #expect(
            instance.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0) == authored,
            "thisLayer.origin must be the layer-table origin, not the sandbox stub's zeros"
        )

        // Control: without an object ID the old name-only identity still reads
        // the stub's zeros — proving the expectation above has teeth.
        let control = try transform(
            script: script,
            seed: authored,
            ownLayerName: "",
            shared: shared
        )
        #expect(control.tick(pointerPosition: SIMD2(0.5, 0.5), runtimeSeconds: 0) == SIMD3(0, 0, 0))
    }
}
