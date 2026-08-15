import Foundation
import JavaScriptCore
import LiveWallpaperProWPE
@testable import LiveWallpaper
import Testing

@Suite(.serialized)
@MainActor
struct WPESceneScriptRuntimeTests {
    private let isolatedGovernor = WPESceneScriptExecutionGovernor(limit: 4)

    private func WPESceneScriptInstance(
        script: String,
        initialValue: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shared: WPESharedScriptState? = nil,
        setupBudget: TimeInterval = 2,
        tickBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor? = nil,
        canvasSize: SIMD2<Double>? = nil
    ) throws -> LiveWallpaper.WPESceneScriptInstance {
        try LiveWallpaper.WPESceneScriptInstance(
            script: script,
            initialValue: initialValue,
            scriptProperties: scriptProperties,
            shared: shared,
            setupBudget: setupBudget,
            tickBudget: tickBudget,
            governor: governor ?? isolatedGovernor,
            canvasSize: canvasSize
        )
    }

    private func WPELayerScriptInstance(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shared: WPESharedScriptState? = nil,
        canvasSize: SIMD2<Double> = SIMD2<Double>(1920, 1080),
        setupBudget: TimeInterval = 2,
        tickBudget: TimeInterval = 0.5,
        nowProviderMillis: (@Sendable () -> Double)? = nil,
        outputMode: WPELayerScriptOutputMode = .layerState,
        initialVisible: Bool = true,
        initialAlpha: Double = 1,
        ownLayerName: String? = nil,
        governor: WPESceneScriptExecutionGovernor? = nil
    ) throws -> LiveWallpaper.WPELayerScriptInstance {
        try LiveWallpaper.WPELayerScriptInstance(
            script: script,
            scriptProperties: scriptProperties,
            shared: shared,
            canvasSize: canvasSize,
            setupBudget: setupBudget,
            tickBudget: tickBudget,
            nowProviderMillis: nowProviderMillis,
            outputMode: outputMode,
            initialVisible: initialVisible,
            initialAlpha: initialAlpha,
            ownLayerName: ownLayerName,
            governor: governor ?? isolatedGovernor
        )
    }

    private func WPETransformScriptEvaluator(
        canvasWidth: Double,
        canvasHeight: Double,
        evaluationBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor? = nil
    ) -> LiveWallpaper.WPETransformScriptEvaluator {
        LiveWallpaper.WPETransformScriptEvaluator(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            evaluationBudget: evaluationBudget,
            governor: governor ?? isolatedGovernor
        )
    }

    private func WPEDynamicTransformScriptInstance(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        seed: SIMD3<Double>,
        valueShape: WPEScriptValueShape = .vector3,
        canvasSize: SIMD2<Double>,
        shared: WPESharedScriptState? = nil,
        setupBudget: TimeInterval = 2,
        tickBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor? = nil
    ) throws -> LiveWallpaper.WPEDynamicTransformScriptInstance {
        try LiveWallpaper.WPEDynamicTransformScriptInstance(
            script: script,
            scriptProperties: scriptProperties,
            seed: seed,
            valueShape: valueShape,
            canvasSize: canvasSize,
            shared: shared,
            setupBudget: setupBudget,
            tickBudget: tickBudget,
            governor: governor ?? isolatedGovernor
        )
    }

    // 2955378002's calendar is 186 sprites whose `visible` scripts are pure
    // `update() { return <bool> }` — the official contract applies the RETURN
    // value to the property. Dropping it froze every sprite at the authored
    // seed, so the date stayed at the author's save day (11/3, a Saturday).
    // 285 of the 392 visible scripts across the local corpus use this form.
    @Test("A visible script's returned boolean drives the layer's visibility")
    func visibleScriptReturnValueDrivesOwnVisibility() throws {
        let instance = try WPELayerScriptInstance(
            script: "export function update(value) { return false; }",
            outputMode: .layerState,
            initialVisible: true
        )
        let output = try #require(instance.tick(runtimeSeconds: 1))
        #expect(output.own.visible == false, "returned false must hide the layer")
        #expect(output.own.visibleAssigned, "a returned value counts as an assignment")

        // Assignment-style scripts return undefined — the seed must survive.
        let assigning = try WPELayerScriptInstance(
            script: "export function update(value) { }",
            outputMode: .layerState,
            initialVisible: true
        )
        let untouched = try #require(assigning.tick(runtimeSeconds: 1))
        #expect(untouched.own.visible == true, "undefined return must not clobber the seed")

        // The current value rides update(value), so toggling scripts can flip it.
        let toggling = try WPELayerScriptInstance(
            script: "export function update(value) { return !value; }",
            outputMode: .layerState,
            initialVisible: true
        )
        let flipped = try #require(toggling.tick(runtimeSeconds: 1))
        #expect(flipped.own.visible == false)
        let flippedBack = try #require(toggling.tick(runtimeSeconds: 2))
        #expect(flippedBack.own.visible == true)
    }

    /// The value handed to `update(value)` must be the layer's LIVE visibility,
    /// not the last value a script happened to RETURN. Assignment-style scripts
    /// (`thisLayer.visible = …`, returning undefined) never produce a return
    /// value, so feeding the previous return back in pinned them to the authored
    /// seed forever: `thisLayer.visible = !value` re-inverted the same seed every
    /// frame instead of alternating. Both styles land in the same place — the
    /// return path writes through `setOwnLayerVisible`, which goes through the
    /// very `defineProperty` setter an assignment uses.
    @Test("An assignment-style visible script is fed its own live value, not the seed")
    func assignmentStyleVisibleScriptSeesLiveValue() throws {
        let instance = try WPELayerScriptInstance(
            script: "export function update(value) { thisLayer.visible = !value; }",
            outputMode: .layerState,
            initialVisible: true
        )
        let first = try #require(instance.tick(runtimeSeconds: 1))
        #expect(first.own.visible == false, "the seed inverts on the first tick")
        let second = try #require(instance.tick(runtimeSeconds: 2))
        #expect(second.own.visible == true, "and back again: \(second.own.visible)")
        let third = try #require(instance.tick(runtimeSeconds: 3))
        #expect(third.own.visible == false, "alternating, not stuck: \(third.own.visible)")
    }

    /// Alpha carries the exact same contract as visibility, and had the exact
    /// same defect: `update(value)` was handed the last RETURNED alpha, so an
    /// assignment-style script (`thisLayer.alpha = …`, returning undefined) read
    /// the seed forever and `1 - value` settled on one value instead of
    /// alternating.
    @Test("An assignment-style alpha script is fed its own live value, not the seed")
    func assignmentStyleAlphaScriptSeesLiveValue() throws {
        let instance = try WPELayerScriptInstance(
            script: "export function update(value) { thisLayer.alpha = 1 - value; }",
            outputMode: .returnedAlpha(initialValue: 1)
        )
        let first = try #require(instance.tick(runtimeSeconds: 1))
        #expect(abs(first.own.alpha - 0) < 0.0001, "seed 1 inverts to 0: \(first.own.alpha)")
        let second = try #require(instance.tick(runtimeSeconds: 2))
        #expect(abs(second.own.alpha - 1) < 0.0001, "and back to 1: \(second.own.alpha)")
        let third = try #require(instance.tick(runtimeSeconds: 3))
        #expect(abs(third.own.alpha - 0) < 0.0001, "alternating, not stuck: \(third.own.alpha)")
    }

    @Test("A hidden object's effect-constant scripts still register (3151551777 DAY-NIGHT)")
    func hiddenObjectConstantScriptsStillRegister() throws {
        // The scene computes its whole day/night cycle on ONE deliberately
        // invisible layer and has the visible layers read the result out of
        // `shared`. Collecting bindings from the render pipeline alone dropped
        // the producer, so every consumer read an unset key forever.
        let json = """
        {"camera": {"center": "0 0 0", "eye": "0 0 100", "up": "0 1 0"},
         "general": {}, "objects": [
          {"id": 1, "name": "DAY-NIGHT", "image": "materials/a.json",
           "origin": "0 0 0", "angles": "0 0 0", "scale": "1 1 1", "visible": false,
           "effects": [{"id": 9, "name": "Night (Cycle)", "file": "effects/e.json",
             "passes": [{"constantshadervalues": {"multiply1": {"script": "export function update(v){ return 1; }", "value": 0}}}]}]},
          {"id": 2, "name": "VISIBLE", "image": "materials/b.json",
           "origin": "0 0 0", "angles": "0 0 0", "scale": "1 1 1"}
         ]}
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let hidden = try #require(document.imageObjects.first { $0.name == "DAY-NIGHT" })
        #expect(hidden.visible == false, "fixture must model the authored hidden layer")

        // Object 2 drew; object 1 did not — exactly the pipeline the builder produces.
        let bindings = WPEMetalSceneRenderer.offscreenConstantScriptBindings(
            in: document, excludingObjectIDs: ["2"]
        )
        #expect(bindings.count == 1, "hidden object's constant script was dropped")
        #expect(bindings.first?.0.uniform == "multiply1")
        #expect(bindings.first?.0.passID.hasPrefix("offscreen.1.") == true,
                "synthetic pass id must not collide with a real pass: \(String(describing: bindings.first?.0.passID))")

        // Control: once that object DOES draw, the pipeline path owns it and the
        // offscreen sweep must not register it a second time.
        #expect(WPEMetalSceneRenderer.offscreenConstantScriptBindings(
            in: document, excludingObjectIDs: ["1", "2"]
        ).isEmpty)
    }

    @Test("engine.userProperties exposes the scene's resolved project properties")
    func engineUserPropertiesCarriesResolvedSceneValues() throws {
        // 3151551777's day/night driver branches on
        // `engine.userProperties.timeofday`. An empty object sent every frame
        // down `else { value = 0 }` — permanent daytime — without throwing, so
        // nothing upstream ever reported a failure.
        let shared = WPESharedScriptState(userProperties: [
            "timeofday": .string("99"),
            "birds": .bool(true),
            "trainsfxvolume": .number(0.15),
        ])
        let instance = try WPEDynamicTransformScriptInstance(
            script: """
            'use strict';
            export function update(value) {
                if (engine.userProperties.timeofday == 99) { value.x = 1; }
                value.y = engine.userProperties.birds ? 2 : 0;
                value.z = engine.userProperties.trainsfxvolume;
                return value;
            }
            """,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(1920, 1080),
            shared: shared
        )
        let value = try #require(instance.tick(pointerPosition: .zero, runtimeSeconds: 0))
        // `"99" == 99` is true in JS — the string form the manifest carries must
        // survive the bridge as a string, not be coerced or dropped.
        #expect(value.x == 1, "timeofday did not reach the script: \(value)")
        #expect(value.y == 2, "bool property did not reach the script: \(value)")
        #expect(value.z == 0.15, "number property did not reach the script: \(value)")
    }

    /// Verbatim from 3151551777's `Night (Cycle)` effect, pass constant `multiply1`.
    private static let nightCycleProducerScript = """
    'use strict';

    import * as WEMath from 'WEMath';

    const START_HOUR = 20;
    const END_HOUR = 5;
    const BLEND_DURATION = 0.004;

    export function update(value) {
        if (engine.userProperties.timeofday == 2) {
            value = 1;
        } else if (engine.userProperties.timeofday == 99) {
            value = Math.max(
                WEMath.smoothStep((START_HOUR - BLEND_DURATION) / 24, START_HOUR / 24, engine.timeOfDay),
                WEMath.smoothStep(END_HOUR / 24, (END_HOUR - BLEND_DURATION) / 24, engine.timeOfDay));
        }else {
            value = 0;
        }

        shared.night = value;
        shared.shownight = value > 0;

        return value;
    }
    """

    @Test("3151551777's day/night producer reaches its forced-night branch and writes shared")
    func nightCycleProducerWritesSharedState() throws {
        // `timeofday == 2` is the author's "always night" option — the one branch
        // that does not depend on the wall clock, so it isolates the
        // engine.userProperties bridge from engine.timeOfDay.
        let shared = WPESharedScriptState(userProperties: ["timeofday": .string("2")])
        let instance = try WPEDynamicTransformScriptInstance(
            script: Self.nightCycleProducerScript,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(3840, 2160),
            shared: shared
        )
        let value = try #require(
            instance.tick(pointerPosition: .zero, runtimeSeconds: 0),
            "producer returned no value — the script threw or never ran"
        )
        #expect(value.x == 1, "forced-night branch did not produce 1: \(value)")
        // The consumers read these; a producer that runs but writes nothing is
        // exactly the self-lock that kept every Night effect hidden.
        #expect(shared.get("night") as? Double == 1, "shared.night = \(String(describing: shared.get("night")))")
        #expect(shared.get("shownight") as? Bool == true,
                "shared.shownight = \(String(describing: shared.get("shownight")))")
    }

    @Test("The day/night producer's else-branch is what an absent user property yields")
    func nightCycleProducerFallsToDayWithoutUserProperties() throws {
        // Control: this is the pre-fix behaviour — no `timeofday` key, so both
        // comparisons fail and the script writes day forever without throwing.
        let shared = WPESharedScriptState()
        let instance = try WPEDynamicTransformScriptInstance(
            script: Self.nightCycleProducerScript,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(3840, 2160),
            shared: shared
        )
        let value = try #require(instance.tick(pointerPosition: .zero, runtimeSeconds: 0))
        #expect(value.x == 0)
        #expect(shared.get("shownight") as? Bool == false)
    }

    @Test("A scene with no user properties still gets an empty engine.userProperties object")
    func engineUserPropertiesIsAlwaysAnObject() throws {
        // Reading a missing key must yield undefined, not throw out of update().
        let instance = try WPEDynamicTransformScriptInstance(
            script: """
            'use strict';
            export function update(value) {
                value.x = (engine.userProperties.nope === undefined) ? 7 : 0;
                return value;
            }
            """,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(1920, 1080)
        )
        let value = try #require(instance.tick(pointerPosition: .zero, runtimeSeconds: 0))
        #expect(value.x == 7)
    }

    @Test("Effect-visibility gate script: boolean return survives the Vec3 engine as 1/0")
    func effectVisibilityGateScriptCoercesBooleanReturn() throws {
        /// Scene 3151551777's authored form returns `shared.shownight`, a JS
        /// BOOLEAN. Unwrapped, the Vec3 engine sees neither a Number nor an
        /// {x,y,z} and reports "no value", so the gate could never open.
        func gate(returning literal: String) throws -> SIMD3<Double>? {
            let source = """
            'use strict';

            export function update(value) {
            \tvalue = \(literal);
            \treturn value;
            }
            """
            let instance = try WPEDynamicTransformScriptInstance(
                script: source,
                seed: SIMD3<Double>(0, 0, 0),
                valueShape: .boolean,
                canvasSize: SIMD2<Double>(1920, 1080),
                shared: WPESharedScriptState()
            )
            return instance.tick(pointerPosition: .zero, runtimeSeconds: 0)
        }

        let openedValue = try gate(returning: "true")
        let closedValue = try gate(returning: "false")
        // The gate shape must keep feeding the author's `value` parameter a
        // boolean, which is what the seed round-trip encodes.
        let boolArgumentValue = try gate(returning: "typeof value === 'boolean'")
        let opened = try #require(openedValue)
        let closed = try #require(closedValue)
        let boolArgument = try #require(boolArgumentValue)
        #expect(opened.x == 1)
        #expect(closed.x == 0)
        #expect(boolArgument.x == 1)
    }

    @Test("Effect-visibility gate opens from the shared value its own constant script wrote")
    func effectVisibilityGateReadsSharedValueWrittenByConstantScript() throws {
        // Scene 3151551777's self-lock in miniature: the producer is a constant
        // script bound to a pass of the very effect the gate controls, so the gate
        // can only ever open if that pass stayed in the pipeline.
        let shared = WPESharedScriptState()
        let producer = try WPEDynamicTransformScriptInstance(
            script: """
            'use strict';

            export function update(value) {
                shared.night = value.x;
                shared.shownight = value.x > 0;
                return value;
            }
            """,
            seed: SIMD3<Double>(1, 0, 0),
            canvasSize: SIMD2<Double>(1920, 1080),
            shared: shared
        )
        let gate = try WPEDynamicTransformScriptInstance(
            script: """
            'use strict';

            export function update(value) {
            \tvalue = shared.shownight;
            \treturn value;
            }
            """,
            seed: SIMD3<Double>(0, 0, 0),
            valueShape: .boolean,
            canvasSize: SIMD2<Double>(1920, 1080),
            shared: shared
        )

        #expect(producer.tick(pointerPosition: .zero, runtimeSeconds: 0) != nil)
        let value = try #require(gate.tick(pointerPosition: .zero, runtimeSeconds: 0))
        #expect(value.x == 1)
    }

    @Test("Captures embedded text script during parse")
    func captureTextScriptDuringParse() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 1,
                "name": "Clock",
                "type": "text",
                "text": {
                    "script": "export function update(value) { return '12:34'; }",
                    "value": "00:00"
                },
                "origin": "0 0 0"
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let text = try #require(document.textObjects.first)
        #expect(text.text == "00:00")
        #expect(text.textScript?.contains("update(value)") == true)
    }

    @Test("A text script reads the scene's canvas, not the sandbox's 1920x1080")
    func textScriptSeesTheSceneCanvas() throws {
        // Text scripts position and wrap against these two, so a 4K scene laying
        // out at 1080p is off by 2x. The layer and dynamic-transform engines
        // already install the real size; this one only had the sandbox default.
        let script = """
        export function update(value) {
            return engine.screenResolution.x + 'x' + engine.canvasSize.y;
        }
        """
        let instance = try WPESceneScriptInstance(
            script: script,
            initialValue: "",
            canvasSize: SIMD2<Double>(3840, 2160)
        )
        #expect(instance.tickString() == "3840x2160")
    }

    @Test("A text script with no canvas keeps the sandbox default")
    func textScriptWithoutCanvasKeepsSandboxDefault() throws {
        // Control: the parameter is optional, and omitting it must not change
        // what every existing caller sees.
        let script = """
        export function update(value) {
            return engine.screenResolution.x + 'x' + engine.canvasSize.y;
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "")
        #expect(instance.tickString() == "1920x1080")
    }

    @Test("Script runtime evaluates update() and returns new value")
    func scriptUpdateReturnsNewValue() throws {
        let script = """
        export function update(value) {
            return 'live: ' + value;
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "hello")
        let updated = instance.tickString()
        #expect(updated == "live: hello")
        let next = instance.tickString()
        #expect(next == "live: live: hello")
    }

    @Test("A text script's ESM import line does not abort the whole module")
    func textScriptImportLineIsStripped() throws {
        // Scene 3713073223's typewriter scripts open with this exact line. A
        // top-level `import` is a SyntaxError under JSContext's non-module eval,
        // and one SyntaxError kills the entire body — no update(), text frozen at
        // its authored value. The import strip lived at two of the four
        // `preprocess` call sites and this one was not among them.
        let script = """
        import * as WEMath from 'WEMath';
        export function update(value) {
            return 'typed: ' + WEMath.clamp(2, 0, 1) + value;
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "!")
        #expect(instance.tickString() == "typed: 1!")
    }

    @Test("init() runs once at load")
    func initRunsOnceAtLoad() throws {
        let script = """
        var counter = 0;
        export function init() { counter = 100; }
        export function update(value) { counter += 1; return String(counter); }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "0")
        let first = instance.tickString()
        #expect(first == "101")
        let second = instance.tickString()
        #expect(second == "102")
    }

    @Test("Script with no update() falls back to initial value")
    func scriptWithoutUpdateFallsBack() throws {
        let script = "var x = 1;"
        let instance = try WPESceneScriptInstance(script: script, initialValue: "static")
        #expect(instance.tickString() == "static")
        #expect(instance.tickString() == "static")
    }

    @Test("createScriptProperties exposes each property's default value")
    func createScriptPropertiesChain() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCheckbox({name: 'use12hFormat', label: '12h', value: false})
            .addText({name: 'sep', label: 'Sep', value: ':'})
            .finish();
        export function update(value) {
            return scriptProperties.sep + 'OK';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == ":OK")
    }

    @Test("addCombo defaults to its first option's value (date script combos)")
    func comboDefaultsToFirstOption() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCombo({ name: 'monthFormat', label: 'Month Format', options: [
                { label: 'Numeric', value: '1' },
                { label: 'Abbreviated', value: '2' }
            ]})
            .finish();
        export function update(value) {
            var months = ['1','2','3','4','5','6','7','8','9','10','11','12'];
            if (scriptProperties.monthFormat == 1) { return 'JAN=' + months[0]; }
            return 'COMBO_UNDEFINED';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "JAN=1")
    }

    @Test("Clock-style script reads property defaults, not 'undefined'")
    func clockScriptPropertyDefaults() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCheckbox({name: 'use24hFormat', value: true})
            .addText({name: 'delimiter', value: ':'})
            .finish();
        export function update(value) {
            return '03' + scriptProperties.delimiter + '30' + '/' + scriptProperties.use24hFormat;
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "03:30/true")
    }

    @Test("engine.getTimeOfDay returns 0..1")
    func engineGetTimeOfDay() throws {
        let script = """
        export function update(value) {
            var t = engine.getTimeOfDay();
            if (t < 0 || t > 1) return 'OUT_OF_RANGE';
            return 'ok';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "?")
        #expect(instance.tickString() == "ok")
    }

    @Test(
        "engine.registerAudioBuffers sizes every channel to the requested resolution",
        arguments: [16, 32, 64]
    )
    func engineRegisterAudioBuffersHonoursResolution(bands: Int) throws {
        let script = """
        let audioBuffer = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_\(bands));
        export function update(value) {
            return [audioBuffer.average.length, audioBuffer.left.length,
                    audioBuffer.right.length, audioBuffer.average[2]].join(':');
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "")
        #expect(instance.tickString() == "\(bands):\(bands):\(bands):0")
    }

    @Test("engine.registerAudioBuffers falls back to 16 bands for an unsupported resolution")
    func engineRegisterAudioBuffersRejectsUnsupportedResolution() throws {
        // WPE: "It must be 16, 32 or 64." A zero-length array would index to NaN
        // and take the whole scripted value with it.
        let script = """
        let audioBuffer = engine.registerAudioBuffers(4);
        export function update(value) { return String(audioBuffer.average.length); }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "")
        #expect(instance.tickString() == "16")
    }

    @Test("Registered audio buffers read live broker data, downsampled per channel")
    func engineAudioBuffersReadLiveSpectrum() throws {
        // 64 bins, all zero except the top pair, so the 16-band downsample puts a
        // known value in exactly one band and proves it is not the stub's zero.
        var left = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        var right = left
        // Exact binary fractions: Float→Double widening plus two halvings stay
        // bit-exact, so the JS string compare doesn't trip over 0.30000000000004.
        left[60] = 0.5
        left[61] = 0.25
        right[60] = 0.25
        right[61] = 0.25
        SystemAudioCaptureManager.broker.publish(
            AudioSpectrumFrame(left: left, right: right, timestampNanos: 1)
        )
        SystemAudioCaptureManager.setCapturingForTesting(true)
        defer {
            SystemAudioCaptureManager.setCapturingForTesting(false)
            SystemAudioCaptureManager.broker.resetToSilence()
        }
        let script = """
        let audioBuffer = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
        export function update(value) {
            return [audioBuffer.left[15], audioBuffer.right[15],
                    audioBuffer.average[15], audioBuffer.left[0]].join(':');
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "")
        // Max-pool keeps the louder neighbour: 64→32 keeps 0.5 (left) / 0.25
        // (right) from bins 60,61; 32→16 keeps those over the zeroed 62,63
        // pair. Average is (left+right)/2 of the pooled bands.
        #expect(instance.tickString() == "0.5:0.25:0.375:0")
    }

    @Test("Audio buffers fall back to silence while capture is off")
    func engineAudioBuffersSilentWhenCaptureOff() throws {
        var left = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        left[0] = 1
        SystemAudioCaptureManager.broker.publish(
            AudioSpectrumFrame(left: left, right: left, timestampNanos: 1)
        )
        defer { SystemAudioCaptureManager.broker.resetToSilence() }
        let script = """
        let audioBuffer = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
        export function update(value) { return String(audioBuffer.average[0]); }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "")
        #expect(instance.tickString() == "0")
    }

    @Test("Transform scripts see the same live spectrum as text scripts")
    func transformScriptsReadLiveSpectrum() throws {
        var bins = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        for index in bins.indices { bins[index] = 0.5 }
        SystemAudioCaptureManager.broker.publish(
            AudioSpectrumFrame(left: bins, right: bins, timestampNanos: 1)
        )
        SystemAudioCaptureManager.setCapturingForTesting(true)
        defer {
            SystemAudioCaptureManager.setCapturingForTesting(false)
            SystemAudioCaptureManager.broker.resetToSilence()
        }
        let instance = try LiveWallpaper.WPEDynamicTransformScriptInstance(
            script: """
            const audioBuffer = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_32);
            export function update(v) { v.x = audioBuffer.average[0]; return v; }
            """,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(100, 100),
            shared: nil
        )
        let value = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)))
        #expect(value.x == 0.5)
    }

    @Test("engine.openUserShortcut exists and reports that nothing was opened")
    func engineOpenUserShortcutIsInert() throws {
        // The method has to be callable: an undefined call throws out of the
        // cursor handler that invokes it, discarding its other side effects.
        let script = """
        export function update(value) { return String(engine.openUserShortcut('anything')); }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "?")
        #expect(instance.tickString() == "false")
    }


    @Test("Script engines don't leak their JSContext")
    func scriptEnginesReleaseTheirContext() throws {
        // A block installed on a JSContext that also RETAINS that context (directly,
        // or via a captured JSValue — a JSValue owns its context) is a cycle JSC
        // never breaks: measured at ~1.15 MB per instance, held for the process.
        //
        // Every script body below calls `createScriptProperties()` and mints the
        // per-name layer/video/parent/animation handles: those blocks are installed
        // LAZILY, so a trivial script cannot observe their cycles.
        let properties = """
        export var scriptProperties = createScriptProperties()
            .addSlider({ name: 'a', label: 'A', value: 0.5, min: 0, max: 1 })
            .addCheckbox({ name: 'b', label: 'B', value: true })
            .addCombo({ name: 'c', label: 'C', options: [{ value: 1 }, { value: 2 }] })
            .finish();
        """
        // Delta, not absolute: a quarantined engine from an earlier test is
        // deliberately retained for the process and would offset the count.
        // Engines share one JSVirtualMachine per batch worker, so a dropped
        // context's globals become unreachable JS-heap garbage instead of dying
        // with the VM. Collect on both sides of the measurement: what survives a
        // GC is a real ObjC retain cycle, which is what this guard is for.
        func collectLaneGarbage() {
            for _ in 0 ..< (WPESceneScriptContainmentDefaults.batchWorkerWidth * 2) {
                let lane = WPESceneScriptBatchDispatcher.processShared.reserveLane()
                if let probe = JSContext(virtualMachine: lane.virtualMachine) {
                    JSGarbageCollect(probe.jsGlobalContextRef)
                }
            }
        }

        func leakedContexts(_ make: () throws -> Void) rethrows -> Int {
            collectLaneGarbage()
            let before = WPESceneScriptContextBeacon.liveCount
            for _ in 0..<8 { try autoreleasepool { try make() } }
            // An engine drops its JSContext on its own serial queue, so the count
            // settles a beat after the instances go out of scope. A real cycle
            // never settles, so polling costs nothing and removes the raciness of
            // sampling once.
            let deadline = Date().addingTimeInterval(2)
            while WPESceneScriptContextBeacon.liveCount > before, Date() < deadline {
                collectLaneGarbage()
                usleep(20_000)
            }
            return max(WPESceneScriptContextBeacon.liveCount - before, 0)
        }

        let text = try leakedContexts {
            _ = try WPESceneScriptInstance(
                script: properties + """
                export function update(v) { shared.n = (shared.n || 0) + 1; return 'x'; }
                """,
                initialValue: "",
                shared: WPESharedScriptState()
            )
        }
        let layer = try leakedContexts {
            _ = try LiveWallpaper.WPELayerScriptInstance(
                script: properties + """
                const other = thisScene.getLayer('someLayer');
                const made = thisScene.createLayer({ image: 'x.png' });
                export function update(v) {
                    thisLayer.getVideoTexture().play();
                    thisLayer.getParent().getParent();
                    thisLayer.getAnimationLayer('idle').play();
                    other.visible = true;
                    return scriptProperties.a;
                }
                """,
                shared: WPESharedScriptState(),
                outputMode: .returnedAlpha(initialValue: 0)
            )
        }
        let transform = try leakedContexts {
            _ = try LiveWallpaper.WPEDynamicTransformScriptInstance(
                script: properties + """
                export function update(v) { v.x = scriptProperties.a; return v; }
                """,
                seed: SIMD3<Double>(0, 0, 0),
                canvasSize: SIMD2<Double>(100, 100),
                shared: WPESharedScriptState()
            )
        }
        // The parse-time evaluator caches up to 64 contexts of its own and is the
        // only other JSContext owner in the app.
        let evaluator = leakedContexts {
            let evaluator = LiveWallpaper.WPETransformScriptEvaluator(
                canvasWidth: 1000,
                canvasHeight: 1000
            )
            _ = evaluator.resolveVec3(
                script: properties + """
                export function update(v) { v.x = scriptProperties.a; return v; }
                """,
                properties: [:],
                seed: SIMD3<Double>(0, 0, 0)
            )
        }
        #expect(text == 0, "text script leaked \(text) JSContext(s)")
        #expect(layer == 0, "layer script leaked \(layer) JSContext(s)")
        #expect(transform == 0, "transform script leaked \(transform) JSContext(s)")
        #expect(evaluator == 0, "parse-time evaluator leaked \(evaluator) JSContext(s)")
    }

    // MARK: - Real corpus scripts

    /// Wallpaper Engine's own audio-response template, verbatim from workshop
    /// scene 2955378002 (249 of the 259 scale scripts in the local corpus are
    /// this script). It multiplies by an `initialValue` that only `init(value)`
    /// can supply.
    private static let audioScaleTemplate = """
'use strict';

/*
 * Adding new properties to the editor so you can tweak these values in the editor
 */
export var scriptProperties = createScriptProperties()
	.addSlider({
		name: 'frequency',
		label: 'ui_editor_properties_audio_frequency',
		value: 0,
		min: 0,
		max: 15,
		integer: true
	})
	.addSlider({
		name: 'smoothing',
		label: 'ui_editor_properties_audio_response',
		value: 15,
		min: 0,
		max: 25,
		integer: false
	})
	.addSlider({
		name: 'minvalue',
		label: 'ui_editor_properties_min',
		value: 0.8,
		min: 0,
		max: 3,
		integer: false
	})
	.addSlider({
		name: 'maxvalue',
		label: 'ui_editor_properties_max',
		value: 1.2,
		min: 0,
		max: 3,
		integer: false
	})
	.finish();

/**
 * This creates a permanent link to the audio response data.
 */
const audioBuffer = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
let smoothValue = 0;
let initialValue;

/**
 * Calculate new audio-scaled value
 */
export function update() {
	const valueDelta = scriptProperties.maxvalue - scriptProperties.minvalue;
	const audioDelta = audioBuffer.average[scriptProperties.frequency] - smoothValue;
	
	smoothValue += audioDelta * Math.min(1.0, engine.frametime * scriptProperties.smoothing);
	smoothValue = Math.min(1.0, smoothValue);

	return initialValue * (smoothValue * valueDelta + scriptProperties.minvalue);
}

export function init(value) {
	initialValue = (typeof value === 'number') ? value : value.x;
}

"""

    @Test("The corpus audio-scale template scales from its seed, not NaN")
    func corpusAudioScaleTemplateUsesItsSeed() throws {
        var bins = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        for index in bins.indices { bins[index] = 1 }
        SystemAudioCaptureManager.broker.publish(
            AudioSpectrumFrame(left: bins, right: bins, timestampNanos: 1)
        )
        SystemAudioCaptureManager.setCapturingForTesting(true)
        defer {
            SystemAudioCaptureManager.setCapturingForTesting(false)
            SystemAudioCaptureManager.broker.resetToSilence()
        }
        let instance = try LiveWallpaper.WPEDynamicTransformScriptInstance(
            script: Self.audioScaleTemplate,
            scriptProperties: [
                "frequency": .number(0), "smoothing": .number(25),
                "minvalue": .number(1), "maxvalue": .number(1.15)
            ],
            seed: SIMD3<Double>(2, 2, 2),
            canvasSize: SIMD2<Double>(100, 100),
            shared: nil
        )
        // Full-scale audio drives `smoothValue` toward 1, so the result walks from
        // seed*minvalue up to seed*maxvalue. Anything NaN (the `initialValue`
        // undefined case) is rejected by the tick and returns nil.
        var last: SIMD3<Double>?
        for _ in 0..<30 {
            last = instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5), runtimeSeconds: 1)
        }
        let value = try #require(last, "the template returned no usable value")
        #expect(value.x > 2.0, "expected growth above the 2.0 seed, got \(value.x)")
        #expect(value.x <= 2.31, "must stay within seed x maxvalue, got \(value.x)")
    }

    @Test("The corpus audio-scale template pulses through the BATCH path with shared state")
    func corpusAudioScaleTemplateThroughBatchPath() throws {
        // Mirrors the app exactly where the passing sync-path test does not:
        // batch dispatch (what the frame loop uses) and a real shared state.
        var bins = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        for index in bins.indices { bins[index] = 1 }
        SystemAudioCaptureManager.broker.publish(
            AudioSpectrumFrame(left: bins, right: bins, timestampNanos: 1)
        )
        SystemAudioCaptureManager.setCapturingForTesting(true)
        defer {
            SystemAudioCaptureManager.setCapturingForTesting(false)
            SystemAudioCaptureManager.broker.resetToSilence()
        }
        let instance = try LiveWallpaper.WPEDynamicTransformScriptInstance(
            script: Self.audioScaleTemplate,
            scriptProperties: [
                "frequency": .number(0), "smoothing": .number(25),
                "minvalue": .number(0.9), "maxvalue": .number(1.2)
            ],
            seed: SIMD3<Double>(1, 1, 1),
            canvasSize: SIMD2<Double>(100, 100),
            shared: WPESharedScriptState()
        )
        // The batch path publishes asynchronously: without a beat between ticks
        // every call returns "nothing new yet" and the loop proves nothing.
        var last: SIMD3<Double>?
        for frame in 0..<40 {
            if let value = WPEBatchTickDriver.tick(
                instance,
                pointerPosition: SIMD2<Double>(0.5, 0.5),
                runtimeSeconds: Double(frame) / 60
            ) {
                last = value
            }
            usleep(4_000)
        }
        let value = try #require(last)
        // Silence would pin this at seed x minvalue = 0.9 — exactly what the
        // wallpaper shows on device.
        #expect(value.x > 0.9001, "stuck at minvalue: the buffer never saw audio (got \(value.x))")
    }

    @Test("The corpus time-of-day effect script resolves through WEMath.smoothStep")
    func corpusTimeOfDayScriptResolves() throws {
        let script = """
        import * as WEMath from 'WEMath';
        const START_HOUR = 0;
        const END_HOUR = 24;
        const BLEND_DURATION = 0.001;
        export function update(value) {
            return WEMath.smoothStep(
              (START_HOUR - BLEND_DURATION) / 24, START_HOUR / 24, engine.timeOfDay
            ) * WEMath.smoothStep(
              END_HOUR / 24, (END_HOUR - BLEND_DURATION) / 24, engine.timeOfDay
            );
        }
        """
        let instance = try LiveWallpaper.WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(1, 1, 1),
            valueShape: .scalar,
            canvasSize: SIMD2<Double>(100, 100),
            shared: nil
        )
        // The window spans the whole day, so whatever the wall clock reads the
        // product is 1 — the point is that neither `WEMath` nor `engine.timeOfDay`
        // is undefined (either one makes the whole expression NaN).
        let value = try #require(
            instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5), runtimeSeconds: 0),
            "WEMath.smoothStep or engine.timeOfDay is missing"
        )
        #expect(value.x == 1)
    }

    @Test("WEMath.smoothStep matches the documented remap, including a descending pair")
    func weMathSmoothStepSemantics() throws {
        let script = """
        export function update(value) {
            return [WEMath.smoothStep(0, 1, 0.5), WEMath.smoothStep(0, 1, -1),
                    WEMath.smoothStep(0, 1, 2), WEMath.smoothStep(1, 0, 0.5),
                    WEMath.mix(2, 4, 0.25), WEMath.smoothStep(1, 1, 5)].join(',');
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "")
        // Descending (min > max) is how the corpus builds a falling ramp.
        #expect(instance.tickString() == "0.5,0,1,0.5,2.5,1")
    }

    @Test("localstorage.set/get round-trip")
    func localstorageRoundTrip() throws {
        let script = """
        export function init() { localstorage.set('key', 'value-set'); }
        export function update(value) {
            return localstorage.get('key') || 'missing';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "?")
        #expect(instance.tickString() == "value-set")
    }

    // MARK: - WPE 2.8 baseclasses (Vec/Mat math + tolerant globals)

    @Test("Vec3 math from the 2.8 baseclasses computes correctly")
    func vec3MathAvailable() throws {
        let script = """
        export function update(value) { return String(new Vec3(0, 3, 4).length()); }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "5")
    }

    @Test("Mat4.identity().normalMatrix() is the identity 3×3")
    func mat4NormalMatrixIdentity() throws {
        let script = """
        export function update(value) {
            return Mat4.identity().normalMatrix().m.join(',');
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "1,0,0,0,1,0,0,0,1")
    }

    @Test("Mat3.inverse() is the true inverse, not its transpose")
    func mat3InverseIsTrueInverse() throws {
        let script = """
        export function update(value) {
            var m = new Mat3([1, 2, 3, 0, 1, 4, 5, 6, 0]);
            var p = m.multiply(m.inverse()).m;
            var ok = true;
            var id = [1, 0, 0, 0, 1, 0, 0, 0, 1];
            for (var i = 0; i < 9; i += 1) {
                if (Math.abs(p[i] - id[i]) > 1e-9) { ok = false; }
            }
            return ok ? 'identity' : p.join(',');
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "identity")
    }

    @Test("Tolerant globals make scene/thisLayer/timers/model references harmless")
    func tolerantGlobalsNeverThrow() throws {
        let script = """
        export function update(value) {
            setTimeout(function () {}, 16);
            var origin = thisLayer.origin;
            origin.x;
            thisLayer.visible = false;
            scene.customField = 42;
            var model = getModel('character');
            var depth = model.bones.head.position.z;
            return 'tolerant';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "tolerant")
    }

    @Test("SceneScript timeout uses renderer runtime, fires before update, and ignores clock rollback")
    func timeoutUsesMonotonicRendererRuntime() throws {
        let script = """
        var fired = 0;
        var contract = [
            typeof engine.setTimeout,
            typeof engine.setInterval,
            typeof engine.clearTimeout,
            typeof engine.clearInterval,
            typeof setTimeout,
            typeof clearInterval
        ].join('|');
        engine.setTimeout(function () { fired += 1; }, 100);
        export function update(value) { return contract + ':' + engine.runtime + ':' + fired; }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "seed")

        #expect(instance.tickString(runtimeSeconds: 0.099) == "function|function|function|function|function|function:0.099:0")
        #expect(instance.tickString(runtimeSeconds: 0.050) == "function|function|function|function|function|function:0.099:0")
        #expect(instance.tickString(runtimeSeconds: 0.100) == "function|function|function|function|function|function:0.1:1")
    }

    @Test("Timer handles support clear calls and direct self-cancellation")
    func timerCancellationContract() throws {
        let script = """
        var fired = 0;
        var a = setTimeout(function () { fired += 1; }, 10);
        clearTimeout(a);
        var b = engine.setInterval(function () { fired += 10; }, 10);
        b();
        var c = setTimeout(function () { fired += 100; }, 10);
        engine.clearInterval(c);
        export function update(value) { return String(fired); }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "seed")
        #expect(instance.tickString(runtimeSeconds: 1) == "0")
    }

    @Test("Equal-deadline timers are stable and reentrant zero-delay work drains in the same advance")
    func timerReentrancyAndStableOrdering() throws {
        let script = """
        var events = '';
        setTimeout(function () {
            events += 'a';
            setTimeout(function () { events += 'c'; }, 0);
        }, 100);
        setTimeout(function () { events += 'b'; }, 100);
        export function update(value) { return events; }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "seed")
        #expect(instance.tickString(runtimeSeconds: 0.1) == "abc")
    }

    @Test("Intervals catch up from their prior deadline; nonpositive intervals fire only once")
    func intervalCatchUpAndZeroPeriodGuard() throws {
        let script = """
        var regular = 0;
        var zero = 0;
        setInterval(function () { regular += 1; }, 100);
        setInterval(function () { zero += 1; }, 0);
        export function update(value) { return regular + '|' + zero; }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "seed")
        #expect(instance.tickString(runtimeSeconds: 0) == "0|1")
        #expect(instance.tickString(runtimeSeconds: 0.35) == "3|1")
    }

    @Test("A throwing interval is tombstoned instead of retried in the same catch-up sweep")
    func throwingIntervalIsCancelled() throws {
        let script = """
        var attempts = 0;
        setInterval(function () { attempts += 1; throw new Error('timer'); }, 100);
        export function update(value) { return String(attempts); }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "seed")
        #expect(instance.tickString(runtimeSeconds: 0.5) == "1")
        #expect(instance.tickString(runtimeSeconds: 1.0) == "1")
    }

    @Test("Baseclasses do not clobber the existing engine sandbox")
    func baseclassesPreserveExistingSandbox() throws {
        let script = """
        export function update(value) {
            return (typeof engine.getTimeOfDay === 'function') ? 'kept' : 'lost';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "kept")
    }

    @Test("ISoundLayer calls reach the renderer as drained commands, addressed by layer")
    func soundLayerCallsEnqueueCommands() throws {
        // 3151551777's music picker does exactly this: resolve sound layers by
        // name, then stop the ones it isn't switching to.
        let store = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(
            script: """
            export function update() {
                const a = thisScene.getLayer('trackA');
                const b = thisScene.getLayer('trackB');
                a.play();
                b.stop();
                b.volume = 0.25;
                thisLayer.visible = a.isPlaying() && !b.isPlaying();
            }
            """,
            shared: store
        )
        _ = instance.tick(runtimeSeconds: 0)
        let drained = store.drainSoundCommands()
        #expect(drained.count == 3)
        #expect(drained[0].layer == "trackA")
        #expect(drained[0].command == .play)
        #expect(drained[1].layer == "trackB")
        #expect(drained[1].command == .stop)
        #expect(drained[2].command == .setVolume(0.25))
        // Draining is destructive — the renderer applies each command once.
        #expect(store.drainSoundCommands().isEmpty)
    }

    @Test("thisLayer resolves against the scene layer table by its own name, not the empty own-key")
    func thisLayerResolvesItsOwnSceneEntry() throws {
        // `ownKey` is "", so a table lookup keyed on it silently returns nothing:
        // `thisLayer.size` read 0 and `getLayerIndex(thisLayer)` returned -1, which
        // is exactly what the three Simple Visualizer scenes call.
        let store = WPESharedScriptState(layers: [
            WPESceneScriptLayerInfo(
                id: "bar", name: "Bar", size: SIMD2(120, 40), origin: SIMD2(300, 200), index: 0, parentName: nil
            ),
            WPESceneScriptLayerInfo(
                id: "dock", name: "Dock", size: SIMD2(800, 90), origin: SIMD2(960, 60), index: 1, parentName: "Bar"
            )
        ])
        let instance = try WPELayerScriptInstance(
            script: """
            export function update() {
                shared.probe = [
                    thisLayer.name,
                    thisLayer.size.x,
                    thisLayer.origin.y,
                    thisScene.getLayerIndex(thisLayer),
                    thisLayer.getParent().name
                ].join('|');
            }
            """,
            shared: store,
            ownLayerName: "Dock"
        )
        _ = instance.tick(runtimeSeconds: 0)
        #expect(store.get("probe") as? String == "Dock|800|60|1|Bar")
    }

    @Test("thisLayer transform setters publish only explicit origin, scale, and degree-angle assignments")
    func thisLayerTransformMutationContract() throws {
        let store = WPESharedScriptState(layers: [
            WPESceneScriptLayerInfo(
                id: "mover",
                name: "Mover",
                size: SIMD2(100, 50),
                origin: SIMD2(30, 40),
                originZ: 5,
                scale: SIMD3(0.5, 0.75, 1),
                angles: SIMD3(0, 0, .pi / 2),
                index: 0,
                parentName: nil
            )
        ])
        let instance = try WPELayerScriptInstance(
            script: """
            export function update() {
                shared.seed = [thisLayer.origin.z, thisLayer.scale.y, thisLayer.angles.z].join('|');
                const moved = thisLayer.origin;
                moved.x += 12;
                thisLayer.origin = moved;
                thisLayer.scale = new Vec3(2, 3, 4);
                thisLayer.angles = new Vec3(10, 20, 90);
            }
            """,
            shared: store,
            ownLayerName: "Mover"
        )

        #expect(instance.initialOutput.ownTransform.isEmpty)
        let output = try #require(instance.tick(runtimeSeconds: 0))
        #expect(store.get("seed") as? String == "5|0.75|90")
        #expect(output.ownTransform.origin == SIMD3<Double>(42, 40, 5))
        #expect(output.ownTransform.scale == SIMD3<Double>(2, 3, 4))
        #expect(output.ownTransform.angles == SIMD3<Double>(10, 20, 90))

        let readOnly = try WPELayerScriptInstance(
            script: """
            export function update() {
                const local = thisLayer.origin;
                local.x = 999;
            }
            """,
            shared: store,
            ownLayerName: "Mover"
        )
        #expect(try #require(readOnly.tick(runtimeSeconds: 0)).ownTransform.isEmpty)
    }

    @Test("A scene override is re-typed to what the script declared (addText stays a String)")
    func scriptPropertyOverrideKeepsDeclaredType() throws {
        // 3460973721 declares `.addText({name:'delayTime', value:'1'})` and the
        // scene overrides it with the JSON string "0.2". scene.json has no types,
        // so the parser reads that as a number and `.trim()` used to throw.
        let instance = try WPESceneScriptInstance(
            script: """
            export var scriptProperties = createScriptProperties()
                .addText({ name: 'delayTime', label: 'Delay', value: '1' })
                .addSlider({ name: 'speed', label: 'Speed', value: 1 })
                .addCheckbox({ name: 'enabled', label: 'On', value: false })
                .finish();
            export function update(value) {
                return typeof scriptProperties.delayTime
                    + '/' + scriptProperties.delayTime.trim()
                    + '/' + typeof scriptProperties.speed
                    + '/' + typeof scriptProperties.enabled;
            }
            """,
            initialValue: "",
            scriptProperties: [
                "delayTime": .number(0.2),   // what the parser produces for "0.2"
                "speed": .string("2.5"),     // and the reverse direction
                "enabled": .number(1)
            ]
        )
        #expect(instance.tickString() == "string/0.2/number/boolean")
    }

    @Test("Text SceneScript reads the scene shared state")
    func textSceneScriptReadsSharedState() throws {
        let store = WPESharedScriptState()
        store.set("ip1", "Local/1st Arm/")
        store.set("num", 42.0)
        let instance = try WPESceneScriptInstance(
            script: """
            export function update(value) {
                return shared.ip1 + shared.num;
            }
            """,
            initialValue: "",
            shared: store
        )

        #expect(instance.tickString() == "Local/1st Arm/42")
    }

    @Test("Current synchronous containment is deadline plus poison, not termination")
    func synchronousTimeoutSourceContract() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("done.wait(timeout: deadline)"))
        #expect(source.contains("safety.quarantine(self, operation: operation)"))
        #expect(!source.contains("static var quarantine"))
        #expect(!source.contains("quarantine.append"))
        #expect(source.contains("throw WPESceneScriptError.executionTimedOut"))
        #expect(source.contains("return lastValue"))
        for absentTerminationSeam in [
            "terminateExecution",
            "TerminateExecution",
            "executionTimeLimit",
            "JSContextGroupSetExecutionTimeLimit",
        ] {
            #expect(!source.contains(absentTerminationSeam))
        }
    }

    @Test("Setup capacity rejection is structured and dispatches no evaluator")
    func setupCapacityRejectionIsStructured() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let blocker = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: blocker))
        defer { heldPermit.release() }
        let expected = WPESceneScriptError.capacityUnavailable(operation: .setup)

        #expect(throws: expected) {
            _ = try WPESceneScriptInstance(
                script: "export function update(value) { return value; }",
                initialValue: "seed",
                setupBudget: 0.001,
                governor: governor
            )
        }
        #expect(throws: expected) {
            _ = try WPELayerScriptInstance(
                script: "export function update() { thisLayer.visible = false; }",
                setupBudget: 0.001,
                governor: governor
            )
        }
        #expect(throws: expected) {
            _ = try WPEDynamicTransformScriptInstance(
                script: "export function update(value) { return value; }",
                seed: .zero,
                canvasSize: SIMD2<Double>(100, 100),
                setupBudget: 0.001,
                governor: governor
            )
        }
        let staticEvaluator = WPETransformScriptEvaluator(
            canvasWidth: 100,
            canvasHeight: 100,
            evaluationBudget: 0.001,
            governor: governor
        )
        #expect(staticEvaluator.resolveVec3(
            script: "export function update(value) { value.x = 7; value.y = 8; return value; }",
            properties: [:],
            seed: .zero
        ) == nil)
    }

    @Test("Setup waits fairly through temporary saturation within its deadline")
    func setupWaitsThroughTemporarySaturation() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let blocker = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: blocker))
        let releaser = DispatchQueue(label: "com.livewallpaper.tests.scenescript-setup-release")
        releaser.asyncAfter(deadline: .now() + 0.01) {
            heldPermit.release()
        }

        let instance = try WPESceneScriptInstance(
            script: "export function update(value) { return value + '-ready'; }",
            initialValue: "seed",
            setupBudget: 1,
            governor: governor
        )
        #expect(instance.tickString() == "seed-ready")
    }

    @Test("Dynamic sync capacity saturation keeps the last stable transform")
    func dynamicSyncCapacityKeepsLastValue() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let instance = try WPEDynamicTransformScriptInstance(
            script: "export function update(value) { value.x += 1; return value; }",
            seed: SIMD3<Double>(3, 4, 5),
            canvasSize: SIMD2<Double>(100, 100),
            governor: governor
        )
        let blocker = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: blocker))
        defer { heldPermit.release() }

        #expect(instance.tick(pointerPosition: .zero) == SIMD3<Double>(3, 4, 5))
    }

    // MARK: - WPETransformScriptEvaluator (static origin scripts)

    private static let originScript = """
    'use strict';
    export var scriptProperties = createScriptProperties()
        .addSlider({name: 'x', value: 0.5, min: 0, max: 1})
        .addSlider({name: 'y', value: 0.5, min: 0, max: 1})
        .finish();
    export function update(value) {
        value.x = scriptProperties.x * engine.canvasSize.x;
        value.y = scriptProperties.y * engine.canvasSize.y;
        return value;
    }
    """

    @Test("Origin script resolves bound scriptProperties × canvasSize")
    func originScriptResolvesToFractionTimesCanvas() throws {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 3840, canvasHeight: 2160)
        let origin = try #require(evaluator.resolveVec3(
            script: Self.originScript,
            properties: ["x": .number(0.112), "y": .number(0.434)],
            seed: SIMD3<Double>(99, 99, 7)
        ))
        #expect(abs(origin.x - 0.112 * 3840) < 0.001)
        #expect(abs(origin.y - 0.434 * 2160) < 0.001)
        #expect(origin.z == 7)
    }

    @Test("Bound scriptProperties override the script's declared defaults")
    func boundPropertiesOverrideDeclaredDefaults() throws {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 1000, canvasHeight: 1000)
        let origin = try #require(evaluator.resolveVec3(
            script: Self.originScript,
            properties: ["x": .number(-0.29), "y": .number(0.0)],
            seed: SIMD3<Double>(0, 0, 0)
        ))
        #expect(abs(origin.x - (-290)) < 0.001)
        #expect(origin.y == 0)
    }

    @Test("One evaluator reuses a context per source across many objects")
    func evaluatorReusesContextPerSource() throws {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 800, canvasHeight: 600)
        let a = try #require(evaluator.resolveVec3(
            script: Self.originScript, properties: ["x": .number(0.25), "y": .number(0.5)], seed: .init(0, 0, 0)))
        let b = try #require(evaluator.resolveVec3(
            script: Self.originScript, properties: ["x": .number(0.75), "y": .number(0.25)], seed: .init(0, 0, 0)))
        #expect(abs(a.x - 200) < 0.001 && abs(a.y - 300) < 0.001)
        #expect(abs(b.x - 600) < 0.001 && abs(b.y - 150) < 0.001)
    }

    @Test("Shared context does not leak one object's bindings into the next")
    func sharedContextDoesNotLeakBindings() throws {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 1000, canvasHeight: 1000)
        let first = try #require(evaluator.resolveVec3(
            script: Self.originScript,
            properties: ["x": .number(0.25), "y": .number(0.25)],
            seed: .init(0, 0, 0)))
        let second = try #require(evaluator.resolveVec3(
            script: Self.originScript,
            properties: [:],
            seed: .init(0, 0, 0)))
        #expect(abs(first.x - 250) < 0.001)
        #expect(abs(second.x - 500) < 0.001)
        #expect(abs(second.y - 500) < 0.001)
    }

    @Test("Overrides apply even when scriptProperties is declared const/let")
    func overridesApplyToConstScriptProperties() throws {
        let constScript = """
        'use strict';
        export const scriptProperties = createScriptProperties()
            .addSlider({name: 'x', value: 0.5})
            .addSlider({name: 'y', value: 0.5})
            .finish();
        export function update(value) {
            value.x = scriptProperties.x * engine.canvasSize.x;
            value.y = scriptProperties.y * engine.canvasSize.y;
            return value;
        }
        """
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 1000, canvasHeight: 1000)
        let origin = try #require(evaluator.resolveVec3(
            script: constScript,
            properties: ["x": .number(0.3), "y": .number(0.7)],
            seed: .init(0, 0, 0)
        ))
        #expect(abs(origin.x - 300) < 0.001)
        #expect(abs(origin.y - 700) < 0.001)
    }

    @Test("Dynamic (audio/time/random) scripts are not statically resolved")
    func dynamicScriptsAreSkipped() {
        #expect(LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(Self.originScript))
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = engine.getFrequency(0); return v; }"
        ))
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = engine.runtime; return v; }"
        ))
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = Math.random(); return v; }"
        ))
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = input.cursorWorldPosition.x; return v; }"
        ))
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = shared.xx1; return v; }"
        ))
        // The property form of the day fraction; the `getTimeOfDay` token above
        // is a case-sensitive substring and does not cover it.
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.y = engine.timeOfDay * 100; return v; }"
        ))
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 100, canvasHeight: 100)
        #expect(evaluator.resolveVec3(
            script: "export function update(v){ v.x = engine.getTimeOfDay(); return v; }",
            properties: [:], seed: .init(1, 2, 3)
        ) == nil)
    }

    @Test("Dynamic origin script follows cursorWorldPosition in WPE y-up canvas pixels")
    func dynamicOriginScriptFollowsCursorWorldPosition() throws {
        let script = """
        'use strict';
        export function update(value) {
            value.x = input.cursorWorldPosition.x;
            value.y = input.cursorWorldPosition.y;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(860.29364, 133.27734, 9),
            canvasSize: SIMD2<Double>(3840, 2160)
        )

        let origin = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.25, 0.75)))

        #expect(origin == SIMD3<Double>(960, 540, 9))
    }

    @Test("Dynamic origin script reads the scene shared state")
    func dynamicOriginScriptReadsSceneSharedState() throws {
        let store = WPESharedScriptState()
        store.set("xx1", 12.5)
        store.set("yy1", -3.25)
        store.set("zz1", 4.75)
        let script = """
        'use strict';
        export function update(value) {
            value.x = shared.xx1;
            value.y = shared.yy1;
            value.z = shared.zz1;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(0, 1, 0),
            canvasSize: SIMD2<Double>(3840, 2160),
            shared: store
        )

        let origin = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)))

        #expect(origin == SIMD3<Double>(12.5, -3.25, 4.75))
    }

    @Test("Dynamic origin script accepts WPE non-breaking keyword spaces")
    func dynamicOriginScriptAcceptsWPENonBreakingKeywordSpaces() throws {
        let nbsp = "\u{00A0}"
        let script = """
        'use\(nbsp)strict';
        export\(nbsp)function\(nbsp)update(value) {
            value.x = input.cursorWorldPosition.x;
            value.y = input.cursorWorldPosition.y;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(860.29364, 133.27734, 9),
            canvasSize: SIMD2<Double>(3840, 2160)
        )

        let origin = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.25, 0.75)))

        #expect(origin == SIMD3<Double>(960, 540, 9))
    }

    @Test("Static origin evaluator rejects loop constructs before JS evaluation")
    func staticOriginScriptsRejectLoopConstructs() throws {
        let loopScripts = [
            "export function update(v){ while (true) {} return v; }",
            "export function update(v){ for (;;) {} return v; }",
            "export function update(v){ do {} while (true); return v; }",
        ]

        for script in loopScripts {
            #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(script))
        }

        let evaluator = WPETransformScriptEvaluator(
            canvasWidth: 100,
            canvasHeight: 100,
            evaluationBudget: 0.1
        )
        #expect(evaluator.resolveVec3(script: loopScripts[0], properties: [:], seed: .init(5, 6, 7)) == nil)

        let origin = try #require(evaluator.resolveVec3(
            script: Self.originScript,
            properties: ["x": .number(0.5), "y": .number(0.5)],
            seed: .init(1, 2, 3)
        ))
        #expect(origin == SIMD3<Double>(50, 50, 3))
    }

    @Test("Origin script can branch on a bool scriptProperty")
    func originScriptBranchesOnBoolProperty() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCheckbox({name: 'flip', value: false})
            .finish();
        export function update(value) {
            value.x = scriptProperties.flip ? 10 : 20;
            return value;
        }
        """
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 1, canvasHeight: 1)
        let flipped = try #require(evaluator.resolveVec3(
            script: script, properties: ["flip": .bool(true)], seed: .init(0, 0, 0)))
        #expect(flipped.x == 10)
        let plain = try #require(evaluator.resolveVec3(
            script: script, properties: ["flip": .bool(false)], seed: .init(0, 0, 0)))
        #expect(plain.x == 20)
    }

    @Test("Parser applies script origin under a parent's transform")
    func parserAppliesScriptOriginBeneathParent() throws {
        let escaped = Self.originScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = """
        {
            "camera": {"center": "0 0 0"},
            "general": {"orthogonalprojection": {"width": 1000, "height": 1000, "auto": true}},
            "objects": [
                {"id": 10, "name": "group", "scale": "-1 1 1", "origin": "2408 971 0"},
                {"id": 11, "name": "Clock", "type": "text", "parent": 10,
                 "text": "12:34",
                 "origin": {"script": "\(escaped)",
                            "scriptproperties": {"x": 0.25, "y": 0.10},
                            "value": "999 999 0"}}
            ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let clock = try #require(document.textObjects.first { $0.id == "11" })
        #expect(abs(clock.origin.x - (2408 - 250)) < 0.01)
        #expect(abs(clock.origin.y - (971 + 100)) < 0.01)
    }

    @Test("Stale baked origin is replaced, not used, when a script is present")
    func staleBakedOriginIsReplaced() throws {
        let escaped = Self.originScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = """
        {
            "camera": {"center": "0 0 0"},
            "general": {"orthogonalprojection": {"width": 2000, "height": 2000, "auto": true}},
            "objects": [
                {"id": 12, "name": "T", "type": "text", "text": "x",
                 "origin": {"script": "\(escaped)",
                            "scriptproperties": {"x": 0.5, "y": 0.5},
                            "value": "12345 67890 0"}}
            ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let text = try #require(document.textObjects.first)
        #expect(abs(text.origin.x - 1000) < 0.01)
        #expect(abs(text.origin.y - 1000) < 0.01)
    }

    @Test("Image localOrigin uses the script-resolved local origin, not stale baked")
    func imageLocalOriginUsesScriptOrigin() throws {
        let escaped = Self.originScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = """
        {
            "camera": {"center": "0 0 0"},
            "general": {"orthogonalprojection": {"width": 1000, "height": 1000, "auto": true}},
            "objects": [
                {"id": 50, "name": "group", "origin": "100 200 0"},
                {"id": 51, "name": "img", "image": "materials/x.png", "parent": 50,
                 "origin": {"script": "\(escaped)",
                            "scriptproperties": {"x": 0.25, "y": 0.40},
                            "value": "999 999 7"}}
            ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let image = try #require(document.imageObjects.first { $0.id == "51" })
        #expect(abs(image.localOrigin.x - 250) < 0.01)
        #expect(abs(image.localOrigin.y - 400) < 0.01)
        #expect(abs(image.origin.x - 350) < 0.01)
        #expect(abs(image.origin.y - 600) < 0.01)
    }

    // MARK: - Text-content script scriptProperties injection (Mon vs Monday)

    @Test("Text script renders with the scene's scriptProperties, not just defaults")
    func textScriptUsesSceneScriptProperties() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCombo({name: 'dayFormat', options: [
                {label: 'Abbreviated', value: '1'},
                {label: 'Full', value: '2'}
            ]})
            .finish();
        export function update(value) {
            return scriptProperties.dayFormat == '2' ? 'Monday' : 'Mon';
        }
        """
        let bare = try WPESceneScriptInstance(script: script, initialValue: "?")
        #expect(bare.tickString() == "Mon")
        let configured = try WPESceneScriptInstance(
            script: script,
            initialValue: "?",
            scriptProperties: ["dayFormat": .string("2")])
        #expect(configured.tickString() == "Monday")
    }

    @Test("Injected scriptProperties survive a const declaration in a text script")
    func textScriptConstScriptPropertiesInjected() throws {
        let script = """
        export const scriptProperties = createScriptProperties()
            .addCheckbox({name: 'showDay', value: true})
            .finish();
        export function update(value) {
            return scriptProperties.showDay ? 'SHOW' : 'HIDE';
        }
        """
        let configured = try WPESceneScriptInstance(
            script: script,
            initialValue: "?",
            scriptProperties: ["showDay": .bool(false)])
        #expect(configured.tickString() == "HIDE")
    }

    // MARK: - Ancestor-aware visibility

    @Test("A text child of a condition-hidden parent group is hidden")
    func textChildOfHiddenGroupIsHidden() throws {
        let json = """
        {
            "camera": {"center": "0 0 0"},
            "general": {"orthogonalprojection": {"width": 100, "height": 100, "auto": true}},
            "objects": [
                {"id": 1, "name": "横Day", "visible": false},
                {"id": 2, "name": "竖Day", "visible": true},
                {"id": 3, "name": "DAY", "type": "text", "text": "DAY", "parent": 1, "visible": true},
                {"id": 4, "name": "SUN", "type": "text", "text": "SUN", "parent": 2, "visible": true}
            ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let horizontal = try #require(document.textObjects.first { $0.id == "3" })
        let vertical = try #require(document.textObjects.first { $0.id == "4" })
        #expect(horizontal.visible == false)
        #expect(vertical.visible == true)
    }

    @Test("Ancestor visibility folds through a multi-level group chain")
    func ancestorVisibilityFoldsThroughChain() throws {
        let json = """
        {
            "camera": {"center": "0 0 0"},
            "general": {"orthogonalprojection": {"width": 100, "height": 100, "auto": true}},
            "objects": [
                {"id": 1, "name": "root", "visible": false},
                {"id": 2, "name": "mid", "parent": 1, "visible": true},
                {"id": 3, "name": "leaf", "type": "text", "text": "x", "parent": 2, "visible": true}
            ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let leaf = try #require(document.textObjects.first { $0.id == "3" })
        #expect(leaf.visible == false)
    }

    // MARK: - Layer visible-script (video intro)

    @Test("Visible-script on an image object is captured during parse")
    func captureVisibleScriptDuringParse() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 7, "name": "Intro", "image": "models/intro.json",
                "visible": { "script": "export function update(){}", "value": true }
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let image = try #require(document.imageObjects.first)
        #expect(image.visibleScript?.contains("update") == true)
    }

    @Test("Visible-script with a user binding is still captured (not collapsed to a bool)")
    func captureVisibleScriptWithUserBinding() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 7, "name": "Intro", "image": "models/intro.json",
                "visible": { "script": "export function update(){}", "user": "ruchang", "value": true }
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: ["ruchang": .bool(true)])
        let image = try #require(document.imageObjects.first)
        #expect(image.visibleScript?.contains("update") == true)
    }

    @Test("Alpha-script on an image object is captured during parse")
    func captureAlphaScriptDuringParse() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 449,
                "name": "RST界面背景备用",
                "image": "models/black.json",
                "alpha": {
                    "script": "export function update(value){ return engine.runtime > 2 ? 0 : value; }",
                    "scriptproperties": { "peakvalue": { "user": "newproperty15", "value": 0.25 } },
                    "value": 1
                }
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let image = try #require(document.imageObjects.first)
        #expect(image.alpha == 1)
        #expect(image.alphaScript?.contains("engine.runtime") == true)
        #expect(image.alphaScriptProperties["peakvalue"] == .number(0.25))
    }

    @Test("Non-rendered solid visible-script is captured as a script host")
    func captureSolidVisibleScriptHostDuringParse() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 1326,
                "name": "MAIN",
                "solid": true,
                "visible": {
                    "script": "export function update(value){ shared.dd = 1; return value; }",
                    "value": true
                }
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let host = try #require(document.scriptHostObjects.first)
        #expect(host.id == "1326")
        #expect(host.visibleScript.contains("shared.dd"))
        #expect(document.imageObjects.isEmpty)
    }

    @Test("Layer alpha-script returns live alpha from update(value)")
    func layerAlphaScriptUsesRuntimeReturnValue() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addSlider({ name: 'peakvalue', value: 1 })
            .finish();
        export function update(value) {
            if (engine.runtime <= 2) { return value; }
            return 1 - Math.min((engine.runtime - 2) / 3, 1) * scriptProperties.peakvalue;
        }
        """
        let instance = try WPELayerScriptInstance(
            script: script,
            scriptProperties: ["peakvalue": .number(1)],
            outputMode: .returnedAlpha(initialValue: 1)
        )

        #expect(instance.initialOutput.own.alpha == 1)
        let early = try #require(instance.tick(runtimeSeconds: 1)?.own)
        #expect(early.alpha == 1)
        let faded = try #require(instance.tick(runtimeSeconds: 5)?.own)
        #expect(faded.visible == true)
        #expect(faded.alpha == 0)
    }

    @Test("Layer alpha-script can read engine.frametime")
    func layerAlphaScriptReadsFrameTime() throws {
        let script = """
        export function update(value) {
            return value + engine.frametime;
        }
        """
        let instance = try WPELayerScriptInstance(
            script: script,
            outputMode: .returnedAlpha(initialValue: 0)
        )

        let first = try #require(instance.tick(runtimeSeconds: 1)?.own)
        #expect(first.alpha == 1)
        let second = try #require(instance.tick(runtimeSeconds: 1.25)?.own)
        #expect(abs(second.alpha - 1.25) < 0.0001)
    }

    @Test("Dynamic transform script receives previous returned value")
    func dynamicTransformScriptReceivesPreviousReturnedValue() throws {
        let script = """
        export function update(value) {
            value.x = value.x + 1;
            value.y = value.y + 2;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(10, 20, 30),
            canvasSize: SIMD2<Double>(100, 100)
        )

        let first = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)))
        let second = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)))

        #expect(first == SIMD3<Double>(11, 22, 30))
        #expect(second == SIMD3<Double>(12, 24, 30))
    }

    @Test("Dynamic transform script reads runtime, frametime, and screen resolution")
    func dynamicTransformScriptReadsEngineTimeAndScreenResolution() throws {
        let script = """
        export function update(value) {
            value.x = engine.runtime;
            value.y = value.y + engine.frametime;
            value.z = engine.screenResolution.x;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(100, 50)
        )

        let first = try #require(instance.tick(
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            runtimeSeconds: 1
        ))
        let second = try #require(instance.tick(
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            runtimeSeconds: 1.25
        ))

        #expect(first == SIMD3<Double>(1, 1, 100))
        #expect(second == SIMD3<Double>(1.25, 1.25, 100))
    }

    /// `installSandbox` seeds `engine.screenResolution` with a hardcoded 1920x1080, and each
    /// engine's `installCanvasSize` is what overwrites it with the real canvas. The parse-time
    /// evaluator overwrote only `canvasSize`, so a statically-baked origin script reading
    /// `screenResolution` silently got 1920 on every non-1080p scene.
    @Test("Parse-time transform evaluator reports the real canvas as screenResolution")
    func transformEvaluatorScreenResolutionMatchesCanvas() throws {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 3840, canvasHeight: 2160)
        let resolved = try #require(evaluator.resolveVec3(
            script: """
            export function update(v) {
                v.x = engine.screenResolution.x;
                v.y = engine.canvasSize.x;
                return v;
            }
            """,
            properties: [:],
            seed: SIMD3<Double>(0, 0, 0)
        ))
        #expect(resolved.y == 3840)
        #expect(resolved.x == 3840)
    }

    @Test("Dynamic transform script expands a scalar return to a uniform vector")
    func dynamicTransformScriptExpandsScalarReturn() throws {
        let script = """
        export function update(value) {
            return engine.runtime > 1 ? 2 : 3;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(1, 1, 1),
            canvasSize: SIMD2<Double>(100, 50)
        )

        let first = try #require(instance.tick(
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            runtimeSeconds: 0.5
        ))
        let second = try #require(instance.tick(
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            runtimeSeconds: 2
        ))

        #expect(first == SIMD3<Double>(3, 3, 3))
        #expect(second == SIMD3<Double>(2, 2, 2))
    }

    @Test("Layer video-intro script: init hides+stops, plays once, hides after timeout")
    func layerVideoIntroPlaysOnce() throws {
        let script = """
        'use strict';
        import * as WEMath from 'WEMath';
        export var scriptProperties = createScriptProperties()
            .addCheckbox({ name: 'play', value: true })
            .addCheckbox({ name: 'hideStopped', value: true })
            .finish();
        let video, stopped = false, startTime = 0, fadeStartTime = 0, fadingOut = false;
        export function init() {
            thisLayer.visible = false;
            video = thisLayer.getVideoTexture();
            video.stop();
            video.setCurrentTime(0);
            thisLayer.alpha = 1;
        }
        export function update() {
            const currentTime = Date.now();
            if (!stopped && scriptProperties.play) {
                if (startTime === 0) { startTime = currentTime; video.play(); }
                else if (currentTime - startTime >= 15000) {
                    if (!fadingOut) { fadingOut = true; fadeStartTime = currentTime; }
                    const fadeProgress = (currentTime - fadeStartTime) / 1000;
                    if (fadeProgress < 1) { thisLayer.alpha = 1 - fadeProgress; }
                    else { thisLayer.alpha = 0; video.stop(); stopped = true; if (scriptProperties.hideStopped) thisLayer.visible = false; }
                } else { thisLayer.alpha = 1; }
            }
            thisLayer.visible = thisLayer.alpha > 0.001;
        }
        """

        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var ms: Double = 0
            func now() -> Double { lock.lock(); defer { lock.unlock() }; return ms }
            func set(_ value: Double) { lock.lock(); ms = value; lock.unlock() }
        }
        let clock = Clock()
        let instance = try WPELayerScriptInstance(script: script, nowProviderMillis: { clock.now() })

        #expect(instance.initialOutput.own.visible == false)
        #expect(instance.initialOutput.own.alpha == 1)
        #expect(instance.initialOutput.own.videoCommands.contains(.stop))
        #expect(instance.initialOutput.own.videoCommands.contains(.seek(0)))

        let base: Double = 1_000_000
        clock.set(base)
        let first = try #require(instance.tick()).own
        #expect(first.videoCommands.contains(.play))
        #expect(first.alpha == 1)
        #expect(first.visible == true)

        clock.set(base + 5000)
        let mid = try #require(instance.tick()).own
        #expect(mid.visible == true)
        #expect(mid.videoCommands.isEmpty)

        clock.set(base + 16100)
        _ = instance.tick()
        clock.set(base + 17300)
        let end = try #require(instance.tick()).own
        #expect(end.videoCommands.contains(.stop))
        #expect(end.visible == false)
        #expect(end.alpha == 0)
    }

    @Test("getLayer drives another layer: button init stops + hides the target video")
    func getLayerControlsAnotherLayer() throws {
        let script = """
        'use strict';
        export var scriptProperties = createScriptProperties()
            .addCheckbox({ name: 'enableScript', value: true })
            .finish();
        let target, video;
        export function init() {
            thisLayer.visible = true;
            target = thisScene.getLayer('千咲入场动画');
            video = target.getVideoTexture();
            video.stop();
            video.setCurrentTime(0);
            target.alpha = 0;
            target.visible = false;
        }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script)
        let other = try #require(instance.initialOutput.others["千咲入场动画"])
        #expect(other.visible == false)
        #expect(other.alpha == 0)
        #expect(other.videoCommands.contains(.stop))
        #expect(other.videoCommands.contains(.seek(0)))
        #expect(instance.initialOutput.own.visible == true)
    }

    /// 2955378002 does exactly this in `init`, and it was a silent no-op while
    /// `getLayer` handles carried plain data properties for origin/scale/angles:
    /// the assignment landed on a throwaway JS object nobody read back.
    @Test("getLayer transform assignment reaches the caller as a cross-layer mutation")
    func getLayerTransformAssignmentIsRecorded() throws {
        let script = """
        'use strict';
        export function init() {
            thisScene.getLayer('playerprogexception').origin = thisLayer.origin;
            thisScene.getLayer('dial').angles = { x: 0, y: 0, z: 90 };
            thisScene.getLayer('dial').scale = { x: 2, y: 2, z: 1 };
        }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script)
        let transforms = instance.initialOutput.otherTransforms

        #expect(transforms["playerprogexception"]?.origin != nil)
        #expect(transforms["dial"]?.angles == SIMD3<Double>(0, 0, 90))
        #expect(transforms["dial"]?.scale == SIMD3<Double>(2, 2, 1))
        #expect(transforms["dial"]?.origin == nil, "an untouched field must stay unassigned")
    }

    /// `createLayer` handles share the `getLayer` shape, so the cross-layer
    /// journal must not swallow them — they report through `created`.
    @Test("A created layer's transform stays out of the cross-layer journal")
    func createdLayerTransformIsNotACrossLayerMutation() throws {
        let script = """
        'use strict';
        export function init() {
            var made = thisScene.createLayer('materials/x.tex');
            made.origin = { x: 4, y: 5, z: 6 };
        }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script)
        #expect(instance.initialOutput.otherTransforms.isEmpty)
        #expect(instance.initialOutput.created.first?.origin == SIMD3<Double>(4, 5, 6))
    }

    /// Control: reading a transform must not look like writing one, or every
    /// script that merely inspects a sibling layer would pin it in place.
    @Test("getLayer transform read does not record a mutation")
    func getLayerTransformReadIsNotAMutation() throws {
        let script = """
        'use strict';
        export var seen = 0;
        export function init() {
            seen = thisScene.getLayer('probe').origin.x + thisScene.getLayer('probe').scale.y;
        }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script)
        #expect(instance.initialOutput.otherTransforms["probe"] == nil)
    }

    @Test("getLayer READ-only reference does not drive the layer (3226487183 variant overlap)")
    func getLayerReadOnlyReferenceDoesNotDrive() throws {
        let script = """
        'use strict';
        var probedVisible = true;
        export function update() {
            // read-only: reference the layer + read its visibility, never assign
            var probed = thisScene.getLayer('中面具身体背景');
            probedVisible = probed.visible;
            // a SEPARATE layer IS explicitly driven — that one must still appear
            thisScene.getLayer('面具花').visible = true;
        }
        """
        let instance = try WPELayerScriptInstance(script: script)
        let output = try #require(instance.tick())
        #expect(output.others["中面具身体背景"] == nil)
        #expect(output.others["面具花"]?.visible == true)
        #expect(output.others["面具花"]?.visibleAssigned == true)
    }

    @Test("getLayer alpha-only assignment does not force visible")
    func getLayerAlphaOnlyDoesNotForceVisible() throws {
        let script = """
        'use strict';
        export function update() { thisScene.getLayer('fade').alpha = 0.25; }
        """
        let instance = try WPELayerScriptInstance(script: script)
        let output = try #require(instance.tick())
        let fade = try #require(output.others["fade"])
        #expect(fade.alpha == 0.25)
        #expect(fade.alphaAssigned == true)
        #expect(fade.visibleAssigned == false)
    }

    @Test("Cursor-only visible script keeps its parsed visible:false seed (3212731906 hover text)")
    func visibleScriptSeedFalsePreservedWhenNeverAssigned() throws {
        let script = """
        'use strict';
        export function cursorEnter() { thisLayer.visible = true; }
        export function cursorLeave() { thisLayer.visible = false; }
        """
        let instance = try WPELayerScriptInstance(script: script, initialVisible: false)
        #expect(instance.initialOutput.own.visibleAssigned == false)
        #expect(instance.initialOutput.own.visible == false)

        let entered = try #require(instance.dispatchCursorEvent(
            .enter,
            pointerFrame: .neutral
        ))
        #expect(entered.own.visibleAssigned == true)
        #expect(entered.own.visible == true)

        let left = try #require(instance.dispatchCursorEvent(
            .leave,
            pointerFrame: .neutral
        ))
        #expect(left.own.visibleAssigned == true)
        #expect(left.own.visible == false)
    }

    @Test("Visible script that assigns visible=true overrides a false seed")
    func visibleScriptExplicitAssignmentOverridesSeed() throws {
        let script = """
        'use strict';
        export function init() { thisLayer.visible = true; }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script, initialVisible: false)
        #expect(instance.initialOutput.own.visibleAssigned == true)
        #expect(instance.initialOutput.own.visible == true)
    }

    @Test("Visible script that never touches alpha keeps the parsed alpha seed")
    func visibleScriptAlphaSeedPreservedWhenNeverAssigned() throws {
        let script = """
        'use strict';
        export function init() { thisLayer.visible = true; }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script, initialAlpha: 0.35)
        #expect(instance.initialOutput.own.alphaAssigned == false)
        #expect(instance.initialOutput.own.alpha == 0.35)
        let ticked = try #require(instance.tick())
        #expect(ticked.own.alphaAssigned == false)
        #expect(ticked.own.alpha == 0.35)
    }

    @Test("Visible script that assigns alpha overrides the parsed seed")
    func visibleScriptExplicitAlphaOverridesSeed() throws {
        let script = """
        'use strict';
        export function init() { thisLayer.alpha = 0.8; }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script, initialAlpha: 0.35)
        #expect(instance.initialOutput.own.alphaAssigned == true)
        #expect(instance.initialOutput.own.alpha == 0.8)
    }

    @Test("applyUserProperties activates the time-of-day switch (3470764447 后处理层)")
    func applyUserPropertiesDrivesTimeOfDaySwitch() throws {
        let script = """
        'use strict';
        var displayVideo = ["morning", "day", "dusk", "night", "mddn"];
        var electDisplay = false;
        var timeVarying = false;
        var morningtime = 4, daytime = 9, dusktime = 17, nighttime = 20;
        export function init() {
            displayVideo = displayVideo.map(video => thisScene.getLayer(video));
        }
        var playVideo = function(num) {
            displayVideo.forEach((video, i) => {
                if (i === num) { video.getVideoTexture().play(); video.visible = true; }
                else { video.getVideoTexture().pause(); video.visible = false; }
            });
        }
        export function update() {
            var hours = (new Date()).getHours();
            if (timeVarying) {
                if (hours >= morningtime && hours < daytime) playVideo(0);
                else if (hours >= daytime && hours < dusktime) playVideo(1);
                else if (hours >= dusktime && hours < nighttime) playVideo(2);
                else playVideo(3);
            }
        }
        export function applyUserProperties(p) {
            if (p.hasOwnProperty('timevarying')) timeVarying = p.timevarying;
            if (p.hasOwnProperty('morningtime')) morningtime = p.morningtime;
            if (p.hasOwnProperty('daytime')) daytime = p.daytime;
            if (p.hasOwnProperty('dusktime')) dusktime = p.dusktime;
            if (p.hasOwnProperty('nighttime')) nighttime = p.nighttime;
        }
        """
        let bands = ["morning", "day", "dusk", "night", "mddn"]
        let instance = try WPELayerScriptInstance(script: script)

        #expect(bands.allSatisfy { instance.initialOutput.others[$0] == nil })
        let beforeProps = try #require(instance.tick())
        #expect(bands.allSatisfy { beforeProps.others[$0] == nil })

        instance.applyUserProperties([
            "timevarying": .bool(true),
            "morningtime": .number(0),
            "daytime": .number(24),
            "dusktime": .number(24),
            "nighttime": .number(24),
        ])
        let afterProps = try #require(instance.tick())
        #expect(afterProps.others["morning"]?.visible == true)
        #expect(afterProps.others["morning"]?.videoCommands.contains(.play) == true)
        for hidden in ["day", "dusk", "night", "mddn"] {
            #expect(afterProps.others[hidden]?.visible == false)
            #expect(afterProps.others[hidden]?.videoCommands.contains(.pause) == true)
        }
    }

    @Test("applyUserProperties is a safe no-op for scripts without the handler")
    func applyUserPropertiesNoHandlerIsSafe() throws {
        let script = """
        'use strict';
        export function init() { thisLayer.visible = true; }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script)
        #expect(instance.handlesUserProperties == false)
        let output = try #require(instance.applyUserProperties(["timevarying": .bool(true)]))
        #expect(output.own.visible == true)
        #expect(try #require(instance.tick()).own.visible == true)
    }

    @Test("Layer script records an authored applyUserProperties handler")
    func detectsApplyUserPropertiesHandler() throws {
        let instance = try WPELayerScriptInstance(script: """
        export function init() { thisLayer.visible = true; }
        export function applyUserProperties(properties) {
            if (properties.enabled !== undefined) {
                thisLayer.visible = properties.enabled;
            }
        }
        """)

        #expect(instance.handlesUserProperties == true)
        let output = try #require(instance.applyUserProperties(["enabled": .bool(false)]))
        #expect(output.own.visible == false)
    }

    @Test("Text scriptProperties patch mutates the retained bag without reload")
    func textScriptPropertiesPatchIsLive() throws {
        let instance = try WPESceneScriptInstance(
            script: """
            var scriptProperties = { suffix: 'A' };
            export function update(value) { return 'clock-' + scriptProperties.suffix; }
            """,
            initialValue: "clock-A",
            scriptProperties: ["suffix": .string("A")]
        )

        #expect(instance.tickString() == "clock-A")
        #expect(instance.applyScriptPropertiesSuperseding(["suffix": .string("B")]))
        #expect(instance.tickString() == "clock-B")
    }

    @Test("Layer scriptProperties patch evaluates visibility on the instance lane")
    func layerScriptPropertiesPatchIsLive() throws {
        let instance = try WPELayerScriptInstance(
            script: """
            var scriptProperties = { shown: true };
            export function update(value) { return scriptProperties.shown; }
            """,
            scriptProperties: ["shown": .bool(true)]
        )

        let output = try #require(instance.applyScriptPropertiesSuperseding([
            "shown": .bool(false)
        ]))
        #expect(output.own.visible == false)
    }

    @Test("Transform scriptProperties patch supersedes the previous frame value")
    func transformScriptPropertiesPatchIsLive() throws {
        let instance = try WPEDynamicTransformScriptInstance(
            script: """
            var scriptProperties = { x: 1 };
            export function update(value) {
                return { x: scriptProperties.x, y: value.y, z: value.z };
            }
            """,
            scriptProperties: ["x": .number(1)],
            seed: SIMD3<Double>(1, 2, 3),
            canvasSize: SIMD2<Double>(1920, 1080)
        )

        #expect(instance.applyScriptPropertiesSuperseding(
            ["x": .number(5)],
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        ))
        let value = try #require(instance.tick(
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        ))
        #expect(value == SIMD3<Double>(5, 2, 3))
    }

    @Test("shared state coordinates across two layer scripts in one scene")
    func sharedStateCoordinatesAcrossInstances() throws {
        let store = WPESharedScriptState()
        _ = try WPELayerScriptInstance(script: """
        export function init() { shared.flag = true; shared.count = 7; }
        export function update() {}
        """, shared: store).initialOutput
        let reader = try WPELayerScriptInstance(script: """
        export function init() { thisLayer.visible = (shared.flag === true && shared.count === 7); }
        export function update() {}
        """, shared: store)
        #expect(reader.initialOutput.own.visible == true)
    }

    @Test("shared container mutations round-trip across scripts")
    func sharedContainerMutationsPersist() throws {
        let store = WPESharedScriptState()
        _ = try WPELayerScriptInstance(script: """
        export function init() {
            shared.logEntries = [];
            shared.records = [];
            shared.lastStates = { rocheLimit: '' };
        }
        export function update() {
            shared.logEntries.unshift('entry');
            shared.records.push({ number: 1, lifespan: 8 });
            shared.lastStates.rocheLimit = '大撕裂';
        }
        """, shared: store)
        .tick()
        let reader = try WPELayerScriptInstance(script: """
        export function init() {
            const le = shared.logEntries, rc = shared.records, ls = shared.lastStates;
            thisLayer.visible = !!le && le.length === 1
                && !!rc && rc.length === 1 && rc[0].lifespan === 8
                && !!ls && ls.rocheLimit === '大撕裂';
        }
        export function update() {}
        """, shared: store)
        #expect(reader.initialOutput.own.visible == true)
    }

    @Test("shared element mutation via find() writes back to the store")
    func sharedNestedElementMutationPersists() throws {
        let store = WPESharedScriptState()
        _ = try WPELayerScriptInstance(script: """
        export function init() { shared.records = [{ number: 2, lifespan: 0 }]; }
        export function update() {
            const r = shared.records.find(x => x.number === 2);
            if (r) { r.lifespan = 99; }
        }
        """, shared: store)
        .tick()
        let reader = try WPELayerScriptInstance(script: """
        export function init() {
            const rc = shared.records;
            thisLayer.visible = !!rc && rc.length === 1 && rc[0].lifespan === 99;
        }
        export function update() {}
        """, shared: store)
        #expect(reader.initialOutput.own.visible == true)
    }

    @Test("applyUserProperties can seed shared state from scriptProperties")
    func applyUserPropertiesSeedsSharedState() throws {
        let store = WPESharedScriptState()
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCheckbox({ name: 'menuEn', value: true })
            .finish();
        export function applyUserProperties(changedUserProperties) {
            if (!scriptProperties.menuEn) { shared.dd = 0; }
            else { shared.dd = 1; }
        }
        """
        let instance = try WPELayerScriptInstance(
            script: script,
            scriptProperties: ["menuEn": .bool(true)],
            shared: store
        )
        _ = instance.applyUserProperties(["menuinit": .bool(true)])
        #expect(store.get("dd") as? Double == 1)
    }

    @Test("getParent / getAnimationLayer / scene.on stubs let a UI script run without throwing")
    func hierarchyAndEventStubsDoNotThrow() throws {
        let instance = try WPELayerScriptInstance(script: """
        scene.on("update", function() {});
        let parent;
        export function init() {
            parent = thisLayer.getParent().getParent();
            thisLayer.getAnimationLayer("x").play();
            thisLayer.visible = Math.abs(parent.scale.x) < 0.05;
        }
        export function update() {}
        """, shared: WPESharedScriptState())
        #expect(instance.initialOutput.own.visible == false)
    }

    @Test("thisScene.createLayer returns a writable layer handle")
    func createLayerStubReturnsWritableLayerHandle() throws {
        let store = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            let point = thisScene.createLayer({
                origin: new Vec3(1, 2, 3),
                alpha: 0,
                visible: false
            });
            point.color = new Vec3(1, 0, 0);
            point.scale = new Vec3(0.1, 0.1, 0.1);
            point.alpha = 0.5;
            point.visible = true;
            shared.created = point.visible && point.alpha === 0.5 ? 1 : 0;
        }
        export function update() {}
        """, shared: store)

        #expect(instance.initialOutput.own.visible == true)
        #expect(instance.initialOutput.created.first?.imagePath == "")
        #expect(store.get("created") as? Double == 1)
    }

    @Test("thisScene.createLayer exposes created layer state")
    func createLayerExposesCreatedLayerState() throws {
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            let point = thisScene.createLayer({
                image: "models/ta.json",
                origin: new Vec3(1, 2, 3),
                color: new Vec3(0.25, 0.5, 0.75),
                alpha: 0.25,
                scale: new Vec3(0.1, 0.2, 0.3),
                visible: true
            });
            point.origin = new Vec3(4, 5, 6);
            point.alpha = 0.75;
        }
        export function update() {}
        """)

        let created = try #require(instance.initialOutput.created.first)
        #expect(created.imagePath == "models/ta.json")
        #expect(created.origin == SIMD3<Double>(4, 5, 6))
        #expect(created.color == SIMD3<Double>(0.25, 0.5, 0.75))
        #expect(created.scale == SIMD3<Double>(0.1, 0.2, 0.3))
        #expect(created.alpha == 0.75)
        #expect(created.visible == true)
    }

    @Test("Layer script receives cursor input and click handlers")
    func layerScriptReceivesCursorInputAndClickHandlers() throws {
        let store = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(
            script: """
            export function cursorMove() { shared.move = 1; }
            export function cursorDown() { shared.down = 1; }
            export function cursorUp() { shared.up = 1; }
            export function cursorClick(e) {
                shared.click = 1;
                shared.wx = e.worldPosition.x;
                shared.ly = e.localPosition.y;
                shared.hit = e.hitBox;
            }
            export function update() {
                shared.x = input.cursorScreenPosition.x;
                shared.y = input.cursorScreenPosition.y;
                thisLayer.alpha = shared.down === 1 && shared.up !== 1 ? 0.25 : 1;
            }
            """,
            shared: store,
            canvasSize: SIMD2<Double>(200, 100)
        )

        let downFrame = WPEPointerFrame(
            position: SIMD2<Double>(0.25, 0.75),
            clickPosition: SIMD2<Double>(0.25, 0.75),
            isDown: true,
            isRightDown: false
        )
        _ = instance.dispatchCursorEvent(.down, pointerFrame: downFrame)
        let downOutput = try #require(instance.tick(pointerFrame: downFrame))

        #expect(store.get("down") as? Double == 1)
        #expect(store.get("x") as? Double == 50)
        #expect(store.get("y") as? Double == 75)
        #expect(downOutput.own.alpha == 0.25)

        let upFrame = WPEPointerFrame(
            position: SIMD2<Double>(0.4, 0.2),
            clickPosition: SIMD2<Double>(0.25, 0.75),
            isDown: false,
            isRightDown: false
        )
        _ = instance.dispatchCursorEvent(.up, pointerFrame: upFrame)
        _ = instance.dispatchCursorEvent(.move, pointerFrame: upFrame)
        let hit = WPELayerScriptCursorHit(
            worldPosition: SIMD3<Double>(1, 2, 3),
            localPosition: SIMD3<Double>(4, 5, 6),
            hitBox: "body"
        )
        _ = instance.dispatchCursorEvent(.click, pointerFrame: upFrame, hit: hit)
        let upOutput = try #require(instance.tick(pointerFrame: upFrame))

        #expect(store.get("up") as? Double == 1)
        #expect(store.get("move") as? Double == 1)
        #expect(store.get("click") as? Double == 1)
        #expect(store.get("wx") as? Double == 1)
        #expect(store.get("ly") as? Double == 5)
        #expect(store.get("hit") as? String == "body")
        #expect(store.get("x") as? Double == 80)
        #expect(store.get("y") as? Double == 20)
        #expect(upOutput.own.alpha == 1)
        #expect(hit.hitBox == "body")
    }

    // MARK: - Async latest-snapshot ticks

    @Test("Outcome slot: newest wins, consume-once, in-flight back-pressure")
    func outcomeSlotSemantics() throws {
        let slot = WPESceneScriptOutcomeSlot<Int>()
        #expect(slot.takeLatest() == nil)
        slot.publishEvent(1)
        slot.publishEvent(2)
        #expect(slot.takeLatest() == 2)
        #expect(slot.takeLatest() == nil)
        let firstClaim = try #require(slot.beginTick())
        #expect(slot.beginTick() == nil)
        #expect(slot.publishTick(3, for: firstClaim))
        let rejectedClaim = try #require(slot.beginTick())
        #expect(slot.rejectTick(rejectedClaim))
        let freshClaim = try #require(slot.beginTick())
        #expect(!slot.publishTick(99, for: rejectedClaim))
        #expect(slot.publishTick(4, for: freshClaim))
        #expect(slot.takeLatest() == 4)
        slot.publishEvent(5)
        #expect(slot.supersede(with: 6) == 6)
        #expect(slot.takeLatest() == nil)
    }

    @Test("Layer outputs merge: video commands accumulate, newest state wins")
    func layerOutputMergePreservesVideoCommands() {
        let pending = WPELayerScriptOutput(
            own: WPELayerScriptState(visible: false, alpha: 0.25, videoCommands: [.play]),
            others: [
                "loop": WPELayerScriptState(
                    visible: true, alpha: 1, videoCommands: [.seek(0)],
                    visibleAssigned: false, alphaAssigned: false
                ),
                "both": WPELayerScriptState(visible: false, alpha: 0, videoCommands: [.pause]),
            ]
        )
        let newer = WPELayerScriptOutput(
            own: WPELayerScriptState(visible: true, alpha: 1, videoCommands: [.stop]),
            others: ["both": WPELayerScriptState(visible: true, alpha: 0.5, videoCommands: [])]
        )
        let merged = LiveWallpaper.WPELayerScriptInstance.mergedOutputs(pending: pending, newer: newer)
        #expect(merged.own.visible == true)
        #expect(merged.own.videoCommands == [.play, .stop])
        #expect(merged.others["both"]?.visible == true)
        #expect(merged.others["both"]?.videoCommands == [.pause])
        #expect(merged.others["loop"]?.videoCommands == [.seek(0)])
    }

    @Test("Seeded text script serves the scripted value on the first live tick")
    func textSeedAvoidsPlaceholderPop() throws {
        let instance = try WPESceneScriptInstance(
            script: "export function update(value) { return 'scripted'; }",
            initialValue: "placeholder"
        )
        instance.seedAsyncTick()
        #expect(WPEBatchTickDriver.tick(instance) == "scripted")
    }

    @Test("Kill-switch legacy path: synchronous tick returns the fresh result immediately")
    func legacySynchronousTickReturnsImmediately() throws {
        let instance = try WPESceneScriptInstance(
            script: "export function update(value) { return value + '!'; }",
            initialValue: "x"
        )
        #expect(instance.tickString() == "x!")
        #expect(instance.tickString() == "x!!")
    }

    @Test("Seeded transform script serves its scripted value on the first live tick")
    func transformSeedAvoidsFirstFramePop() throws {
        let script = """
        export function update(value) { value.x = value.x + 1; return value; }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(10, 20, 30),
            canvasSize: SIMD2<Double>(100, 100)
        )
        instance.seedAsyncTick(pointerPosition: SIMD2<Double>(0.5, 0.5))
        let first = WPEBatchTickDriver.tick(instance, pointerPosition: SIMD2<Double>(0.5, 0.5))
        #expect(first == SIMD3<Double>(11, 20, 30))
    }

    @Test("Transform init captures a real parent handle whose transform reads stay live")
    func transformScriptReadsLiveParentSnapshot() throws {
        let shared = WPESharedScriptState(layers: [
            WPESceneScriptLayerInfo(
                id: "parent", name: "Parent", size: SIMD2(400, 200),
                origin: SIMD2(0, -10), scale: SIMD3(2, 1, 1), index: 0,
                parentName: nil
            ),
            WPESceneScriptLayerInfo(
                id: "child", name: "Child", size: SIMD2(100, 40),
                origin: SIMD2(0, -66), index: 1, parentName: "Parent"
            ),
        ])
        shared.publishLayerTransforms(
            origins: ["parent": SIMD3(0, 42, 0)],
            scales: ["parent": SIMD3(4, 1, 1)],
            angles: [:]
        )
        let instance = try LiveWallpaper.WPEDynamicTransformScriptInstance(
            script: """
            let initial, parent;
            export function init(value) { initial = value; parent = thisLayer.getParent(); }
            export function update(value) {
                value.x = initial.x / parent.scale.x;
                value.y = initial.y * Math.sign(-parent.origin.y);
                return value;
            }
            """,
            seed: SIMD3<Double>(8, -66, 0),
            canvasSize: SIMD2<Double>(1920, 1080),
            ownLayerName: "Child",
            shared: shared
        )

        #expect(instance.tick(pointerPosition: SIMD2<Double>.zero) == SIMD3<Double>(2, 66, 0))
        shared.publishLayerTransforms(
            origins: ["parent": SIMD3(0, -42, 0)],
            scales: ["parent": SIMD3(2, 1, 1)],
            angles: [:]
        )
        #expect(instance.tick(pointerPosition: SIMD2<Double>.zero) == SIMD3<Double>(4, -66, 0))
    }

    @Test("Async transform ticks chain lastValue like the legacy path")
    func asyncTransformChainsLastValue() async throws {
        let script = """
        export function update(value) { value.x = value.x + 1; return value; }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(10, 20, 30),
            canvasSize: SIMD2<Double>(100, 100)
        )
        instance.seedAsyncTick(pointerPosition: SIMD2<Double>(0.5, 0.5))
        #expect(WPEBatchTickDriver.tick(instance, pointerPosition: SIMD2<Double>(0.5, 0.5)) == SIMD3<Double>(11, 20, 30))
        var sawChainedResult = false
        for _ in 0..<200 {
            let value = WPEBatchTickDriver.tick(instance, pointerPosition: SIMD2<Double>(0.5, 0.5))
            if value == SIMD3<Double>(12, 20, 30) {
                sawChainedResult = true
                break
            }
            #expect(value == SIMD3<Double>(11, 20, 30))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(sawChainedResult)
    }

    @Test("Transform script allows one transient update exception to recover")
    func transformTransientRuntimeExceptionRecovers() throws {
        let script = """
        var attempts = 0;
        export function update(value) {
            attempts += 1;
            if (attempts === 1) { throw new Error('unsupported runtime API'); }
            value.x = 999;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(10, 20, 30),
            canvasSize: SIMD2<Double>(100, 100)
        )

        #expect(instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)) == nil)
        #expect(
            instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)) == SIMD3<Double>(999, 20, 30)
        )
    }

    @Test("Transform script quarantines after repeated update exceptions")
    func transformRepeatedRuntimeExceptionDoesNotRetryEveryFrame() throws {
        let script = """
        var attempts = 0;
        export function update(value) {
            attempts += 1;
            if (attempts <= 3) { throw new Error('unsupported runtime API'); }
            value.x = 999;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(10, 20, 30),
            canvasSize: SIMD2<Double>(100, 100)
        )

        for _ in 0..<4 {
            #expect(
                instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)) == nil,
                "After the bounded retry window, the transform must keep its baked value instead of re-entering JavaScriptCore"
            )
        }
    }

    @Test("Async cursor event outcome drains through the next batch tick")
    func asyncCursorEventDrainsThroughLiveTick() async throws {
        let script = """
        export function cursorDown() {
            thisLayer.getVideoTexture().play();
            thisLayer.alpha = 0.25;
        }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(
            script: script,
            governor: WPESceneScriptExecutionGovernor(limit: 1)
        )
        let frame = WPEPointerFrame(
            position: SIMD2<Double>(0.5, 0.5),
            clickPosition: SIMD2<Double>(0.5, 0.5),
            isDown: true,
            isRightDown: false
        )
        instance.liveDispatchCursorEvent(.down, pointerFrame: frame)
        var received: WPELayerScriptOutput?
        for _ in 0..<100 {
            if let output = WPEBatchTickDriver.tick(instance, pointerFrame: frame) {
                received = output
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let output = try #require(received)
        #expect(output.own.videoCommands.contains(.play))
        #expect(output.own.alpha == 0.25)
    }

    @Test("Superseding property push folds a pending tick's video commands")
    func supersedingPropertyPushFoldsPendingTick() throws {
        let script = """
        var started = false;
        export function update() {
            if (!started) { started = true; thisLayer.getVideoTexture().play(); }
            thisLayer.visible = true;
        }
        """
        let instance = try WPELayerScriptInstance(script: script)
        #expect(WPEBatchTickDriver.tick(instance) == nil)
        let merged = try #require(instance.applyUserPropertiesSuperseding(["k": .bool(true)]))
        #expect(merged.own.videoCommands.contains(.play))
        #expect(merged.own.visible == true)
        #expect(WPEBatchTickDriver.tick(instance) == nil)
    }

    @Test("Superseding property push waits out an in-flight slow tick without poisoning")
    func supersedingPropertyPushWaitsOutInFlightSlowTick() throws {
        let script = """
        var n = 0;
        export function update() {
            n += 1;
            if (n === 1) {
                var t0 = Date.now();
                while (Date.now() - t0 < 700) {}
                thisLayer.getVideoTexture().play();
            }
            thisLayer.visible = true;
        }
        export function applyUserProperties(p) { thisLayer.alpha = 0.5; }
        """
        let instance = try WPELayerScriptInstance(script: script, tickBudget: 0.5)
        #expect(WPEBatchTickDriver.tick(instance) == nil)
        let merged = try #require(instance.applyUserPropertiesSuperseding(["k": .bool(true)]))
        #expect(merged.own.alpha == 0.5)
        #expect(merged.own.videoCommands.contains(.play))
        #expect(merged.own.visible == true)
        #expect(instance.applyUserPropertiesSuperseding(["k": .bool(false)]) != nil)
    }

    // MARK: - Consumer-before-producer recovery

    @Test("Text script that throws on unset shared state recovers on a later tick")
    func textScriptRecoversOnceSharedStateArrives() throws {
        let shared = WPESharedScriptState()
        let script = """
        export function update(value) {
            return '[' + shared.xx1.toFixed(2) + ']';
        }
        """
        let instance = try WPESceneScriptInstance(
            script: script,
            initialValue: "placeholder",
            shared: shared
        )
        #expect(instance.tickString() == "placeholder")
        let producer = try WPELayerScriptInstance(
            script: "export function update() { shared.xx1 = 1.5; }",
            shared: shared
        )
        _ = producer.tick(runtimeSeconds: 0, pointerFrame: .neutral)
        #expect(instance.tickString() == "[1.50]")
    }

    @Test("Parser keeps a script-driven text object whose authored value is empty")
    func parserKeepsScriptedTextWithEmptyAuthoredValue() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [
                {
                    "id": 345,
                    "name": "time",
                    "text": {
                        "script": "export function update(value) { return '1 Years'; }",
                        "value": ""
                    },
                    "origin": "0 0 0"
                },
                {
                    "id": 346,
                    "name": "empty-static",
                    "text": {"value": ""},
                    "origin": "0 0 0"
                }
            ]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let scripted = try #require(document.textObjects.first(where: { $0.id == "345" }))
        #expect(scripted.text.isEmpty)
        #expect(scripted.textScript?.isEmpty == false)
        #expect(!document.textObjects.contains(where: { $0.id == "346" }))
    }
}
