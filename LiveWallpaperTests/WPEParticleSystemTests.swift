import Foundation
import LiveWallpaperProWPE
import Metal
import simd
import Testing
@testable import LiveWallpaper

struct WPEParticleSystemTests {

    @Test("Parses canonical snowflat-style particle JSON")
    func parsesCanonicalParticleJSON() throws {
        let json = #"""
        {
            "material": "materials/presets/snowflat.json",
            "maxcount": 300,
            "starttime": 5,
            "emitter": [{
                "rate": 15,
                "origin": "0 650 0",
                "distancemin": 10,
                "distancemax": 1200
            }],
            "initializer": [
                {"name": "lifetimerandom", "min": 15, "max": 23},
                {"name": "sizerandom", "min": 2, "max": 30},
                {"name": "velocityrandom", "min": "-10 -50 0", "max": "-37 -90 0"},
                {"name": "colorrandom", "min": "95 98 100", "max": "255 255 255"}
            ],
            "operator": [{"name": "alphafade", "fadeintime": 0.4}]
        }
        """#
        let data = Data(json.utf8)
        let def = try #require(WPEParticleDefinitionParser.parse(data: data))

        #expect(def.materialRelativePath == "materials/presets/snowflat.json")
        #expect(def.maxCount == 300)
        #expect(def.startDelay == 5)
        #expect(def.rate == 15)
        #expect(def.lifetimeMin == 15)
        #expect(def.lifetimeMax == 23)
        #expect(def.sizeMin == 2)
        #expect(def.sizeMax == 30)
        #expect(def.fadeInSeconds == 0.4)
        #expect(def.colorMax.x == 255 && def.colorMax.y == 255)
    }

    @Test("Unrecognized initializer and operator names surface as diagnostics")
    func unknownInitializerAndOperatorNamesAreDiagnosed() throws {
        let json: [String: Any] = [
            "maxcount": 10,
            "emitter": [["rate": 1]],
            "initializer": [
                ["name": "lifetimerandom", "min": 1, "max": 2],
                ["name": "notarealinitializer", "value": 3]
            ],
            "operator": [
                ["name": "alphafade", "fadeintime": 0.4],
                ["name": "notarealoperator", "scale": 1]
            ]
        ]
        var diagnostics: [WPESceneDiagnostic] = []
        _ = WPEParticleDefinitionParser.parse(dictionary: json, diagnostics: &diagnostics)
        #expect(diagnostics.contains { $0.message.contains("notarealinitializer") })
        #expect(diagnostics.contains { $0.message.contains("notarealoperator") })
        // Recognized names must NOT be flagged.
        #expect(!diagnostics.contains { $0.message.contains("lifetimerandom") })
        #expect(!diagnostics.contains { $0.message.contains("alphafade") })
    }

    @Test("Parser captures child references preserving duplicates and origin")
    func parserCapturesChildParticleDefinitions() throws {
        let json = #"""
        {
            "children": [
                {"id": 13, "name": "particles/presets/leaves2b.json"},
                {"id": 14, "name": "particles/presets/leaves2b.json", "origin": "60 0 0", "type": "eventfollow"}
            ],
            "maxcount": 5,
            "emitter": [{"rate": 1}]
        }
        """#

        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))

        #expect(def.childReferences.map(\.relativePath) == [
            "particles/presets/leaves2b.json",
            "particles/presets/leaves2b.json"
        ])
        #expect(def.childReferences.count == 2)
        #expect(def.childReferences[0].id == 13)
        #expect(def.childReferences[0].originOffset == SIMD3<Double>(0, 0, 0))
        #expect(!def.childReferences[0].isEventFollow)
        #expect(def.childReferences[1].id == 14)
        #expect(def.childReferences[1].originOffset == SIMD3<Double>(60, 0, 0))
        #expect(def.childReferences[1].isEventFollow)
    }

    @Test("Parser treats explicit empty renderer as simulate-only")
    func parserCapturesRendererGate() throws {
        let spawner = #"""
        {
            "renderer": [],
            "children": [{"name": "particles/presets/child.json"}],
            "maxcount": 5,
            "emitter": [{"rate": 1}]
        }
        """#
        let drawable = #"""
        {
            "renderer": [{"name": "sprite"}],
            "maxcount": 5,
            "emitter": [{"rate": 1}]
        }
        """#
        let legacy = #"""
        {
            "maxcount": 5,
            "emitter": [{"rate": 1}]
        }
        """#

        #expect(try #require(WPEParticleDefinitionParser.parse(data: Data(spawner.utf8))).rendersSprite == false)
        #expect(try #require(WPEParticleDefinitionParser.parse(data: Data(drawable.utf8))).rendersSprite == true)
        #expect(try #require(WPEParticleDefinitionParser.parse(data: Data(legacy.utf8))).rendersSprite == true)
    }

    @Test("Parser defaults sphere random emitters to 2D directions")
    func parserDefaultsSphereRandomEmittersTo2DDirections() throws {
        let json = #"""
        {
            "maxcount": 500,
            "emitter": [{
                "name": "sphererandom",
                "rate": 5,
                "distancemin": 64,
                "distancemax": 1024
            }]
        }
        """#

        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))

        #expect(def.directionMask == SIMD3<Double>(1, 1, 0))
    }

    @Test("Particle instance override scales count rate lifetime size and speed")
    func particleInstanceOverrideScalesDefinition() {
        let base = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 5,
            rate: 1.7,
            startDelay: 3,
            lifetimeMin: 20, lifetimeMax: 20,
            sizeMin: 100, sizeMax: 110,
            originOffset: SIMD3(350, 750, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(750, 750, 750),
            velocityMin: SIMD3(-200, -100, 0), velocityMax: SIMD3(-300, -15, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 236, 0),
            fadeInSeconds: 0.1,
            turbulentVelocityInit: WPEParticleTurbulentVelocityInit(speedMin: 35, speedMax: 100)
        )
        let override = WPESceneParticleInstanceOverride(
            count: 0.2,
            rate: 0.5,
            lifetime: 1.77,
            size: 0.69,
            speed: 1.32,
            alpha: 0.03,
            brightness: 2,
            color: SIMD3<Double>(192, 192, 192)
        )

        let scaled = base.applying(instanceOverride: override)

        #expect(scaled.maxCount == 1)
        #expect(abs(scaled.rate - 0.85) < 0.0001)
        #expect(abs(scaled.lifetimeMin - 35.4) < 0.0001)
        #expect(abs(scaled.sizeMin - 69) < 0.0001)
        #expect(abs(scaled.sizeMax - 75.9) < 0.0001)
        #expect(abs(scaled.velocityMin.x - (-264)) < 0.0001)
        #expect(abs((scaled.turbulentVelocityInit?.speedMax ?? 0) - 132) < 0.0001)
        #expect(abs(scaled.alphaMin - 0.03) < 0.0001)
        #expect(abs(scaled.alphaMax - 0.03) < 0.0001)
        #expect(scaled.colorMin == SIMD3<Double>(384, 384, 384))
        let expectedColorMax = SIMD3<Double>(384, 2 * 236.0 * 192.0 / 255.0, 0)
        #expect(abs(scaled.colorMax.x - expectedColorMax.x) < 0.0001)
        #expect(abs(scaled.colorMax.y - expectedColorMax.y) < 0.0001)
        #expect(abs(scaled.colorMax.z - expectedColorMax.z) < 0.0001)
    }

    @Test("particle instance brightness survives as HDR vertex RGB")
    func particleInstanceBrightnessProducesHDRVertexColor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let base = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 0, instantaneousCount: 1, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: .zero,
            dispersalMin: .zero, dispersalMax: .zero,
            velocityMin: .zero, velocityMax: .zero,
            colorMin: SIMD3<Double>(255, 255, 255),
            colorMax: SIMD3<Double>(255, 255, 255),
            fadeInSeconds: 0
        )
        let definition = base.applying(
            instanceOverride: WPESceneParticleInstanceOverride(brightness: 4))
        let system = try #require(WPEParticleSystem(
            definition: definition, device: device, seed: 0x3509_2436_56))

        system.tick(now: 0)

        #expect(system.liveInstanceCount == 1)
        let instance = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0]
        #expect(instance.color.x == 4)
        #expect(instance.color.y == 4)
        #expect(instance.color.z == 4)
        #expect(instance.color.w == 1)
    }

    @Test("Emitter respects start delay before spawning")
    func emitterRespectsStartDelay() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var def = WPEParticleDefinition.empty
        def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 16,
            rate: 100,
            startDelay: 1.0,
            lifetimeMin: 5, lifetimeMax: 5,
            sizeMin: 4, sizeMax: 4,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 0)
        system.tick(now: 0.5)
        #expect(system.liveInstanceCount == 0)
        system.tick(now: 1.5)
        #expect(system.liveInstanceCount > 0)
    }

    @Test("Emitter caps live count at maxCount")
    func emitterCapsAtMaxCount() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 8,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 4, sizeMax: 4,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        system.tick(now: 1.0)
        #expect(system.liveInstanceCount == 8)
    }

    @Test("Pointer-tracking emitter stops + clears when Follow Cursor is off")
    func pointerEmitterStopsWhenFollowDisabled() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 16,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 4, sizeMax: 4,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1,
            controlPoints: [WPEParticleControlPoint(id: 0, offset: SIMD3(0, 0, 0), pointerLocked: true)]
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        #expect(system.tracksPointer)

        system.pointerCentered = SIMD2<Float>(10, 20)
        system.tick(now: 0)
        system.tick(now: 1.0)
        #expect(system.liveInstanceCount > 0)

        system.clearLiveParticles()
        #expect(system.liveInstanceCount == 0)
        system.pointerCentered = nil
        system.tick(now: 2.0)
        system.tick(now: 3.0)
        #expect(system.liveInstanceCount == 0)

        system.pointerCentered = SIMD2<Float>(30, 40)
        system.tick(now: 4.0)
        #expect(system.liveInstanceCount > 0)
    }

    @Test("Pointer-locked empty systems report blocked-on-absent-pointer")
    func pointerLockedEmptySystemIsBlockedOnAbsentPointer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 16,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 4, sizeMax: 4,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1,
            controlPoints: [WPEParticleControlPoint(id: 0, offset: SIMD3(0, 0, 0), pointerLocked: true)]
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        #expect(system.isBlockedOnAbsentPointer)
        system.pointerCentered = SIMD2<Float>(1, 1)
        #expect(!system.isBlockedOnAbsentPointer)
        system.pointerCentered = nil
        #expect(system.isBlockedOnAbsentPointer)
    }

    @Test("Particle system allocates GPU buffer of expected size")
    func allocatesGPUBuffer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 64,
            rate: 0, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        #expect(system.capacity == 64)
        #expect(system.instanceBuffer.length == 64 * MemoryLayout<WPEParticleInstance>.stride)
    }

    @Test("Particle frame slots do not overwrite an in-flight instance buffer")
    func particleFrameSlotsKeepIndependentInstanceBuffers() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 32,
            rate: 1_000, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 4, sizeMax: 4,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 10, 0), velocityMax: SIMD3(0, 10, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let system = try #require(
            WPEParticleSystem(definition: def, device: device, seed: 0xF12A_0001)
        )

        system.tick(now: 0, frameSlot: 0)
        system.tick(now: 0.1, frameSlot: 0)
        let slotZero = system.instanceBuffer
        let slotZeroBytes = Data(bytes: slotZero.contents(), count: slotZero.length)

        system.tick(now: 0.2, frameSlot: 1)

        #expect(system.instanceBuffer !== slotZero)
        #expect(Data(bytes: slotZero.contents(), count: slotZero.length) == slotZeroBytes)
    }

    @Test("Capacity ceiling protects against malformed maxcount")
    func capacityCeiling() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 100_000,
            rate: 0, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        #expect(system.capacity == WPEParticleSystem.absoluteCap)
    }

    @Test("Parser captures rotation, angular velocity, alpha random, fadeout, gravity, drag")
    func parserCapturesP1Operators() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "initializer": [
                {"name": "alpharandom", "min": 0.15, "max": 0.2},
                {"name": "rotationrandom", "min": "0 0 -1", "max": "0 0 1"},
                {"name": "angularvelocityrandom", "min": "0 0 -2", "max": "0 0 2"}
            ],
            "operator": [
                {"name": "alphafade", "fadeintime": 0.1, "fadeouttime": 0.9},
                {"name": "alphachange", "starttime": 0, "endtime": 0.8, "startvalue": 1, "endvalue": 0},
                {"name": "oscillatealpha", "frequencymin": 0.5, "frequencymax": 0.5, "scalemin": 0.6, "phasemin": 0.25},
                {"name": "movement", "gravity": "0 -50 0", "drag": 0.5},
                {"name": "angularmovement", "force": "0 0 3", "drag": 0.2}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.alphaMin == 0.15)
        #expect(def.alphaMax == 0.2)
        #expect(def.rotationMin.z == -1)
        #expect(def.rotationMax.z == 1)
        #expect(def.angularVelocityMin.z == -2)
        #expect(def.angularVelocityMax.z == 2)
        #expect(def.fadeInSeconds == 0.1)
        #expect(def.fadeOutSeconds == 0.9)
        let alphaChange = try #require(def.alphaChange)
        #expect(alphaChange.startTime == 0)
        #expect(alphaChange.endTime == 0.8)
        #expect(alphaChange.startValue == 1)
        #expect(alphaChange.endValue == 0)
        let oscillateAlpha = try #require(def.oscillateAlpha)
        #expect(oscillateAlpha.frequencyMin == 0.5)
        #expect(oscillateAlpha.frequencyMax == 0.5)
        #expect(oscillateAlpha.scaleMin == 0.6)
        #expect(oscillateAlpha.scaleMax == 1)
        #expect(oscillateAlpha.phaseMin == 0.25)
        #expect(def.gravity.y == -50)
        #expect(def.drag == 0.5)
        #expect(def.angularForceZ == 3)
        #expect(def.angularDrag == 0.2)
    }

    @Test("Bare random initializers seed engine defaults, not zero")
    func bareRandomInitializersTakeEngineDefaults() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "initializer": [
                {"name": "velocityrandom"},
                {"name": "angularvelocityrandom"},
                {"name": "rotationrandom"}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.velocityMin == SIMD3<Double>(-32, -32, 0))
        #expect(def.velocityMax == SIMD3<Double>(32, 32, 0))
        #expect(def.angularVelocityMin.z == -5)
        #expect(def.angularVelocityMax.z == 5)
        #expect(def.rotationMax.z == 2 * .pi)
        #expect(def.rotationMax.x == 0)
        #expect(def.rotationMax.y == 0)
    }

    @Test("Only a literal rope takes the ribbon path; ropetrail/spritetrail do not")
    func trailRendererTaxonomy() throws {
        func def(_ renderer: String, extra: String = "") throws -> WPEParticleDefinition {
            let json = #"""
            {
                "maxcount": 100,
                "material": "materials/m.json",
                "initializer": [{"name": "lifetimerandom", "min": 4, "max": 4}],
                "renderer": [{"name": "\#(renderer)"\#(extra)}]
            }
            """#
            return try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        }

        let ropetrail = try def("ropetrail", extra: #", "length": 3"#)
        #expect(!ropetrail.isRope, "ropetrail must not join the whole chain")
        #expect(ropetrail.trailRenderer?.length == 3)
        #expect(ropetrail.trailRenderer?.kind == .rope)
        #expect(ropetrail.usesTrailRibbon, "ropetrail drags a per-particle history ribbon")

        let spritetrail = try def("spritetrail", extra: #", "length": 5, "maxlength": 40"#)
        #expect(!spritetrail.isRope)
        #expect(spritetrail.trailRenderer?.length == 5)
        #expect(spritetrail.trailRenderer?.maxLength == 40)
        #expect(spritetrail.trailRenderer?.kind == .sprite)
        #expect(!spritetrail.usesTrailRibbon, "spritetrail stretches a quad, no ribbon")

        let defaulted = try #require(ropetrail.trailRenderer)
        #expect(defaulted.maxLength == 10, "absent maxlength is 10, never unbounded")
        #expect(defaulted.subdivision == 3)
        let bare = try #require(try def("spritetrail").trailRenderer)
        #expect(bare.length == 0.05)
        #expect(bare.maxLength == 10)

        let rope = try def("rope")
        #expect(rope.isRope)
        #expect(rope.trailRenderer == nil)
        #expect(!rope.usesTrailRibbon, "rope threads one ribbon, not per-particle ones")

        let sprite = try def("sprite")
        #expect(!sprite.isRope)
        #expect(sprite.trailRenderer == nil)
        #expect(!sprite.usesTrailRibbon)
    }

    @Test("Parser reads emitter sign and normalizes each axis to -1/0/1")
    func parserReadsEmitterSign() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{
                "name": "sphererandom", "rate": 1,
                "distancemin": 10, "distancemax": 100,
                "sign": "0 -0.5 3"
            }]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.sign == SIMD3<Double>(0, -1, 1))
    }

    @Test("Emitter sign defaults to zero (no axis forced) when absent")
    func parserDefaultsSignToZero() throws {
        let json = #"""
        {"maxcount": 10, "emitter": [{"name": "sphererandom", "rate": 1}]}
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.sign == SIMD3<Double>(0, 0, 0))
    }

    @Test("Parser retains emitter radial speed bounds")
    func parserRetainsEmitterRadialSpeedBounds() throws {
        let json = #"{"maxcount":10,"emitter":[{"speedmin":100,"speedmax":35}]}"#
        let definition = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))

        #expect(definition.emitterSpeedMin == 35)
        #expect(definition.emitterSpeedMax == 100)
    }

    @Test("applyEmitterSign forces a nonzero axis to abs(value) * sign, passes zero axes through")
    func applyEmitterSignForcesOnlyNonzeroAxes() {
        let p = SIMD3<Double>(-2, 3, -5)
        let zOnly = WPEParticleSystem.applyEmitterSign(p, sign: SIMD3<Double>(0, 0, 1))
        #expect(zOnly == SIMD3<Double>(-2, 3, 5))

        let allForced = WPEParticleSystem.applyEmitterSign(p, sign: SIMD3<Double>(1, -1, 1))
        #expect(allForced == SIMD3<Double>(2, -3, 5))

        let untouched = WPEParticleSystem.applyEmitterSign(p, sign: SIMD3<Double>(0, 0, 0))
        #expect(untouched == p)
    }

    @Test("Emitter radial speed follows the relative dispersal direction")
    func emitterRadialSpeedFollowsDispersal() {
        let velocity = WPEParticleSystem.emitterRadialVelocity(
            dispersal: SIMD3<Float>(3, 4, 0),
            speed: 10
        )
        #expect(simd_distance(velocity, SIMD3<Float>(6, 8, 0)) < 0.000_1)
        #expect(WPEParticleSystem.emitterRadialVelocity(dispersal: .zero, speed: 10) == .zero)
    }

    #if !LITE_BUILD && DEBUG
    @Test("Sphere emitter sign=\"0 0 1\" keeps every spawned particle at non-negative depth (scene 3462491575 snowperspective dust)")
    func sphereEmitterSignKeepsParticlesInFrontOfCamera() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let json = #"""
        {
            "maxcount": 400, "flags": 4,
            "emitter": [{
                "name": "sphererandom", "rate": 100000,
                "distancemin": 10, "distancemax": 500,
                "directions": "1 1 1", "sign": "0 0 1"
            }]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.sign == SIMD3<Double>(0, 0, 1))
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        for step in 1...4 { system.tick(now: Double(step) * 0.05) }
        try #require(system.liveInstanceCount >= 32)

        var sampled = 0
        for rawLine in system.particleStateDumpText().split(separator: "\n") {
            let line = String(rawLine)
            guard let open = line.range(of: "pos=("),
                  let close = line.range(of: ")", range: open.upperBound..<line.endIndex)
            else { continue }
            let parts = line[open.upperBound..<close.lowerBound].split(separator: ",")
            guard parts.count == 3, let z = Double(parts[2]) else { continue }
            #expect(z >= 0, "sign=\"0 0 1\" must force every particle's depth non-negative (z=\(z))")
            sampled += 1
        }
        #expect(sampled >= 32)
    }

    @Test("Sphere radius sampling is volume-uniform: seeded average lands well past the naive-uniform midpoint")
    func sphereRadiusSamplingIsVolumeUniformUnderSeed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let json = #"""
        {
            "maxcount": 300,
            "emitter": [{
                "name": "sphererandom", "rate": 100000,
                "distancemin": 0, "distancemax": 100,
                "directions": "0 0 1", "sign": "0 0 1"
            }]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0x00A5_11CE))
        system.tick(now: 0)
        system.tick(now: 0.01)
        try #require(system.liveInstanceCount >= 100)

        var total = 0.0
        var count = 0
        for rawLine in system.particleStateDumpText().split(separator: "\n") {
            let line = String(rawLine)
            guard let open = line.range(of: "pos=("),
                  let close = line.range(of: ")", range: open.upperBound..<line.endIndex)
            else { continue }
            let parts = line[open.upperBound..<close.lowerBound].split(separator: ",")
            guard parts.count == 3, let z = Double(parts[2]) else { continue }
            #expect(z >= -0.01 && z <= 100.01)
            total += z
            count += 1
        }
        try #require(count >= 100)
        let average = total / Double(count)
        #expect(average > 60, "volumetric sampling should skew well past the naive-uniform mean of 50 (got \(average))")
    }
    #endif

    @Test("alphachange interpolates over lifetime fractions")
    func alphaChangeInterpolatesOverLifetimeFractions() {
        let change = WPEParticleAlphaChange(startTime: 0, endTime: 0.8, startValue: 1, endValue: 0)
        #expect(abs(change.factor(lifetimeFraction: 0) - 1) < 0.0001)
        #expect(abs(change.factor(lifetimeFraction: 0.4) - 0.5) < 0.0001)
        #expect(abs(change.factor(lifetimeFraction: 0.8)) < 0.0001)
        #expect(abs(change.factor(lifetimeFraction: 1)) < 0.0001)
    }

    @Test("oscillatealpha clamps factor to [0,1]")
    func oscillateAlphaClampsFactor() {
        let oscillate = WPEParticleOscillateAlpha(
            frequencyMin: 1, frequencyMax: 1, scaleMin: 0, scaleMax: 2, phaseMin: 0, phaseMax: 0
        )
        for age in stride(from: 0.0, through: 1.0, by: 0.05) {
            let factor = oscillate.factor(age: age, frequency: 1, phase: 0)
            #expect(factor >= 0)
            #expect(factor <= 1)
        }
    }

    @Test("oscillatealpha honours a bare frequencymax and sweeps scalemin…scalemax")
    func oscillateAlphaBareFrequencyMaxTwinkles() throws {
        let json = #"""
        {
            "maxcount": 10,
            "material": "materials/m.json",
            "initializer": [{"name": "lifetimerandom", "min": 4, "max": 8}],
            "operator": [{"name": "oscillatealpha", "frequencymax": 3, "scalemin": 0.2}]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let osc = try #require(def.oscillateAlpha)
        #expect(osc.frequencyMin == 0)
        #expect(osc.frequencyMax == 3)
        #expect(osc.scaleMin == 0.2)
        #expect(osc.scaleMax == 1)

        #expect(abs(osc.factor(age: 0, frequency: 3, phase: 0) - 1.0) < 0.0001)
        #expect(abs(osc.factor(age: .pi / 3, frequency: 3, phase: 0) - 0.2) < 0.0001)
    }

    @Test("Angular velocity advances rotationZ over time")
    func angularVelocityAdvancesRotation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 4, sizeMax: 4,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            angularVelocityMin: SIMD3(0, 0, 1.5),
            angularVelocityMax: SIMD3(0, 0, 1.5)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        for step in 1...10 {
            system.tick(now: Double(step) * 0.05)
        }
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)
        #expect(abs(pointer[0].rotationAndLife.x - 0.675) < 0.1)
    }

    @Test("A seeded RNG makes particle spawn jitter reproducible run-to-run (oracle determinism)")
    func seededParticleRNGIsDeterministic() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeDef() -> WPEParticleDefinition {
            WPEParticleDefinition(
                materialRelativePath: nil, maxCount: 64,
                rate: 2000, startDelay: 0,
                lifetimeMin: 2, lifetimeMax: 8,
                sizeMin: 2, sizeMax: 12,
                originOffset: SIMD3(0, 0, 0),
                dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(200, 200, 200),
                velocityMin: SIMD3(-50, -50, 0), velocityMax: SIMD3(50, 50, 0),
                colorMin: SIMD3(0, 0, 0), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0.01
            )
        }
        func liveSnapshot(seed: UInt64?) throws -> Data {
            let system = try #require(WPEParticleSystem(definition: makeDef(), device: device, seed: seed))
            system.tick(now: 0)
            for step in 1...20 { system.tick(now: Double(step) * 0.05) }
            let liveBytes = system.liveInstanceCount * MemoryLayout<WPEParticleInstance>.stride
            #expect(liveBytes > 0)
            return Data(bytes: system.instanceBuffer.contents(), count: liveBytes)
        }
        let a = try liveSnapshot(seed: 0x00AB_CDEF)
        let b = try liveSnapshot(seed: 0x00AB_CDEF)
        let c = try liveSnapshot(seed: 0x0012_3456)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("deterministicSeed is stable per input and unique across scene/object/order")
    func deterministicSeedIsStableAndUnique() {
        let base = WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "42", sortIndex: 3)
        #expect(base == WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "42", sortIndex: 3))
        #expect(base != WPEParticleSystem.deterministicSeed(workshopID: "123457", objectID: "42", sortIndex: 3))
        #expect(base != WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "43", sortIndex: 3))
        #expect(base != WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "42", sortIndex: 4))
        #expect(WPEParticleSystem.deterministicSeed(workshopID: "12", objectID: "3456", sortIndex: 0)
            != WPEParticleSystem.deterministicSeed(workshopID: "123", objectID: "456", sortIndex: 0))
    }

    @Test("Gravity integrates over time, pulling a particle along the gravity vector")
    func gravityIntegrates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            gravity: SIMD3(0, -10, 0)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let initialY = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.y
        system.tick(now: 0.15)
        let laterY = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.y
        #expect(laterY < initialY)
    }

    @Test("alpharandom selects per-particle base alpha")
    func alphaRandomScalesAlpha() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 8,
            rate: 1000, startDelay: 0,
            lifetimeMin: 5, lifetimeMax: 5,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            alphaMin: 0.15, alphaMax: 0.15
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 8)
        #expect(system.liveInstanceCount > 0)
        for index in 0..<system.liveInstanceCount {
            #expect(abs(pointer[index].color.w - 0.15) < 0.01)
        }
    }

    @Test("fadeOut envelope drops alpha near end of lifetime")
    func fadeOutDropsAlphaAtTail() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.0,
            fadeOutSeconds: 0.5
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        for step in 1...4 {
            system.tick(now: Double(step) * 0.05)
        }
        let early = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
        for step in 5...17 {
            system.tick(now: Double(step) * 0.05)
        }
        let late = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
        #expect(early > 0.9)
        #expect(late < early)
    }

    @Test("alphachange operator reduces written particle alpha over lifetime")
    func alphaChangeReducesWrittenAlphaOverLifetime() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            alphaChange: WPEParticleAlphaChange(startTime: 0, endTime: 0.8, startValue: 1, endValue: 0)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))

        system.tick(now: 0)
        system.tick(now: 0.05)
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        let early = pointer[0].color.w

        for step in 1...4 {
            system.tick(now: 0.05 + Double(step) * 0.1)
        }
        let middle = pointer[0].color.w

        for step in 5...8 {
            system.tick(now: 0.05 + Double(step) * 0.1)
        }
        let late = pointer[0].color.w

        #expect(early > 0.9)
        #expect(middle < early)
        #expect(late < 0.05)
    }

    @Test("Parser captures turbulence parameters")
    func parserCapturesTurbulence() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "initializer": [
                {"name": "turbulentvelocityrandom",
                 "speedmin": 35, "speedmax": 100,
                 "scale": 0.5, "offset": 3,
                 "timescale": 0.02,
                 "phasemin": 0, "phasemax": 6.28}
            ],
            "operator": []
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let tvi = try #require(def.turbulentVelocityInit)
        #expect(tvi.speedMin == 35)
        #expect(tvi.speedMax == 100)
        #expect(tvi.scale == 0.5)
        #expect(tvi.offset == 3)
        #expect(tvi.timescale == 0.02)
        #expect(tvi.phaseMax > 6.2)
        #expect(def.turbulence == nil)
    }

    @Test("Parser fills engine defaults for a sparse turbulent-velocity initializer")
    func parserTurbulentVelocityDefaults() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "initializer": [{"name": "turbulentvelocityrandom", "scale": 0.3}]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let tvi = try #require(def.turbulentVelocityInit)
        #expect(tvi.scale == 0.3)
        #expect(tvi.speedMin == 100)
        #expect(tvi.speedMax == 250)
        #expect(tvi.timescale == 1)
        #expect(tvi.forward == SIMD3<Double>(0, 1, 0))
    }

    @Test("Parser captures turbulence operator parameters")
    func parserCapturesTurbulenceOperator() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "operator": [
                {"name": "turbulence", "speedmin": 750, "speedmax": 900, "mask": "0.5 4 0"}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))

        let turb = try #require(def.turbulence)
        #expect(turb.speedMin == 750)
        #expect(turb.speedMax == 900)
        #expect(turb.mask.x == 0.5)
        #expect(turb.mask.y == 4)
        #expect(turb.mask.z == 0)
        #expect(def.turbulentVelocityInit == nil)
    }

    @Test("Initializer and operator turbulence parse independently without clobbering")
    func parserTurbulenceInitAndOperatorIndependent() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "initializer": [{"name": "turbulentvelocityrandom", "offset": -0.5, "scale": 0.1}],
            "operator": [
                {"name": "movement"},
                {"name": "turbulence", "speedmin": 250, "speedmax": 1000,
                 "timescale": 50, "mask": "1 0.4 0"}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let tvi = try #require(def.turbulentVelocityInit)
        let turb = try #require(def.turbulence)
        #expect(tvi.offset == -0.5)
        #expect(tvi.scale == 0.1)
        #expect(tvi.speedMin == 100)
        #expect(tvi.speedMax == 250)
        #expect(turb.speedMin == 250)
        #expect(turb.speedMax == 1000)
        #expect(turb.timescale == 50)
        #expect(turb.mask.y == 0.4)
    }

    @Test("Parser reads perspective flag (flags & 4)")
    func parserReadsPerspectiveFlag() throws {
        let perspective = try #require(WPEParticleDefinitionParser.parse(
            data: Data(#"{"maxcount": 4, "flags": 4, "emitter": [{"rate": 5}]}"#.utf8)))
        #expect(perspective.isPerspective)
        let flat = try #require(WPEParticleDefinitionParser.parse(
            data: Data(#"{"maxcount": 4, "flags": 0, "emitter": [{"rate": 5}]}"#.utf8)))
        #expect(!flat.isPerspective)
        let none = try #require(WPEParticleDefinitionParser.parse(
            data: Data(#"{"maxcount": 4, "emitter": [{"rate": 5}]}"#.utf8)))
        #expect(!none.isPerspective)
    }

    @Test("Perspective particles draw with depth-varied size")
    func perspectiveDepthVariesSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let json = #"""
        {
            "maxcount": 200, "flags": 4,
            "emitter": [{"name": "sphererandom", "rate": 100000, "distancemin": 10, "distancemax": 1000, "directions": "1 1 1"}],
            "initializer": [
                {"name": "lifetimerandom", "min": 100, "max": 100},
                {"name": "sizerandom", "min": 40, "max": 40}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.isPerspective)
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        for step in 1...6 { system.tick(now: Double(step) * 0.05) }
        let n = system.liveInstanceCount
        try #require(n >= 32)
        let buf = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 200)
        var minSize: Float = .greatestFiniteMagnitude
        var maxSize: Float = 0
        for i in 0..<n {
            let s = buf[i].positionAndSize.w
            minSize = Swift.min(minSize, s)
            maxSize = Swift.max(maxSize, s)
        }
        #expect(minSize <= 45, "far particles stay near the base size (min \(minSize))")
        #expect(maxSize > 60, "near particles are boosted bigger (max \(maxSize))")
        #expect(maxSize - minSize > 20, "depth should spread sizes (span \(maxSize - minSize))")
    }

    @Test("Perspective particles keep depth projection when Z comes from gravity")
    func perspectiveDepthAccountsForGravityTravel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 5, lifetimeMax: 5,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(100, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            directionMask: SIMD3(2, 2, 0),
            gravity: SIMD3(0, 0, 250),
            isPerspective: true
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let near = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize

        for step in 2...12 {
            system.tick(now: Double(step) * 0.05)
        }
        let mid = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize

        for step in 13...40 {
            system.tick(now: Double(step) * 0.05)
        }
        let late = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize

        #expect(mid.x > near.x + 1)
        #expect(mid.w > near.w + 0.1)
        #expect(late.x > mid.x + 5)
        #expect(late.w > mid.w + 0.5)
    }

    @Test("Turbulence produces non-zero position delta")
    func turbulenceProducesPositionDelta() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let calmDef = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let stormyDef = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            turbulence: WPEParticleTurbulenceOperator(
                speedMin: 50, speedMax: 50, scale: 0.1, timescale: 1,
                phaseMin: 1, phaseMax: 1, mask: SIMD3<Double>(1, 1, 0)
            )
        )
        let calmSystem = try #require(WPEParticleSystem(definition: calmDef, device: device))
        let stormySystem = try #require(WPEParticleSystem(definition: stormyDef, device: device))
        for step in 1...10 {
            calmSystem.tick(now: Double(step) * 0.05)
            stormySystem.tick(now: Double(step) * 0.05)
        }
        let calm = calmSystem.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
            .positionAndSize
        let stormy = stormySystem.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
            .positionAndSize
        let dx = stormy.x - calm.x
        let dy = stormy.y - calm.y
        #expect(sqrt(dx * dx + dy * dy) > 0.5)
    }

    @Test("Parser flags a turbulentvelocityrandom initializer")
    func parserFlagsTurbulentVelocityInit() throws {
        let seeded = try #require(WPEParticleDefinitionParser.parse(data: Data(#"""
        {
            "maxcount": 8, "emitter": [{"name": "boxrandom", "rate": 10}],
            "initializer": [{"name": "turbulentvelocityrandom", "offset": 0.5, "scale": 0.1}]
        }
        """#.utf8)))
        #expect(seeded.turbulentVelocityInit != nil)
        let plain = try #require(WPEParticleDefinitionParser.parse(data: Data(#"""
        {"maxcount": 8, "emitter": [{"name": "boxrandom", "rate": 10}]}
        """#.utf8)))
        #expect(plain.turbulentVelocityInit == nil)
    }

    @Test("turbulentvelocityrandom seeds a travelling velocity (embers leave the box)")
    func turbulentVelocityInitSeedsMotion() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeDef(seed: Bool) -> WPEParticleDefinition {
            WPEParticleDefinition(
                materialRelativePath: nil, maxCount: 32,
                rate: 10000, startDelay: 0,
                lifetimeMin: 10, lifetimeMax: 10,
                sizeMin: 1, sizeMax: 1,
                originOffset: SIMD3(0, 0, 0),
                dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
                velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
                colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0,
                turbulentVelocityInit: seed ? WPEParticleTurbulentVelocityInit() : nil
            )
        }
        func maxTravel(_ def: WPEParticleDefinition) throws -> Float {
            let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xEE1B_0A75))
            let buf = system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 32)
            system.tick(now: 0)
            system.tick(now: 0.1)
            let n = system.liveInstanceCount
            try #require(n >= 8)
            let spawned = (0..<n).map { SIMD2(buf[$0].positionAndSize.x, buf[$0].positionAndSize.y) }
            for step in 2...6 { system.tick(now: Double(step) * 0.1) }
            var travel: Float = 0
            for i in 0..<n {
                let p = SIMD2(buf[i].positionAndSize.x, buf[i].positionAndSize.y)
                travel = Swift.max(travel, simd_length(p - spawned[i]))
            }
            return travel
        }
        let stuck = try maxTravel(makeDef(seed: false))
        let travelled = try maxTravel(makeDef(seed: true))
        #expect(stuck < 0.01, "no seed → sparks never leave the spawn point (travel \(stuck))")
        #expect(travelled > 40, "seed → sparks travel away from spawn (travel \(travelled))")
    }

    @Test("turbulentvelocityrandom aims ONE system-wide gust, not a per-particle scatter")
    func turbulentVelocityInitIsOneGust() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let alignment = try Self.meanGustAlignment(device: device, timescale: 1)
        #expect(alignment > 0.7, "particles must share one gust direction (alignment \(alignment))")
    }

    @Test("turbulentvelocityrandom timescale sets how fast the gust turns")
    func turbulentVelocityInitTimescaleDrivesWalk() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fast = try Self.meanGustAlignment(device: device, timescale: 0.01)
        let slow = try Self.meanGustAlignment(device: device, timescale: 100)
        #expect(fast < 0.6, "a fast field must re-aim the gust between spawns (\(fast))")
        #expect(slow > 0.9, "a slow field must hold one gust (\(slow))")
    }

    private static func meanGustAlignment(device: MTLDevice, timescale: Double) throws -> Float {
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 32,
            rate: 100_000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            turbulentVelocityInit: WPEParticleTurbulentVelocityInit(
                speedMin: 100, speedMax: 250, scale: 2, timescale: timescale, offset: 0
            )
        )
        var total: Float = 0
        let seeds: [UInt64] = [0x6057_1234, 0x7A1E_5CA1, 0xBEEF_0001, 0x1EAF_FA11, 0xC0FF_EE42]
        for seed in seeds {
            let system = try #require(WPEParticleSystem(definition: def, device: device, seed: seed))
            let dirs = try seededSpawnDirections(system, capacity: 32)
            try #require(dirs.count >= 24)
            let mean = simd_normalize(dirs.reduce(SIMD2<Float>.zero, +) / Float(dirs.count))
            total += dirs.map { simd_dot($0, mean) }.reduce(0, +) / Float(dirs.count)
        }
        return total / Float(seeds.count)
    }

    private static func seededSpawnDirections(
        _ system: WPEParticleSystem, capacity: Int
    ) throws -> [SIMD2<Float>] {
        let buf = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: capacity)
        system.tick(now: 0)
        system.tick(now: 0.1)
        let n = system.liveInstanceCount
        let spawned = (0..<n).map { SIMD2(buf[$0].positionAndSize.x, buf[$0].positionAndSize.y) }
        system.tick(now: 0.2)
        return (0..<n).compactMap { i in
            let delta = SIMD2(buf[i].positionAndSize.x, buf[i].positionAndSize.y) - spawned[i]
            return simd_length(delta) > 1e-4 ? simd_normalize(delta) : nil
        }
    }

    @Test("turbulentvelocityrandom offset≈3 drives the stream DOWNWARD (leaves fall, not rise)")
    func turbulentVelocityOffsetFallsDown() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 200,
            rate: 20000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            turbulentVelocityInit: WPEParticleTurbulentVelocityInit(
                speedMin: 35, speedMax: 100, scale: 0.5, offset: 3
            )
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0x5EED_1EAF))
        func meanY() -> Float {
            let n = system.liveInstanceCount
            let buf = system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 200)
            var sum: Float = 0
            for i in 0..<n { sum += buf[i].positionAndSize.y }
            return sum / Float(n)
        }
        system.tick(now: 0)
        system.tick(now: 0.01)
        try #require(system.liveInstanceCount >= 32)
        let spawnY = meanY()
        system.tick(now: 0.11)
        let movedY = meanY()
        let displacement = movedY - spawnY
        #expect(
            displacement < -1,
            "offset=3 must seed a DOWNWARD stream; spawnY=\(spawnY) movedY=\(movedY) Δ=\(displacement)"
        )
    }

    @Test("An initializer-only system gets no per-frame turbulence sway (leaves drift straight)")
    func initializerOnlyHasNoOperatorSway() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, -80, 0), velocityMax: SIMD3(0, -80, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            turbulentVelocityInit: WPEParticleTurbulentVelocityInit(
                speedMin: 0, speedMax: 0, scale: 0
            )
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 1))
        func y0() -> Float {
            system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0].positionAndSize.y
        }
        system.tick(now: 0)
        system.tick(now: 0.1)
        system.tick(now: 0.2)
        let y1 = y0()
        system.tick(now: 0.3)
        let y2 = y0()
        system.tick(now: 0.4)
        let y3 = y0()
        #expect(y1 < 0, "particle should be falling, y1=\(y1)")
        #expect(
            abs((y3 - y2) - (y2 - y1)) < 0.001,
            "expected constant-velocity motion (equal increments), y1=\(y1) y2=\(y2) y3=\(y3)"
        )
    }

    @Test("Turbulence operator path is reproducible under a fixed seed")
    func turbulenceOperatorIsReproducibleUnderSeed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeDef() -> WPEParticleDefinition {
            WPEParticleDefinition(
                materialRelativePath: nil, maxCount: 64,
                rate: 3000, startDelay: 0,
                lifetimeMin: 4, lifetimeMax: 8,
                sizeMin: 2, sizeMax: 6,
                originOffset: SIMD3(0, 0, 0),
                dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(50, 50, 0),
                velocityMin: SIMD3(-20, -20, 0), velocityMax: SIMD3(20, 20, 0),
                colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0.01,
                drag: 1.5,
                turbulentVelocityInit: WPEParticleTurbulentVelocityInit(scale: 0.1, offset: -0.5),
                turbulence: WPEParticleTurbulenceOperator(
                    speedMin: 250, speedMax: 1000, scale: 0.002, timescale: 50,
                    phaseMin: 5, phaseMax: 50, mask: SIMD3<Double>(1, 0.4, 0)
                )
            )
        }
        func snapshot(seed: UInt64) throws -> Data {
            let system = try #require(WPEParticleSystem(definition: makeDef(), device: device, seed: seed))
            system.tick(now: 0)
            for step in 1...20 { system.tick(now: Double(step) * 0.05) }
            let bytes = system.liveInstanceCount * MemoryLayout<WPEParticleInstance>.stride
            #expect(bytes > 0)
            return Data(bytes: system.instanceBuffer.contents(), count: bytes)
        }
        #expect(try snapshot(seed: 0xCAFE_F00D) == snapshot(seed: 0xCAFE_F00D))
        #expect(try snapshot(seed: 0xCAFE_F00D) != snapshot(seed: 0x0BAD_BEEF))
    }

    @Test("alphafade timings are lifetime fractions, not seconds")
    func fadeTimingsAreLifetimeFractions() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1,
            fadeOutSeconds: 0.0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let mid = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
        #expect(mid < 0.15)
        for step in 2...22 {
            system.tick(now: Double(step) * 0.05)
        }
        let full = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
        #expect(full > 0.95)
    }

    @Test("Pre-warm advances simulation without prior tick")
    func prewarmAdvancesPopulation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 16,
            rate: 8, startDelay: 1,
            lifetimeMin: 5, lifetimeMax: 5,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.05
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.prewarm(simulatedSeconds: 3)
        system.tick(now: 0)
        #expect(system.liveInstanceCount >= 8)
    }

    @Test("Pre-warm reanchors simulation clock to runtime zero")
    func prewarmReanchorsSimulationClock() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(100, 0, 0), velocityMax: SIMD3(100, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.05
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.prewarm(simulatedSeconds: 2)
        system.tick(now: 0)
        let before = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.x

        system.tick(now: 0.1)
        let after = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.x

        #expect(after > before + 5)
    }

    @Test("Authored starttime forces WPE-matching prewarm without the manual prewarm flag")
    func authoredStarttimeForcesPrewarm() {
        let delayed = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 5_000,
            rate: 250, startDelay: 200,
            lifetimeMin: 5, lifetimeMax: 5,
            sizeMin: 3, sizeMax: 5,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(512, 512, 512),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1
        )
        let immediate = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 128,
            rate: 10, startDelay: 0,
            lifetimeMin: 2, lifetimeMax: 2,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )

        // `starttime` pre-simulates exactly itself — no steady-state padding on
        // top (this used to be 205 = 200 + a 5s tail, which matched neither WPE
        // nor a plain delay). 200 clamps to the 120s substep bound; every real
        // lifetime is far shorter, so the system is at steady state either way.
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: delayed,
            manualPrewarmEnabled: false
        ) == WPEMetalSceneRenderer.maxPrewarmSeconds)
        let shortDelay = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 128,
            rate: 10, startDelay: 3,
            lifetimeMin: 20, lifetimeMax: 20,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        // Under the clamp it is the authored value verbatim, NOT the old
        // `starttime + min(max(lifetimeMax, 2), 15)` = 18.
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: shortDelay,
            manualPrewarmEnabled: false
        ) == 3)
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: immediate,
            manualPrewarmEnabled: false
        ) == nil)
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: immediate,
            manualPrewarmEnabled: true
        ) == 2)

        // Oracle capture is a single frozen frame: dt is 0, so a `starttime: 0`
        // rate emitter spawns nothing and reports 0 alive while WPE reports
        // rate x elapsed. The replay instant overrides both gates — without it
        // the particle half of every fidelity diff compares against an empty pool.
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: immediate,
            manualPrewarmEnabled: false,
            oracleReplaySeconds: 6.845
        ) == 6.845, "a starttime:0 emitter must still prewarm under the oracle")
        // `starttime` PRE-SIMULATES rather than delaying (WPE docs: "as if it has
        // already been running for the configured time"), so at frame time T the
        // system has run for `starttime + T`. RenderDoc agrees: 3448877775's
        // snowperspective (starttime 15) holds 344 particles at T=4.851s where
        // dead-zoning the 15s predicts 121.
        let presimulated = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 360,
            rate: 25, startDelay: 15,
            lifetimeMin: 14, lifetimeMax: 14,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: presimulated,
            manualPrewarmEnabled: false,
            oracleReplaySeconds: 4.851
        ) == 15 + 4.851, "starttime adds to the replay instant, it does not gate it")
        // `delayed` authors starttime 200, which exceeds the loop bound and clamps.
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: delayed,
            manualPrewarmEnabled: false,
            oracleReplaySeconds: 6.845
        ) == WPEMetalSceneRenderer.maxPrewarmSeconds)
        // Clamped: prewarm substeps at 1/60s, so the replay time bounds the loop.
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: immediate,
            manualPrewarmEnabled: false,
            oracleReplaySeconds: 9_999
        ) == WPEMetalSceneRenderer.maxPrewarmSeconds)
        // Control: a system that emits neither way still prewarms to nothing.
        let inert = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 128,
            rate: 0, startDelay: 0,
            lifetimeMin: 2, lifetimeMax: 2,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: inert,
            manualPrewarmEnabled: false,
            oracleReplaySeconds: 6.845
        ) == nil)
    }

    // MARK: - Mouse interaction: control points (M3)

    @Test("Cursor-follow: control point 0 with flags:1 makes the emitter track the pointer")
    func parsesCursorFollowControlPoints() throws {
        let json = #"""
        {
            "maxcount": 1000, "material": "materials/particle/halo.json",
            "controlpoint": [ {"flags":1,"id":0,"offset":"0 0 0"}, {"flags":0,"id":1,"offset":"0 0 0"} ],
            "emitter": [{"id":6,"name":"boxrandom","rate":200}],
            "operator": [{"name":"movement","drag":0.4}]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.controlPoints.count == 2)
        #expect(def.controlPoints.first(where: { $0.id == 0 })?.pointerLocked == true)
        #expect(def.controlPoints.first(where: { $0.id == 1 })?.pointerLocked == false)
        #expect(def.emitterTracksPointer == true)
        #expect(def.attractors.isEmpty)
    }

    @Test("Cursor-avoid: controlpointattract on a pointer-locked control point")
    func parsesCursorAvoidAttractor() throws {
        let json = #"""
        {
            "maxcount": 1000, "material": "materials/particle/halo.json",
            "controlpoint": [ {"flags":0,"id":0,"offset":"0 0 0"}, {"flags":1,"id":1,"offset":"0 0 0"} ],
            "emitter": [{"id":6,"name":"boxrandom","rate":200}],
            "operator": [
                {"name":"movement","drag":2.5},
                {"name":"controlpointattract","controlpoint":1,"scale":-5000,"threshold":64}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.emitterTracksPointer == false)
        #expect(def.controlPoints.first(where: { $0.id == 1 })?.pointerLocked == true)
        let attractor = try #require(def.attractors.first)
        #expect(def.attractors.count == 1)
        #expect(attractor.controlPointID == 1)
        #expect(attractor.scale == -5000)
        #expect(attractor.threshold == 64)
    }

    @Test("controlpointattract repels particles away from a pointer-locked cursor (scene 3554161528 mechanism)")
    func cursorRepelPushesParticlesAway() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            controlPoints: [
                WPEParticleControlPoint(id: 0, offset: SIMD3(0, 0, 0), pointerLocked: false),
                WPEParticleControlPoint(id: 1, offset: SIMD3(0, 0, 0), pointerLocked: true)
            ],
            attractors: [
                WPEParticleControlPointAttractor(controlPointID: 1, scale: -1000, threshold: 200)
            ]
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.pointerCentered = SIMD2<Float>(20, 0)
        system.tick(now: 0)
        system.tick(now: 0.05)
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        let x0 = pointer[0].positionAndSize.x
        for step in 2...6 { system.tick(now: Double(step) * 0.05) }
        let x1 = pointer[0].positionAndSize.x
        #expect(x1 < x0)
        #expect(system.lastAttractorAffectedCount >= 1)
        #expect(system.cursorDebugSummary() != nil)
    }

    @Test("Pointer-locked emitter spawns particles at the cursor")
    func pointerLockedEmitterSpawnsAtCursor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.05,
            controlPoints: [WPEParticleControlPoint(id: 0, offset: SIMD3(0, 0, 0), pointerLocked: true)]
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000),
            objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, sceneTransform: transform))
        system.pointerCentered = SIMD2(200, 150)
        system.tick(now: 0)
        system.tick(now: 0.02)
        let inst = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
        #expect(abs(inst.positionAndSize.x - 200) < 1)
        #expect(abs(inst.positionAndSize.y - 150) < 1)
    }

    @Test("Event-follow control point injection wins over static resolution")
    func eventFollowControlPointInjectionWins() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(rate: 0, originOffset: SIMD3(300, 300, 0))
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            sceneTransform: centeredParticleTransform
        ))
        let injected = SIMD3<Float>(120, -35, 9)

        system.injectedControlPoints[system.followControlPointID] = injected

        #expect(system.controlPointPosition(system.followControlPointID) == injected)
    }

    @Test("Event-follow child spawns at injected parent particle position")
    func eventFollowChildSpawnsAtInjectedParentPosition() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(maxCount: 1, originOffset: SIMD3(300, 300, 0))
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            sceneTransform: centeredParticleTransform
        ))
        let injected = SIMD3<Float>(42, -84, 0)
        system.requiresFollowParent = true
        system.injectedControlPoints[system.followControlPointID] = injected

        system.tick(now: 0)
        system.tick(now: 0.02)

        #expect(system.liveInstanceCount == 1)
        let inst = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0]
        #expect(abs(inst.positionAndSize.x - injected.x) < 1)
        #expect(abs(inst.positionAndSize.y - injected.y) < 1)
    }

    @Test("Event-follow child does not spawn without a live parent injection")
    func eventFollowChildSkipsSpawnWithoutInjectedPosition() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let parent = try #require(WPEParticleSystem(
            definition: stillParticleDefinition(maxCount: 1),
            device: device,
            sceneTransform: centeredParticleTransform
        ))
        let child = try #require(WPEParticleSystem(
            definition: stillParticleDefinition(maxCount: 1),
            device: device,
            sceneTransform: centeredParticleTransform
        ))
        child.followParent = parent
        child.requiresFollowParent = true

        child.tick(now: 0)
        child.tick(now: 0.05)

        #expect(child.liveInstanceCount == 0)
    }

    @Test("Primary live particle position reports the youngest live particle")
    func primaryLiveParticlePositionReportsLiveParticle() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(maxCount: 1, originOffset: SIMD3(12, -8, 0))
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            sceneTransform: centeredParticleTransform
        ))

        #expect(system.primaryLiveParticlePosition == nil)
        system.tick(now: 0)
        system.tick(now: 0.02)

        let position = try #require(system.primaryLiveParticlePosition)
        #expect(abs(position.x - 12) < 1)
        #expect(abs(position.y + 8) < 1)
    }

    @Test("Parser captures sizechange, colorchange, oscillateposition operators")
    func parserCapturesModulationOperators() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "operator": [
                {"name": "sizechange", "starttime": 0, "endtime": 1, "startvalue": 0, "endvalue": 1},
                {"name": "colorchange", "startvalue": "1 1 1", "endvalue": "1 0 0"},
                {"name": "oscillateposition", "frequencymin": 0.8, "frequencymax": 1.0,
                 "scalemin": 20, "scalemax": 35, "phasemin": 0, "phasemax": 1, "mask": "1 0.5 0"}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let size = try #require(def.sizeChange)
        #expect(size.startValue == 0)
        #expect(size.endValue == 1)
        let color = try #require(def.colorChange)
        #expect(color.endColor.x == 1)
        #expect(color.endColor.y == 0)
        let osc = try #require(def.oscillatePosition)
        #expect(osc.frequencyMin == 0.8)
        #expect(osc.frequencyMax == 1.0)
        #expect(osc.scaleMin == 20)
        #expect(osc.scaleMax == 35)
        #expect(osc.mask.x == 1)
        #expect(osc.mask.y == 0.5)
    }

    @Test("oscillateposition defaults a missing frequencymax to five")
    func oscillatePositionDefaultsFrequencyMax() throws {
        let json = #"{"operator":[{"name":"oscillateposition","frequencymin":0.8,"scalemax":20}]}"#
        let definition = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let oscillation = try #require(definition.oscillatePosition)

        #expect(oscillation.frequencyMin == 0.8)
        #expect(oscillation.frequencyMax == 5)
    }

    @Test("sizechange factor ramps over lifetime")
    func sizeChangeFactorRamps() {
        let s = WPEParticleSizeChange(startTime: 0, endTime: 1, startValue: 0, endValue: 1)
        #expect(abs(s.factor(lifetimeFraction: 0)) < 0.0001)
        #expect(abs(s.factor(lifetimeFraction: 0.5) - 0.5) < 0.0001)
        #expect(abs(s.factor(lifetimeFraction: 1) - 1) < 0.0001)
    }

    @Test("colorchange interpolates each channel independently")
    func colorChangeInterpolatesChannels() {
        let c = WPEParticleColorChange(
            startTime: 0, endTime: 1,
            startColor: SIMD3(1, 1, 1), endColor: SIMD3(1, 0, 0)
        )
        let mid = c.color(lifetimeFraction: 0.5)
        #expect(abs(mid.x - 1) < 0.0001)
        #expect(abs(mid.y - 0.5) < 0.0001)
        #expect(abs(mid.z - 0.5) < 0.0001)
    }

    @Test("sizechange grows the written sprite size over lifetime")
    func sizeChangeGrowsWrittenSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            sizeChange: WPEParticleSizeChange(startTime: 0, endTime: 1, startValue: 0, endValue: 1)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        system.tick(now: 0)
        system.tick(now: 0.05)
        let early = pointer[0].positionAndSize.w
        for step in 1...8 { system.tick(now: 0.05 + Double(step) * 0.1) }
        let late = pointer[0].positionAndSize.w
        #expect(early < 2)
        #expect(late > 6)
        #expect(late > early)
    }

    @Test("colorchange multiplies the written tint over lifetime")
    func colorChangeMultipliesWrittenColor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            colorChange: WPEParticleColorChange(
                startTime: 0, endTime: 1,
                startColor: SIMD3(1, 1, 1), endColor: SIMD3(1, 0, 0)
            ),
            hasColorInitializer: true
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        system.tick(now: 0)
        system.tick(now: 0.05)
        let early = pointer[0].color
        for step in 1...8 { system.tick(now: 0.05 + Double(step) * 0.1) }
        let late = pointer[0].color
        #expect(early.y > 0.8)
        #expect(late.x > 0.8)
        #expect(late.y < late.x)
    }

    @Test("oscillateposition sways the written position with bounded amplitude (transient, no drift)")
    func oscillatePositionSwaysBounded() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            oscillatePosition: WPEParticleOscillatePosition(
                frequencyMin: 1, frequencyMax: 1,
                scaleMin: 50, scaleMax: 50,
                phaseMin: 0, phaseMax: 0,
                mask: SIMD3(1, 0, 0)
            )
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        system.tick(now: 0)
        for step in 1...160 {
            system.tick(now: Double(step) * 0.05)
            let x = pointer[0].positionAndSize.x
            minX = min(minX, x)
            maxX = max(maxX, x)
        }
        let amplitude = (maxX - minX) / 2
        #expect(amplitude > 40)
        #expect(amplitude < 60)
    }

    @Test("colorchange multiplier composes with 0...255 colorrandom normalization")
    func colorChangeComposesWithColorNormalization() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(128, 128, 128), colorMax: SIMD3(128, 128, 128),
            fadeInSeconds: 0,
            colorChange: WPEParticleColorChange(
                startTime: 0, endTime: 1,
                startColor: SIMD3(0.5, 0.5, 0.5), endColor: SIMD3(0.5, 0.5, 0.5)
            ),
            hasColorInitializer: true
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        system.tick(now: 0)
        system.tick(now: 0.05)
        let written = pointer[0].color
        #expect(abs(written.x - 0.251) < 0.02)
    }

    @Test("colorchange does NOT recolour a particle with no colour initializer (white r8 smoke stays white)")
    func colorChangeSkippedWithoutColorInitializer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            colorChange: WPEParticleColorChange(
                startTime: 0, endTime: 0.6,
                startColor: SIMD3(1, 0.749, 0), endColor: SIMD3(1, 0, 0)
            )
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        system.tick(now: 0)
        for step in 1...8 { system.tick(now: Double(step) * 0.1) }
        let c = pointer[0].color
        #expect(c.x > 0.9, "red stays ~white")
        #expect(c.y > 0.9, "green NOT ramped down — stays ~white")
        #expect(c.z > 0.9, "blue NOT zeroed — stays ~white")
    }

    @Test("colorn instance-override applies (dims) even without a colour initializer")
    func colornOverrideAppliesWithoutColorInitializer() throws {
        let base = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let override = WPESceneParticleInstanceOverride(color: SIMD3(61, 41, 69))
        let applied = base.applying(instanceOverride: override)
        #expect(applied.colorMin == SIMD3(61, 41, 69))
        #expect(applied.colorMax == SIMD3(61, 41, 69))
    }

    @Test("oscillateposition mask transforms into render space with object rotation")
    func oscillatePositionMaskRotatesWithObject() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            oscillatePosition: WPEParticleOscillatePosition(
                frequencyMin: 1, frequencyMax: 1,
                scaleMin: 50, scaleMax: 50,
                phaseMin: 0, phaseMax: 0,
                mask: SIMD3(1, 0, 0)
            )
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000),
            objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(1, 1, 1),
            objectAngleZ: Float.pi / 2
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, sceneTransform: transform))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        system.tick(now: 0)
        for step in 1...160 {
            system.tick(now: Double(step) * 0.05)
            let p = pointer[0].positionAndSize
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        #expect((maxX - minX) < 5)
        #expect((maxY - minY) > 80)
    }

    @Test("object scale enlarges sprite size (WPE T·R·S model)")
    func objectScaleEnlargesSpriteSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 50, sizeMax: 50,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000), objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(2, 2, 1), objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def, device: device, sceneTransform: transform))
        system.tick(now: 0); system.tick(now: 0.05)
        let w = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.w
        #expect(abs(w - 100) < 1)
    }

    @Test("additive sprite size is capped near scene height; translucent is not")
    func additiveSpriteSizeCapped() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeSized(blend: WPEParticleBlendMode) throws -> Float {
            let def = WPEParticleDefinition(
                materialRelativePath: nil, maxCount: 1,
                rate: 1000, startDelay: 0,
                lifetimeMin: 100, lifetimeMax: 100,
                sizeMin: 50, sizeMax: 50,
                originOffset: SIMD3(0, 0, 0),
                dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
                velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
                colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0
            )
            let transform = WPEParticleSceneTransform(
                sceneSize: SIMD2(1000, 1000), objectOrigin: SIMD3(500, 500, 0),
                objectScale: SIMD3(100, 100, 1), objectAngleZ: 0
            )
            let system = try #require(WPEParticleSystem(
                definition: def, device: device, blendMode: blend, sceneTransform: transform))
            system.tick(now: 0); system.tick(now: 0.05)
            return system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.w
        }
        #expect(abs(try makeSized(blend: .additive) - 1000) < 1)
        #expect(try makeSized(blend: .translucent) > 4000)
    }

    @Test("additive sprite cap also applies after sizechange growth")
    func additiveSpriteSizeCapAppliesAfterSizeChange() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 50, sizeMax: 50,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            sizeChange: WPEParticleSizeChange(startTime: 0, endTime: 1, startValue: 2, endValue: 2)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000), objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(100, 100, 1), objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def, device: device, blendMode: .additive, sceneTransform: transform))
        system.tick(now: 0); system.tick(now: 0.05)
        let w = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.w
        #expect(abs(w - 1000) < 1)
    }

    @Test("Parser captures sizerandom exponent; spawn biases size toward min")
    func sizeRandomExponentBiasesTowardMin() throws {
        let json = #"""
        {
            "maxcount": 200, "material": "materials/particle/leaves5_1.json",
            "emitter": [{"name": "sphererandom", "rate": 1000}],
            "initializer": [{"name": "sizerandom", "min": 40, "max": 80, "exponent": 2}]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.sizeExponent == 2)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        for step in 0...40 { system.tick(now: Double(step) * 0.05) }
        let n = system.liveInstanceCount
        let ptr = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: n)
        let mean = (0..<n).map { ptr[$0].positionAndSize.w }.reduce(0, +) / Float(max(1, n))
        #expect(n > 30)
        #expect(mean < 58)
        #expect(mean > 40)
    }

    @Test("Parser captures instantaneous burst from a verbatim WPE emitter (scene 3460973721)")
    func parserCapturesInstantaneousBurst() throws {
        let json = #"""
        {
            "maxcount": 200,
            "emitter": [{"directions": "1 0.5 0", "distancemax": 1024, "distancemin": 0,
                         "duration": 0, "id": 7, "instantaneous": 50, "name": "sphererandom",
                         "origin": "0 -0.5 0", "rate": 15, "speedmax": 5}],
            "operator": []
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.instantaneousCount == 50)
        #expect(def.rate == 15)
        // The editor stamps `duration: 0` onto every emitter; it is the unset
        // marker, not a zero-second window. Reading it literally silenced every
        // rate emitter in the corpus after one tick.
        #expect(def.duration == nil)
    }

    @Test("Parser preserves emitter flags and both authored audio key families; unknown audio keys stay diagnosed")
    func parserPreservesOpaqueEmitterFlagsAndAudioState() throws {
        let json: [String: Any] = [
            "maxcount": 20,
            "emitter": [[
                "name": "sphererandom",
                "rate": 100,
                "duration": 1.25,
                "flags": 5,
                "audioprocessingmode": 3,
                "audioprocessingfrequencystart": 2,
                "audioprocessingfrequencyend": 12,
                "audioprocessingbounds": "0.1 0.8",
                "audioprocessingexponent": 1.5,
                "audioamount": 2.25,
                "audiofuturefield": ["shape": "unconfirmed", "values": [1, true]]
            ]]
        ]
        var diagnostics: [WPESceneDiagnostic] = []
        let def = WPEParticleDefinitionParser.parse(dictionary: json, diagnostics: &diagnostics)

        #expect(def.duration == 1.25)
        #expect(def.emitterFlagsRaw == 5)
        #expect(def.emitterAudioState?.mode == 3)
        #expect(def.emitterAudioState?.frequencyStart == 2)
        #expect(def.emitterAudioState?.frequencyEnd == 12)
        #expect(def.emitterAudioState?.bounds == [0.1, 0.8])
        #expect(def.emitterAudioState?.exponent == 1.5)
        #expect(def.emitterAudioState?.amount == 2.25)
        #expect(def.emitterAudioState?.rawFields["audioprocessingbounds"] == .string("0.1 0.8"))
        #expect(def.emitterAudioState?.rawFields["audiofuturefield"] == .object([
            "shape": .string("unconfirmed"),
            "values": .array([.number(1), .bool(true)])
        ]))
        #expect(diagnostics.contains { $0.message.contains("flags 5") && $0.message.contains("without runtime interpretation") })
        #expect(diagnostics.contains { $0.message.contains("audio fields") && $0.message.contains("without a runtime consumer") })

        let copied = def.applying(instanceOverride: WPESceneParticleInstanceOverride(count: 1))
            .offsettingOrigin(by: SIMD3(1, 2, 3))
        #expect(copied.duration == def.duration)
        #expect(copied.emitterFlagsRaw == def.emitterFlagsRaw)
        #expect(copied.emitterAudioState == def.emitterAudioState)

        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xA03))
        system.tick(now: 0)
        system.tick(now: 0.1)
        #expect(system.liveInstanceCount == 10,
                "opaque emitter flags must not silently become a one-per-frame limit")
    }

    @Test("An audio-responsive emitter scales its emission rate by the injected spectrum")
    func audioResponsiveEmitterScalesEmissionRate() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(
            maxCount: 100,
            rate: 10,
            lifetime: 100,
            emitterAudioState: WPEParticleEmitterAudioState(mode: 1, amount: 3)
        )

        let silent = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xA03))
        silent.tick(now: 0)
        for step in 1...10 { silent.tick(now: Double(step) / 10) }
        #expect(silent.liveInstanceCount == 10, "no spectrum ⇒ baseline rate")

        let loud = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xA03))
        loud.audioSpectrum16 = [Float](repeating: 1, count: 16)
        loud.tick(now: 0)
        for step in 1...10 { loud.tick(now: Double(step) / 10) }
        // Full-scale spectrum: level 1 → rate × (1 + 1·3) = 40 births/second.
        #expect(loud.liveInstanceCount == 40)
    }

    @Test("A muted audio emitter (mode 0) ignores the spectrum")
    func mutedAudioEmitterIgnoresSpectrum() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(
            maxCount: 100,
            rate: 10,
            lifetime: 100,
            emitterAudioState: WPEParticleEmitterAudioState(mode: 0, amount: 3)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xA03))
        system.audioSpectrum16 = [Float](repeating: 1, count: 16)
        system.tick(now: 0)
        for step in 1...10 { system.tick(now: Double(step) / 10) }
        #expect(system.liveInstanceCount == 10)
    }

    @Test("Emission scale follows the reference defaults, bounds, exponent and clamps")
    func emitterAudioEmissionScaleSemantics() {
        let half = [Float](repeating: 0.5, count: 16)
        // Disabled or empty inputs are the neutral scale.
        #expect(WPEParticleEmitterAudioState(mode: 0).emissionScale(spectrum16: half) == 1)
        #expect(WPEParticleEmitterAudioState(mode: 1).emissionScale(spectrum16: []) == 1)
        // Defaults (freq 0…15, bounds 0…1, exponent 1, amount 1): 1 + level.
        #expect(WPEParticleEmitterAudioState(mode: 1).emissionScale(spectrum16: half) == 1.5)
        // The authored band range picks its slice; reversed endpoints swap.
        var spectrum = [Float](repeating: 0, count: 16)
        spectrum[2] = 1
        let banded = WPEParticleEmitterAudioState(mode: 1, frequencyStart: 2, frequencyEnd: 2, amount: 2)
        #expect(banded.emissionScale(spectrum16: spectrum) == 3)
        let reversed = WPEParticleEmitterAudioState(mode: 1, frequencyStart: 2, frequencyEnd: 0, amount: 2)
        #expect(abs(reversed.emissionScale(spectrum16: spectrum) - (1 + 2.0 / 3)) < 1e-9)
        // Out-of-range endpoints clamp into the 16-band array instead of trapping.
        let clamped = WPEParticleEmitterAudioState(mode: 1, frequencyStart: -5, frequencyEnd: 99)
        #expect(clamped.emissionScale(spectrum16: half) == 1.5)
        // Bounds renormalize linearly (not the material path's smoothstep):
        // level 0.5 against 0…0.5 saturates to 1.
        let bounded = WPEParticleEmitterAudioState(mode: 1, bounds: [0, 0.5])
        #expect(bounded.emissionScale(spectrum16: half) == 2)
        // Exponent shapes the normalized level; amount may push the scale to 0 but never below.
        let squared = WPEParticleEmitterAudioState(mode: 1, exponent: 2)
        #expect(squared.emissionScale(spectrum16: half) == 1.25)
        let damped = WPEParticleEmitterAudioState(mode: 1, amount: -3)
        #expect(damped.emissionScale(spectrum16: [Float](repeating: 1, count: 16)) == 0)
    }

    @Test("Frame spectrum pools 64→16 by averaging channels before max-pooling")
    func audioSpectrum16AverageChannelOrderMatters() {
        var left = [Double](repeating: 0, count: 64)
        var right = [Double](repeating: 0, count: 64)
        left[0] = 1.0
        right[1] = 0.5
        let uniforms = WPEMetalRuntimeUniforms(
            time: 0, daytime: 0, brightness: 1,
            pointerPosition: SIMD2(0.5, 0.5),
            audioSpectrumLeft: left, audioSpectrumRight: right
        )
        let pooled = uniforms.audioSpectrum16Average
        #expect(pooled.count == 16)
        // Average first: mono (0.5, 0.25, 0, 0) → max 0.5. Pooling each channel
        // before averaging would give (1 + 0.5) / 2 = 0.75 — the wrong order.
        #expect(pooled[0] == 0.5)
        #expect(pooled[1...].allSatisfy { $0 == 0 })
    }

    @Test("Known audio emitter keys are consumed — no unconsumed-fields diagnostic")
    func knownAudioEmitterKeysAreConsumed() {
        let json: [String: Any] = [
            "maxcount": 5,
            "emitter": [[
                "rate": 10,
                "audioprocessingmode": 1,
                "audioprocessingfrequencystart": 0,
                "audioprocessingfrequencyend": 15,
                "audiobounds": "0 1",
                "audioexponent": 1,
                "audioamount": 2
            ]]
        ]
        var diagnostics: [WPESceneDiagnostic] = []
        let def = WPEParticleDefinitionParser.parse(dictionary: json, diagnostics: &diagnostics)
        #expect(def.emitterAudioState?.isEnabled == true)
        #expect(!diagnostics.contains { $0.message.contains("without a runtime consumer") })
    }

    @Test("Emitter duration stops births while existing particles keep aging to expiry")
    func emitterDurationStopsBirthsButDoesNotKillLiveParticles() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(
            maxCount: 100,
            rate: 10,
            duration: 0.3,
            lifetime: 0.5
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xA03))

        system.tick(now: 0)
        for step in 1...3 { system.tick(now: Double(step) / 10) }
        let countAtDeadline = system.liveInstanceCount
        #expect(countAtDeadline == 3)

        system.tick(now: 0.4)
        #expect(system.liveInstanceCount == countAtDeadline, "duration expiry must stop new births, not clear the pool")
        for step in 5...10 { system.tick(now: Double(step) / 10) }
        #expect(system.liveInstanceCount == 0, "particles born before the deadline still age out normally")
    }

    @Test("Nil duration keeps unbounded rate emission behavior")
    func nilEmitterDurationPreservesUnboundedEmission() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(maxCount: 100, rate: 10, duration: nil, lifetime: 100)
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xA03))
        system.tick(now: 0)
        for step in 1...10 { system.tick(now: Double(step) / 10) }
        #expect(system.liveInstanceCount == 10)
        for step in 11...20 { system.tick(now: Double(step) / 10) }
        #expect(system.liveInstanceCount == 20)
    }

    // A-03 changed more than `duration`: the emission gate now anchors at zero
    // once `starttime` has been consumed as authored history. Without this the
    // delay was charged twice — once inside prewarm, once again live — and a
    // prewarm window shorter than `starttime` left the emitter silent. Pinned
    // here because it fires with `duration == nil`, outside A-03's headline.
    @Test("A presimulated start delay is authored history, not a second live delay")
    func nilDurationEmitsImmediatelyWhenStartDelayWasPresimulated() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(
            maxCount: 100,
            rate: 10,
            startDelay: 10,
            duration: nil,
            lifetime: 100
        )

        // Prewarm window (2 s) is deliberately shorter than starttime (10 s).
        let presimulated = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xA03))
        presimulated.prewarm(simulatedSeconds: 2, presimulateDelay: true)
        presimulated.tick(now: 0)
        let afterPrewarm = presimulated.liveInstanceCount
        #expect(afterPrewarm > 0, "presimulating the delay must produce authored history")
        for step in 1...10 { presimulated.tick(now: Double(step) / 10) }
        #expect(
            presimulated.liveInstanceCount == afterPrewarm + 10,
            "starttime already spent as history must not gate the first live second"
        )

        // Control: the same starttime with no presimulation is still a real delay.
        let gated = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xA03))
        gated.tick(now: 0)
        for step in 1...10 { gated.tick(now: Double(step) / 10) }
        #expect(gated.liveInstanceCount == 0, "an un-presimulated starttime still delays emission")
    }

    @Test("Duration window begins after a non-presimulated start delay")
    func durationIsRelativeToStartDelay() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(
            maxCount: 100,
            rate: 10,
            startDelay: 0.3,
            duration: 0.2,
            lifetime: 100
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xA03))
        system.tick(now: 0)
        system.tick(now: 0.1)
        system.tick(now: 0.2)
        #expect(system.liveInstanceCount == 0)
        system.tick(now: 0.3)
        system.tick(now: 0.4)
        system.tick(now: 0.5)
        let countAtDeadline = system.liveInstanceCount
        #expect(countAtDeadline > 0)
        system.tick(now: 0.6)
        #expect(system.liveInstanceCount == countAtDeadline)
    }

    @Test("Duration applies during presimulation and a saturated pool is not refilled after expiry")
    func durationCoversPrewarmAndPoolSaturation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let prewarmDef = stillParticleDefinition(
            maxCount: 100,
            rate: 10,
            duration: 0.5,
            lifetime: 100
        )
        let prewarmed = try #require(WPEParticleSystem(definition: prewarmDef, device: device, seed: 0xA03))
        prewarmed.prewarm(simulatedSeconds: 2, presimulateDelay: true)
        prewarmed.tick(now: 0)
        let prewarmedCount = prewarmed.liveInstanceCount
        #expect(prewarmedCount == 5)
        prewarmed.tick(now: 0.1)
        #expect(prewarmed.liveInstanceCount == prewarmedCount)

        let authoredHistoryDef = stillParticleDefinition(
            maxCount: 100,
            rate: 10,
            startDelay: 0.4,
            duration: 0.2,
            lifetime: 100
        )
        let authoredHistory = try #require(WPEParticleSystem(
            definition: authoredHistoryDef,
            device: device,
            seed: 0xA03
        ))
        authoredHistory.prewarm(simulatedSeconds: 0.4, presimulateDelay: true)
        authoredHistory.tick(now: 0)
        let historyCount = authoredHistory.liveInstanceCount
        #expect(historyCount == 2)
        authoredHistory.tick(now: 0.1)
        #expect(authoredHistory.liveInstanceCount == historyCount,
                "starttime history must not restart duration at the first live frame")

        // Authored `duration: 0` must survive the parser as "unbounded" and keep
        // emitting. This is the shape every corpus emitter actually has
        // (bird_child.json: `"duration": 0, "rate": 1`), so it is checked
        // end-to-end through the parser rather than by constructing a definition.
        let authoredZeroJSON = #"""
        {
            "maxcount": 100,
            "emitter": [{"name": "sphererandom", "rate": 10, "duration": 0}],
            "initializer": [{"id": 2, "name": "lifetimerandom", "min": 100, "max": 100}],
            "operator": []
        }
        """#
        let authoredZeroDef = try #require(
            WPEParticleDefinitionParser.parse(data: Data(authoredZeroJSON.utf8))
        )
        #expect(authoredZeroDef.duration == nil, "duration:0 is the editor default, i.e. unbounded")
        let authoredZero = try #require(WPEParticleSystem(
            definition: authoredZeroDef,
            device: device,
            seed: 0xA03
        ))
        authoredZero.tick(now: 0)
        for step in 1...20 { authoredZero.tick(now: Double(step) / 10) }
        #expect(authoredZero.liveInstanceCount == 20, "an authored duration:0 emitter must keep emitting")

        let saturatedDef = stillParticleDefinition(
            maxCount: 1,
            rate: 10,
            duration: 0.3,
            lifetime: 0.15
        )
        let saturated = try #require(WPEParticleSystem(definition: saturatedDef, device: device, seed: 0xA03))
        saturated.tick(now: 0)
        saturated.tick(now: 0.1)
        saturated.tick(now: 0.2)
        saturated.tick(now: 0.3)
        #expect(saturated.liveInstanceCount == 1)
        saturated.tick(now: 0.4)
        saturated.tick(now: 0.5)
        #expect(saturated.liveInstanceCount == 0, "a free slot after duration must not restart emission")
    }

    @Test("instantaneous burst spawns exactly N particles once, even with rate 0")
    func instantaneousBurstSpawnsOnceWithZeroRate() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 100,
            rate: 0, instantaneousCount: 5, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 5)
        for step in 1...20 { system.tick(now: Double(step) * 0.1) }
        #expect(system.liveInstanceCount == 5)
    }

    @Test("instantaneous burst seeds population immediately alongside continuous rate")
    func instantaneousBurstSeedsWithContinuousRate() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 200,
            rate: 10, instantaneousCount: 30, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 30)
    }

    @Test("event-follow burst waits for a parent birth, then fires at its position")
    func eventFollowInstantaneousBurstWaitsForParentBirth() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 10,
            rate: 0, instantaneousCount: 4, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let parentPosition = SIMD3<Double>(25, -10, 0)
        let parentDef = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 20, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: parentPosition,
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let parent = try #require(WPEParticleSystem(definition: parentDef, device: device))
        let child = try #require(WPEParticleSystem(definition: def, device: device))
        child.followParent = parent
        child.requiresFollowParent = true

        parent.tick(now: 0)
        child.tick(now: 0)
        #expect(child.liveInstanceCount == 0, "nothing has been born to follow yet")

        parent.tick(now: 0.05)
        child.tick(now: 0.05)
        #expect(child.liveInstanceCount == 4)
        let first = child.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
        #expect(abs(first.positionAndSize.x - Float(parentPosition.x)) < 1)
        #expect(abs(first.positionAndSize.y - Float(parentPosition.y)) < 1)
    }

    @Test("instantaneous burst is capped by maxCount")
    func instantaneousBurstCappedByMaxCount() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 3,
            rate: 0, instantaneousCount: 10, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 3)
    }

    @Test("instance override count scales the instantaneous burst")
    func instanceOverrideScalesInstantaneousBurst() {
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 100,
            rate: 0, instantaneousCount: 10, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let scaled = def.applying(instanceOverride: WPESceneParticleInstanceOverride(count: 2))
        #expect(scaled.instantaneousCount == 20)
    }

    @Test("material overbright parse: numeric, absent default, bool guard, negative clamp")
    func materialOverbrightParse() {
        #expect(abs(WPEMetalSceneRenderer.overbright(
            fromConstants: ["ui_editor_properties_overbright": 1.51]) - 1.51) < 0.0001)
        #expect(WPEMetalSceneRenderer.overbright(fromConstants: [:]) == 1.0)
        #expect(WPEMetalSceneRenderer.overbright(fromConstants: nil) == 1.0)
        #expect(WPEMetalSceneRenderer.overbright(
            fromConstants: ["ui_editor_properties_overbright": false]) == 1.0)
        #expect(WPEMetalSceneRenderer.overbright(
            fromConstants: ["ui_editor_properties_overbright": -3]) == 0)
    }

    @Test("object brightness multiplies material overbright into the particle uniform")
    func objectBrightnessMultipliesOverbright() {
        #expect(abs(WPEMetalSceneRenderer.particleOverbright(
            material: nil, objectBrightness: 2.0) - 2.0) < 0.0001)
        #expect(abs(WPEMetalSceneRenderer.particleOverbright(
            material: 1.5, objectBrightness: 2.0) - 3.0) < 0.0001)
        #expect(WPEMetalSceneRenderer.particleOverbright(
            material: nil, objectBrightness: 1.0) == 1.0)
        #expect(WPEMetalSceneRenderer.particleOverbright(
            material: 1.0, objectBrightness: -2.0) == 0)
    }

    private func stillParticleDefinition(
        maxCount: Int = 4,
        rate: Double = 1000,
        startDelay: Double = 0,
        duration: Double? = nil,
        lifetime: Double = 10,
        originOffset: SIMD3<Double> = SIMD3(0, 0, 0),
        emitterAudioState: WPEParticleEmitterAudioState? = nil
    ) -> WPEParticleDefinition {
        WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: maxCount,
            rate: rate,
            startDelay: startDelay,
            duration: duration,
            emitterAudioState: emitterAudioState,
            lifetimeMin: lifetime,
            lifetimeMax: lifetime,
            sizeMin: 1,
            sizeMax: 1,
            originOffset: originOffset,
            dispersalMin: SIMD3<Double>(0, 0, 0),
            dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0),
            velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255),
            colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
    }

    private var centeredParticleTransform: WPEParticleSceneTransform {
        WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000),
            objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(1, 1, 1),
            objectAngleZ: 0
        )
    }

    // MARK: - Rope renderer (scene 3351072238)

    @Test("Parser flags renderer:[{name:rope}] as a rope; sprite/empty stay false")
    func parserDetectsRopeRenderer() throws {
        func def(_ renderer: String) -> WPEParticleDefinition? {
            let json = """
            {"maxcount": 8, "renderer": \(renderer),
             "emitter":[{"name":"sphererandom","rate":32}],
             "material":"materials/presets/trail_1.json"}
            """
            return WPEParticleDefinitionParser.parse(data: Data(json.utf8))
        }
        #expect(try #require(def("[{\"name\":\"rope\"}]")).isRope == true)
        #expect(try #require(def("[{\"name\":\"sprite\"}]")).isRope == false)
        #expect(try #require(def("[]")).isRope == false)
    }

    @Test("Rope builds a 2-vertex-per-knot ribbon with finite width")
    func ropeBuildsRibbonStrip() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            isRope: true,
            maxCount: 32,
            rate: 64,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 200, 0), velocityMax: SIMD3(0, 200, 0),
            colorMin: SIMD3(85, 153, 255), colorMax: SIMD3(85, 153, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        #expect(system.isRope)
        #expect(system.ropeVertexBuffer != nil)
        system.tick(now: 0)
        for step in 1...20 { system.tick(now: Double(step) * 0.05) }

        let alive = system.liveInstanceCount
        #expect(alive >= 2)
        #expect(system.ropeVertexCount == alive * 2)

        let verts = try #require(system.ropeVertexBuffer).contents()
            .bindMemory(to: WPEParticleRopeVertex.self, capacity: system.ropeVertexCount)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for i in 0..<system.ropeVertexCount {
            minX = min(minX, verts[i].positionUV.x); maxX = max(maxX, verts[i].positionUV.x)
            minY = min(minY, verts[i].positionUV.y); maxY = max(maxY, verts[i].positionUV.y)
        }
        #expect(abs((maxX - minX) - 10) < 0.5)
        #expect((maxY - minY) > 50)
        #expect(abs(verts[0].positionUV.w - 0) < 0.001)
        #expect(abs(verts[system.ropeVertexCount - 1].positionUV.w - 1) < 0.001)
        #expect(verts[0].color.x < 0.5 && verts[0].color.z > 0.9)
    }

    @Test("Rope frame slots do not overwrite in-flight ribbon vertices")
    func ropeFrameSlotsKeepIndependentVertexBuffers() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            isRope: true,
            maxCount: 32,
            rate: 64,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 200, 0), velocityMax: SIMD3(0, 200, 0),
            colorMin: SIMD3(85, 153, 255), colorMax: SIMD3(85, 153, 255),
            fadeInSeconds: 0
        )
        let system = try #require(
            WPEParticleSystem(definition: def, device: device, seed: 0xF12A_0002)
        )

        system.tick(now: 0, frameSlot: 0)
        for step in 1...10 {
            system.tick(now: Double(step) * 0.05, frameSlot: 0)
        }
        let slotZero = try #require(system.ropeVertexBuffer)
        let slotZeroBytes = Data(bytes: slotZero.contents(), count: slotZero.length)

        system.tick(now: 0.55, frameSlot: 1)

        let slotOne = try #require(system.ropeVertexBuffer)
        #expect(slotOne !== slotZero)
        #expect(Data(bytes: slotZero.contents(), count: slotZero.length) == slotZeroBytes)
    }

    @Test("Stationary rope collapses to zero-area strip (no white blob)")
    func ropeStationaryDrawsNoArea() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            isRope: true,
            maxCount: 32,
            rate: 64,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(85, 153, 255), colorMax: SIMD3(85, 153, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        for step in 1...10 { system.tick(now: Double(step) * 0.05) }
        guard system.ropeVertexCount >= 4 else { return }

        let verts = try #require(system.ropeVertexBuffer).contents()
            .bindMemory(to: WPEParticleRopeVertex.self, capacity: system.ropeVertexCount)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for i in 0..<system.ropeVertexCount {
            minX = min(minX, verts[i].positionUV.x); maxX = max(maxX, verts[i].positionUV.x)
            minY = min(minY, verts[i].positionUV.y); maxY = max(maxY, verts[i].positionUV.y)
        }
        #expect(min(maxX - minX, maxY - minY) < 0.001)
    }

    // MARK: - alphafade engine defaults

    @Test("A bare alphafade takes the engine's fade defaults, not zero")
    func bareAlphaFadeTakesEngineDefaults() throws {
        func def(_ operators: String) throws -> WPEParticleDefinition {
            let json = """
            {"maxcount": 8, "renderer":[{"name":"sprite"}],
             "emitter":[{"name":"sphererandom","rate":8}],
             "initializer":[{"name":"lifetimerandom","min":4,"max":4}],
             "operator": \(operators)}
            """
            return try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        }
        // WPE's own reference scene for the operator authors it bare, and the editor
        // writes 0.1 / 0.3 when it creates one.
        let bare = try def(#"[{"name":"alphafade"}]"#)
        #expect(bare.fadeInSeconds == 0.1)
        #expect(bare.fadeOutSeconds == 0.3)

        // Control group 1: an authored value still wins, including an explicit 0.
        let explicit = try def(#"[{"name":"alphafade","fadeintime":0.4,"fadeouttime":0.9}]"#)
        #expect(explicit.fadeInSeconds == 0.4)
        #expect(explicit.fadeOutSeconds == 0.9)
        let zeroed = try def(#"[{"name":"alphafade","fadeouttime":0}]"#)
        #expect(zeroed.fadeOutSeconds == 0)

        // Control group 2: no alphafade operator at all keeps the old no-fade-out
        // behavior — the default belongs to the operator, not to every particle.
        let none = try def(#"[{"name":"movement"}]"#)
        #expect(none.fadeOutSeconds == 0)
    }

    @Test("A bare alphafade actually dims a particle past 30% of its life")
    func bareAlphaFadeDimsLateLife() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let json = """
        {"maxcount": 1, "renderer":[{"name":"sprite"}],
         "emitter":[{"name":"sphererandom","rate":0,"instantaneous":1}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10},
                        {"name":"sizerandom","min":10,"max":10}],
         "operator":[{"name":"alphafade"}]}
        """
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        // `advance` clamps dt to 0.1 s, so age only moves if we tick continuously.
        var now = 0.0
        func alpha(upTo time: Double) -> Float {
            while now < time {
                now = min(time, now + 1.0 / 60)
                system.tick(now: now)
            }
            return system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
        }
        #expect(abs(alpha(upTo: 3.0) - 1) < 0.001, "full brightness up to the fade-out point")
        let late = alpha(upTo: 6.5)                       // 65% of a 10 s life
        #expect(late > 0.4 && late < 0.6, "ramping down, got \(late)")
        #expect(alpha(upTo: 9.5) < 0.1, "nearly gone by the end of life")
    }

    // MARK: - ropetrail per-particle history ribbon (scene 3413921910 meteors)

    /// Far from the world origin so a ribbon that failed to seed its history would
    /// visibly stretch back to (0,0).
    private static let trailSpawnOrigin = SIMD3<Double>(500, 300, 0)

    private static func ropeTrailDefinition(
        kind: WPEParticleTrailRenderer.Kind = .rope,
        subdivision: Double = 3,
        maxCount: Int = 3,
        instantaneousCount: Int? = nil,
        rate: Double = 0,
        lifetime: Double = 100,
        lifetimeSpread: Double = 0
    ) -> WPEParticleDefinition {
        WPEParticleDefinition(
            materialRelativePath: nil,
            trailRenderer: WPEParticleTrailRenderer(
                kind: kind, length: 3, maxLength: 10, subdivision: subdivision
            ),
            maxCount: maxCount,
            rate: rate,
            instantaneousCount: instantaneousCount ?? maxCount,
            startDelay: 0,
            lifetimeMin: lifetime, lifetimeMax: lifetime + lifetimeSpread,
            sizeMin: 10, sizeMax: 10,
            originOffset: trailSpawnOrigin,
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(200, 0, 0), velocityMax: SIMD3(200, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
    }

    @Test("ropetrail packs one ribbon per particle, joined by degenerate bridges")
    func ropeTrailBuildsPerParticleRibbons() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(
            WPEParticleSystem(definition: Self.ropeTrailDefinition(), device: device)
        )
        #expect(system.usesTrailRibbon)
        #expect(system.usesRibbonGeometry)
        #expect(!system.isRope, "ropetrail must not take the whole-chain rope path")

        system.tick(now: 0)
        for step in 1...6 { system.tick(now: Double(step) * 0.05) }

        #expect(system.liveInstanceCount == 3)
        // 3 particles × 4 points × 2 edge vertices, + 2 bridge vertices per junction.
        #expect(system.ropeVertexCount == 3 * 4 * 2 + 2 * 2)

        let verts = try #require(system.ropeVertexBuffer).contents()
            .bindMemory(to: WPEParticleRopeVertex.self, capacity: system.ropeVertexCount)
        // Each bridge repeats the previous ribbon's last vertex, then the next
        // ribbon's first — two zero-area triangles that keep the strip continuous.
        #expect(verts[8].positionUV == verts[7].positionUV)
        #expect(verts[9].positionUV == verts[10].positionUV)
        #expect(verts[18].positionUV == verts[17].positionUV)
        #expect(verts[19].positionUV == verts[20].positionUV)
        // v runs 0→1 head→tail inside a ribbon and restarts on the next one.
        #expect(abs(verts[0].positionUV.w) < 0.001)
        #expect(abs(verts[6].positionUV.w - 1) < 0.001)
        #expect(abs(verts[10].positionUV.w) < 0.001)
    }

    @Test("ropetrail seeds its history at the spawn point, then trails behind")
    func ropeTrailSeedsHistoryAtSpawn() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(
            WPEParticleSystem(definition: Self.ropeTrailDefinition(maxCount: 1), device: device)
        )
        func bounds() throws -> (width: Float, height: Float, minX: Float) {
            let count = system.ropeVertexCount
            let verts = try #require(system.ropeVertexBuffer).contents()
                .bindMemory(to: WPEParticleRopeVertex.self, capacity: count)
            var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
            var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
            for i in 0..<count {
                minX = min(minX, verts[i].positionUV.x); maxX = max(maxX, verts[i].positionUV.x)
                minY = min(minY, verts[i].positionUV.y); maxY = max(maxY, verts[i].positionUV.y)
            }
            return (maxX - minX, maxY - minY, minX)
        }

        system.tick(now: 0)
        #expect(system.liveInstanceCount == 1)
        #expect(system.ropeVertexCount == 8)
        let seeded = try bounds()
        #expect(seeded.width < 0.001, "all four history points start on the spawn point")
        #expect(abs(seeded.height - 10) < 0.001, "only the ±half-size ribbon width")
        #expect(seeded.minX > 400, "a ribbon anchored at the world origin would reach 0")

        for step in 1...6 { system.tick(now: Double(step) * 0.05) }
        let trailing = try bounds()
        #expect(trailing.width > 20, "history must lag behind the moving particle")
        #expect(trailing.minX > 400)
    }

    @Test("ropetrail point count comes from subdivision, not length")
    func ropeTrailPointCountFollowsSubdivision() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func system(_ renderer: String) throws -> WPEParticleSystem {
            let json = """
            {"maxcount": 2, "renderer":[\(renderer)],
             "emitter":[{"name":"sphererandom","rate":0,"instantaneous":2}],
             "initializer":[{"name":"lifetimerandom","min":100,"max":100},
                            {"name":"sizerandom","min":10,"max":10}]}
            """
            let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
            return try #require(WPEParticleSystem(definition: def, device: device))
        }
        // Authored `length: 3` with no `subdivision` ⇒ engine default 3 segments = 4 points.
        let defaulted = try system(#"{"name":"ropetrail","length":3}"#)
        defaulted.tick(now: 0)
        #expect(defaulted.liveInstanceCount == 2)
        #expect(defaulted.ropeVertexCount == 2 * 4 * 2 + 2)

        // Control group: `length` is unchanged, only `subdivision` moves the count.
        let subdivided = try system(#"{"name":"ropetrail","length":3,"subdivision":5}"#)
        subdivided.tick(now: 0)
        #expect(subdivided.liveInstanceCount == 2)
        #expect(subdivided.ropeVertexCount == 2 * 6 * 2 + 2)

        // The one corpus definition that authors `subdivision` (3521337568
        // `particles/短.json`): a fractional `length` next to 2 segments = 3 points.
        // Reading the count off `length` would collapse it to a 1-segment stub.
        let authored = try system(#"{"name":"ropetrail","length":0.2,"subdivision":2}"#)
        authored.tick(now: 0)
        #expect(authored.liveInstanceCount == 2)
        #expect(authored.ropeVertexCount == 2 * 3 * 2 + 2)
    }

    @Test("ropetrail strip tracks the live population as particles expire")
    func ropeTrailStripTracksLivePopulation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Spread lifetimes so the population shrinks as well as grows — an even
        // 1-in/1-out steady state would never exercise the dead-slot path.
        let def = Self.ropeTrailDefinition(
            maxCount: 8, instantaneousCount: 0, rate: 20, lifetime: 0.12, lifetimeSpread: 0.18
        )
        let system = try #require(
            WPEParticleSystem(definition: def, device: device, seed: 0xF12A_0004)
        )
        var sawShrink = false
        var previous = 0
        for step in 0...40 {
            system.tick(now: Double(step) * 0.05)
            let alive = system.liveInstanceCount
            let expected = alive > 0 ? alive * 4 * 2 + (alive - 1) * 2 : 0
            #expect(system.ropeVertexCount == expected, "alive=\(alive) at step \(step)")
            if alive < previous { sawShrink = true }
            previous = alive
        }
        #expect(sawShrink, "particles must have expired during the sweep")
    }

    /// Width of the ribbon along X. The helper definition flies straight +X, so the
    /// ribbon's own thickness lies entirely on Y and this reads as its length.
    private static func ribbonSpanX(_ system: WPEParticleSystem) throws -> Float {
        let count = system.ropeVertexCount
        guard count > 0 else { return 0 }
        let verts = try #require(system.ropeVertexBuffer).contents()
            .bindMemory(to: WPEParticleRopeVertex.self, capacity: count)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        for i in 0..<count {
            minX = min(minX, verts[i].positionUV.x)
            maxX = max(maxX, verts[i].positionUV.x)
        }
        return maxX - minX
    }

    @Test("ropetrail length comes from the authored `length`, clamped by `maxlength`")
    func ropeTrailLengthFollowsAuthoredLength() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // size 10, speed 200 ⇒ ribbon = size × clamp(speed·length, 1, maxlength).
        func span(length: Double, maxLength: Double = 10) throws -> Float {
            let def = WPEParticleDefinition(
                materialRelativePath: nil,
                trailRenderer: WPEParticleTrailRenderer(
                    kind: .rope, length: length, maxLength: maxLength, subdivision: 3
                ),
                maxCount: 1, rate: 0, instantaneousCount: 1, startDelay: 0,
                lifetimeMin: 100, lifetimeMax: 100,
                sizeMin: 10, sizeMax: 10,
                originOffset: Self.trailSpawnOrigin,
                dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
                velocityMin: SIMD3(200, 0, 0), velocityMax: SIMD3(200, 0, 0),
                colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0
            )
            let system = try #require(WPEParticleSystem(definition: def, device: device))
            system.tick(now: 0)
            // 1.5 s of flight = 300 px of recorded path, more than any span below.
            for step in 1...30 { system.tick(now: Double(step) * 0.05) }
            return try Self.ribbonSpanX(system)
        }

        // clamp(200·3, 1, 10) = 10 ⇒ 10 × 10 = 100 px
        #expect(abs(try span(length: 3) - 100) < 2)
        // clamp(200·0.01, 1, 10) = 2 ⇒ 20 px — `length` alone moved it 5×
        #expect(abs(try span(length: 0.01) - 20) < 2)
        // `maxlength` caps the same authored length back down to the 20 px ribbon
        #expect(abs(try span(length: 3, maxLength: 2) - 20) < 2)
        // Our floor: a stalled-slow particle still draws one sprite length, never zero
        #expect(abs(try span(length: 0.0001) - 10) < 2)
    }

    @Test("ropetrail grows in from the spawn point instead of inventing path")
    func ropeTrailGrowsInFromSpawn() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(
            WPEParticleSystem(definition: Self.ropeTrailDefinition(maxCount: 1), device: device)
        )
        system.tick(now: 0)
        #expect(try Self.ribbonSpanX(system) < 0.001, "no recorded path yet")
        // 3 ticks at 200 px/s = 30 px flown; the nominal ribbon is 100 px long, so
        // the trail must stop at what actually happened.
        for step in 1...3 { system.tick(now: Double(step) * 0.05) }
        #expect(abs(try Self.ribbonSpanX(system) - 30) < 2)
        for step in 4...30 { system.tick(now: Double(step) * 0.05) }
        #expect(abs(try Self.ribbonSpanX(system) - 100) < 2, "settles at the authored length")
    }

    @Test("ropetrail world length is frame-rate independent")
    func ropeTrailLengthIsFrameRateIndependent() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func span(step: Double) throws -> Float {
            let system = try #require(
                WPEParticleSystem(definition: Self.ropeTrailDefinition(maxCount: 1), device: device)
            )
            system.tick(now: 0)
            var now = 0.0
            while now < 1.5 {
                now += step
                system.tick(now: now)
            }
            return try Self.ribbonSpanX(system)
        }
        let at60 = try span(step: 1.0 / 60)
        let at30 = try span(step: 1.0 / 30)
        #expect(abs(at60 - 100) < 2)
        #expect(abs(at30 - 100) < 3, "halving the tick rate must not halve the trail")
    }

    @Test("spritetrail keeps the sprite path and allocates no ribbon")
    func spriteTrailKeepsSpritePath() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(
            WPEParticleSystem(definition: Self.ropeTrailDefinition(kind: .sprite), device: device)
        )
        #expect(!system.usesTrailRibbon)
        #expect(!system.usesRibbonGeometry)
        #expect(system.ropeVertexBuffer == nil)
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 3)
        #expect(system.ropeVertexCount == 0)
    }

    // MARK: - eventfollow bursts (scene 3413921910 meteor glow / shine)

    private static func eventFollowParentDefinition() -> WPEParticleDefinition {
        WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 32,
            rate: 20,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 10, sizeMax: 10,
            originOffset: trailSpawnOrigin,
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(100, 0, 0), velocityMax: SIMD3(100, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
    }

    private static func burstChildDefinition(
        instantaneous: Int = 2, maxCount: Int = 16
    ) -> WPEParticleDefinition {
        WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: maxCount,
            rate: 0,
            instantaneousCount: instantaneous,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3<Double>(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
    }

    @Test("eventfollow child bursts once per parent birth, not once per system")
    func eventFollowBurstsPerParentSpawn() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let parent = try #require(
            WPEParticleSystem(definition: Self.eventFollowParentDefinition(), device: device)
        )
        let child = try #require(
            WPEParticleSystem(definition: Self.burstChildDefinition(), device: device)
        )
        child.followParent = parent
        child.requiresFollowParent = true

        parent.tick(now: 0)
        child.tick(now: 0)
        #expect(parent.liveInstanceCount == 0, "dt is 0 on the first tick, so rate spawns nothing")
        #expect(child.liveInstanceCount == 0)

        for step in 1...3 {
            let time = Double(step) * 0.05
            parent.tick(now: time)
            child.tick(now: time)
        }
        #expect(parent.liveInstanceCount == 3)
        #expect(child.liveInstanceCount == 6, "2 per birth × 3 births — not a single one-shot")
    }

    @Test("Child probability and scale parse, with engine defaults and a clamp")
    func childProbabilityAndScaleParse() throws {
        let json = #"""
        {
            "maxcount": 8,
            "renderer": [{"name": "sprite"}],
            "children": [
                {"name": "a.json", "type": "eventfollow", "probability": 0.2, "scale": "2.5 2.5 1"},
                {"name": "b.json", "type": "static"},
                {"name": "c.json", "type": "eventdeath", "probability": 0},
                {"name": "d.json", "probability": 7}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let children = def.childReferences
        #expect(children.count == 4)
        #expect(children[0].probability == 0.2)
        #expect(children[0].scale == SIMD3<Double>(2.5, 2.5, 1))
        // Absent keys take the engine defaults, not zero.
        #expect(children[1].probability == 1)
        #expect(children[1].scale == SIMD3<Double>(1, 1, 1))
        #expect(children[2].probability == 0)
        #expect(children[3].probability == 1, "out-of-range probability clamps to 1")

        // Which children re-roll per event vs once at creation.
        #expect(children[0].rollsProbabilityPerEvent, "eventfollow")
        #expect(!children[1].rollsProbabilityPerEvent, "static rolls once")
        #expect(children[2].rollsProbabilityPerEvent, "eventdeath")
        #expect(!children[3].rollsProbabilityPerEvent, "no type ⇒ static")
    }

    @Test("eventfollow probability is rolled per parent event, not once per system")
    func eventFollowProbabilityRollsPerEvent() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        /// Runs the parent's births past a child at `probability`, returns child
        /// alive count. The child pool is deliberately far larger than the parent's
        /// so saturation can't mask the difference between 0.5 and 1.
        func bursts(probability: Double, seed: UInt64) throws -> Int {
            let parent = try #require(
                WPEParticleSystem(definition: Self.eventFollowParentDefinition(), device: device)
            )
            let child = try #require(
                WPEParticleSystem(
                    definition: Self.burstChildDefinition(instantaneous: 1, maxCount: 256),
                    device: device, seed: seed
                )
            )
            child.followParent = parent
            child.requiresFollowParent = true
            child.spawnProbability = probability
            for step in 0...40 {
                let time = Double(step) * 0.05
                parent.tick(now: time)
                child.tick(now: time)
            }
            return child.liveInstanceCount
        }

        // Control group at the ends: 1 fires on every event, 0 on none.
        // The parent's own pool (maxCount 32) bounds how many events exist.
        let all = try bursts(probability: 1, seed: 0xC0FF_EE01)
        #expect(all == 32, "one burst per parent birth")
        #expect(try bursts(probability: 0, seed: 0xC0FF_EE01) == 0)

        // The real case (Valve's thunderbolt ships eventfollow @ 0.2, the corpus
        // has six eventfollow @ 0.5): a fraction of the events, not all-or-nothing.
        // Two seeds so one lucky draw can't carry the assertion.
        for seed in [UInt64(0xC0FF_EE01), 0xC0FF_EE02] {
            let half = try bursts(probability: 0.5, seed: seed)
            #expect(half > 8 && half < 26, "seed \(String(seed, radix: 16)) gave \(half)")
        }
    }

    @Test("A non-eventfollow instantaneous burst still fires exactly once")
    func instantaneousBurstStaysOneShot() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(
            WPEParticleSystem(definition: Self.burstChildDefinition(instantaneous: 3), device: device)
        )
        for step in 0...20 { system.tick(now: Double(step) * 0.05) }
        #expect(system.liveInstanceCount == 3, "fireworks/explosion bursts must not repeat")
    }

    @Test("eventfollow child with no parent stays empty")
    func eventFollowWithoutParentStaysEmpty() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(
            WPEParticleSystem(definition: Self.burstChildDefinition(), device: device)
        )
        system.requiresFollowParent = true
        for step in 0...20 { system.tick(now: Double(step) * 0.05) }
        #expect(system.liveInstanceCount == 0)
    }

    @Test("prewarm spawn events are dropped, and live births still burst afterwards")
    func prewarmDropsSpawnEventsButKeepsBursting() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let parent = try #require(
            WPEParticleSystem(definition: Self.eventFollowParentDefinition(), device: device)
        )
        let child = try #require(
            WPEParticleSystem(definition: Self.burstChildDefinition(), device: device)
        )
        child.followParent = parent
        child.requiresFollowParent = true

        parent.prewarm(simulatedSeconds: 1)
        #expect(parent.spawnEventsThisTick.isEmpty, "prewarm births must not reach the first frame")
        child.prewarm(simulatedSeconds: 1)

        for step in 0...2 {
            let time = Double(step) * 0.05
            parent.tick(now: time)
            child.tick(now: time)
        }
        #expect(child.liveInstanceCount == 4, "2 live parent births × 2 particles")
    }

    // MARK: - prewarm convergence (skipping the pre-lifetimeMax treadmill)

    private static func convergenceDefinition(lifetime: Double) -> WPEParticleDefinition {
        WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 2_000,
            rate: 60, startDelay: 0,
            lifetimeMin: lifetime, lifetimeMax: lifetime,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
    }

    @Test("Prewarm past lifetimeMax lands on the same population as a short window")
    func prewarmConvergesRegardlessOfWindowLength() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Everything alive at the end was born within the last `lifetime`
        // seconds, so a 5s and a 90s window must agree — the extra 85s is a
        // treadmill that only costs time.
        let short = try #require(
            WPEParticleSystem(definition: Self.convergenceDefinition(lifetime: 4), device: device)
        )
        let long = try #require(
            WPEParticleSystem(definition: Self.convergenceDefinition(lifetime: 4), device: device)
        )
        short.prewarm(simulatedSeconds: 5, presimulateDelay: true)
        long.prewarm(simulatedSeconds: 90, presimulateDelay: true)
        short.tick(now: 0)
        long.tick(now: 0)
        #expect(short.liveInstanceCount == long.liveInstanceCount,
                "short=\(short.liveInstanceCount) long=\(long.liveInstanceCount)")
        #expect(long.liveInstanceCount >= 200, "rate 60 x lifetime 4 should saturate near 240")
    }

    @Test("A one-shot burst does not re-fire when the prewarm head is skipped")
    func truncatedPrewarmDoesNotReplayBurst() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // instantaneous 3, lifetime 100: the burst fires once at t=0 and those
        // particles are still alive, so nothing is skipped and the count is 3.
        let live = try #require(
            WPEParticleSystem(definition: Self.burstChildDefinition(instantaneous: 3), device: device)
        )
        live.prewarm(simulatedSeconds: 50, presimulateDelay: true)
        live.tick(now: 0)
        #expect(live.liveInstanceCount == 3, "one burst, still within its lifetime")

        // Same burst but the window runs far past the particles' lifetime: they
        // are long dead, and the skipped head must not resurrect them.
        let expired = try #require(
            WPEParticleSystem(definition: Self.convergenceDefinition(lifetime: 2), device: device)
        )
        expired.prewarm(simulatedSeconds: 80, presimulateDelay: true)
        expired.tick(now: 0)
        // rate 60 x lifetime 2 = ~120 steady state; a replayed burst would show up
        // as a spike above it, and a dead system as 0.
        #expect(expired.liveInstanceCount >= 100 && expired.liveInstanceCount <= 130,
                "got \(expired.liveInstanceCount)")
    }

    // MARK: - eventfollow prewarm (scene 3226487183 matrix_trail)

    /// Rate-based `eventfollow` child, shaped like 3226487183's `matrix_trail`:
    /// it rides the parent continuously rather than bursting on birth events.
    private static func rateFollowChildDefinition() -> WPEParticleDefinition {
        WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 100,
            rate: 2,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3<Double>(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
    }

    private func makeFollowPair(
        _ device: MTLDevice
    ) throws -> (parent: WPEParticleSystem, child: WPEParticleSystem) {
        let parent = try #require(
            WPEParticleSystem(definition: Self.eventFollowParentDefinition(), device: device)
        )
        let child = try #require(
            WPEParticleSystem(definition: Self.rateFollowChildDefinition(), device: device)
        )
        child.followParent = parent
        child.requiresFollowParent = true
        return (parent, child)
    }

    @Test("Prewarming an eventfollow child alone leaves it empty — the bug the chain fixes")
    func independentPrewarmStarvesFollowChild() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (parent, child) = try makeFollowPair(device)

        parent.prewarm(simulatedSeconds: 6, presimulateDelay: true)
        child.prewarm(simulatedSeconds: 6, presimulateDelay: true)
        // prewarm never writes the instance buffer; `tick` at dt 0 publishes it.
        parent.tick(now: 0)
        child.tick(now: 0)

        #expect(parent.liveInstanceCount > 0, "the parent prewarms fine on its own")
        #expect(child.liveInstanceCount == 0,
                "no injected parent position, so every rate spawn is refused")
    }

    @Test("Lockstep chain prewarm populates a rate-based eventfollow child")
    func chainPrewarmPopulatesFollowChild() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (parent, child) = try makeFollowPair(device)

        WPEMetalSceneRenderer.prewarmFollowChain(
            [(parent, 6), (child, 6)], presimulateDelay: true
        )
        parent.tick(now: 0)
        child.tick(now: 0)

        #expect(parent.liveInstanceCount > 0)
        // rate 2/s over ~6s, minus the parent's first-spawn lead-in; lifetime is
        // 100s here so nothing dies. Bounded above by the authored maxcount.
        #expect(child.liveInstanceCount >= 10,
                "child had \(child.liveInstanceCount) particles, expected ~12")
        #expect(child.liveInstanceCount <= 12)
    }

    @Test("Chain prewarm spawns the child ON the parent, not at the static origin")
    func chainPrewarmSpawnsAtParentPositions() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (parent, child) = try makeFollowPair(device)

        WPEMetalSceneRenderer.prewarmFollowChain(
            [(parent, 6), (child, 6)], presimulateDelay: true
        )
        child.tick(now: 0)

        // The parent moves at +100 x/s from `trailSpawnOrigin`, so its children
        // must be strewn along x. Spawning at the child's own (0,0,0) origin —
        // the failure mode `spawn` guards against — would collapse them onto one point.
        let count = child.liveInstanceCount
        try #require(count >= 2)
        let instances = child.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: count)
        let xs = Set((0..<count).map { instances[$0].positionAndSize.x })
        #expect(xs.count > 1, "every child spawned at the same x — not following")
    }

    @Test("A follow chain whose members have different starttimes aligns on the capture instant")
    func chainPrewarmAlignsWindowEnds() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (parent, child) = try makeFollowPair(device)

        // Parent pre-simulates 4s longer than the child; both must END together,
        // so the child still sees a live parent for its whole window.
        WPEMetalSceneRenderer.prewarmFollowChain(
            [(parent, 10), (child, 6)], presimulateDelay: true
        )
        child.tick(now: 0)

        #expect(child.liveInstanceCount >= 10,
                "child had \(child.liveInstanceCount); a start-aligned window would starve it")
    }

    // MARK: - boxrandom emitter (scene 3351072238 rain pile)

    @Test("boxrandom parses vector distancemax and scatters across the box")
    func boxEmitterScattersAcrossExtent() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let json = """
        {"maxcount": 200, "renderer":[{"name":"sprite"}],
         "emitter":[{"name":"boxrandom","rate":400,"distancemax":"1200 1000 0"}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}]}
        """
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.emitterShape == .box)
        #expect(def.dispersalMax == SIMD3<Double>(1200, 1000, 0))

        let system = try #require(WPEParticleSystem(
            definition: def, device: device, sceneTransform: centeredParticleTransform))
        system.tick(now: 0)
        for step in 1...8 { system.tick(now: Double(step) * 0.05) }
        let alive = system.liveInstanceCount
        #expect(alive > 20)

        let p = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: alive)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for i in 0..<alive {
            minX = min(minX, p[i].positionAndSize.x); maxX = max(maxX, p[i].positionAndSize.x)
            minY = min(minY, p[i].positionAndSize.y); maxY = max(maxY, p[i].positionAndSize.y)
        }
        #expect((maxX - minX) > 800)
        #expect((maxY - minY) > 600)
    }

    @Test("Scalar sphererandom emitter still parses as a sphere")
    func sphereEmitterStaysScalar() throws {
        let json = """
        {"maxcount": 20, "emitter":[{"name":"sphererandom","rate":2,"distancemax":512}]}
        """
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.emitterShape == .sphere)
        #expect(def.dispersalMax == SIMD3<Double>(512, 512, 512))
    }

    /// `oscillatesize` shares `FrequencyValue`/`GetScale` with `oscillatealpha`, but
    /// `WPParticleParser.cpp`'s `ReadFromJson` gives it its own scale defaults (0.8…1.2 instead of
    /// the base 0…1). `particles/presets/fireflies.json` authors only `frequencymin`.
    @Test("oscillatesize parses with its own scale defaults and no diagnostic")
    func parsesOscillateSizeDefaults() throws {
        let json = """
        {"maxcount": 20, "emitter":[{"name":"boxrandom","rate":2}],
         "operator":[{"name":"oscillatesize","frequencymin":5}]}
        """
        var diagnostics: [WPESceneDiagnostic] = []
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let def = WPEParticleDefinitionParser.parse(dictionary: object, diagnostics: &diagnostics)
        let osc = try #require(def.oscillateSize)
        #expect(osc.frequencyMin == 5)
        #expect(osc.frequencyMax == 10)
        #expect(osc.scaleMin == 0.8)
        #expect(osc.scaleMax == 1.2)
        #expect(!diagnostics.contains { $0.message.contains("oscillatesize") })
    }

    /// The alpha oscillator clamps its factor into 0…1 because alpha cannot exceed 1. Size can:
    /// `deku_twinkle_star_shine.json` authors `scalemax: 1.5`, and reusing the alpha clamp would
    /// silently flatten every enlargement to 1.0.
    @Test("oscillatesize factor spans the authored scale range above 1.0")
    func oscillateSizeFactorIsNotClampedToOne() throws {
        let json = """
        {"maxcount": 20, "emitter":[{"name":"boxrandom","rate":2}],
         "operator":[{"name":"oscillatesize","frequencymin":2,"frequencymax":4,
                      "scalemin":0.6,"scalemax":1.5}]}
        """
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let osc = try #require(def.oscillateSize)
        // `GetScale` is lerp(scalemin, scalemax) over (cos(w·t + phase) + 1)/2, and w is the
        // authored frequency (the reference's /2π and ·2π cancel). phase = 0, t = 0 → cos = 1.
        #expect(abs(osc.factor(age: 0, frequency: 3, phase: 0) - 1.5) < 1e-9)
        // Half a period later the cosine is -1 → the low end of the range.
        #expect(abs(osc.factor(age: .pi / 3, frequency: 3, phase: 0) - 0.6) < 1e-9)
        // A zero frequency draw leaves the size untouched rather than freezing it at scalemin.
        #expect(osc.factor(age: 1, frequency: 0, phase: 0) == 1)
    }

    /// Parsing the operator is not the same as applying it. `scalemin == scalemax` pins the
    /// cosine's output to a constant, so the rendered sprite size is checked against an exact
    /// multiple with no dependence on the per-particle frequency/phase draw.
    @Test("oscillatesize multiplies the rendered sprite size")
    func oscillateSizeScalesRenderedSprite() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeSystem(withOscillator: Bool) throws -> WPEParticleSystem {
            let oscillator = withOscillator
                ? #",{"name":"oscillatesize","frequencymin":1,"frequencymax":1,"scalemin":2,"scalemax":2}"#
                : ""
            let json = """
            {
                "maxcount": 4,
                "emitter": [{"name":"boxrandom","rate":60,"distancemin":"0 0 0","distancemax":"0 0 0"}],
                "initializer": [{"name":"sizerandom","min":40,"max":40},
                                {"name":"lifetimerandom","min":100,"max":100}]\(oscillator.isEmpty ? "" : ",")
                \(oscillator.isEmpty ? "" : "\"operator\": [\(oscillator.dropFirst())]")
            }
            """
            let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
            return try #require(WPEParticleSystem(definition: def, device: device, seed: 0x5125_2E01))
        }
        func spriteSize(_ system: WPEParticleSystem) -> Float {
            system.tick(now: 0)
            system.tick(now: 0.25)
            return system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.w
        }
        let plain = try spriteSize(makeSystem(withOscillator: false))
        let oscillated = try spriteSize(makeSystem(withOscillator: true))
        #expect(plain > 0)
        #expect(abs(oscillated - plain * 2) < 1e-3)
    }

    /// Both per-instance copy helpers are hand-written field lists; dropping one silently loses
    /// the operator (this has bitten twice before).
    @Test("oscillatesize survives both per-instance copy helpers")
    func oscillateSizeSurvivesCopies() throws {
        let json = """
        {"maxcount": 20, "emitter":[{"name":"boxrandom","rate":2}],
         "operator":[{"name":"oscillatesize","frequencymin":2,"scalemax":1.4}]}
        """
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.applying(instanceOverride: nil).oscillateSize == def.oscillateSize)
        #expect(def.offsettingOrigin(by: SIMD3<Double>(1, 2, 3)).oscillateSize == def.oscillateSize)
    }

    /// Third drop through the same hand-written field list (after `shapePoints` and
    /// `colorAnimation`): `offsettingOrigin` omitted `overrideAlphaAnimation`. It stayed
    /// invisible only because the one production call site runs `applying` last — swap the
    /// two and the 3448877775-style alpha ramp silently flattens.
    @Test("overrideAlphaAnimation survives offsettingOrigin")
    func overrideAlphaAnimationSurvivesOriginOffset() throws {
        let json = """
        {"maxcount": 20, "emitter":[{"name":"boxrandom","rate":2}]}
        """
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let ramp = WPESceneAnimatedValue(
            animation: WPESceneNumericAnimation(
                tracks: [[.init(frame: 0, value: 0), .init(frame: 30, value: 1)]],
                fps: 30, length: 30, mode: "loop", wrapLoop: true
            ),
            scalarFallback: 1,
            vectorFallback: nil
        )
        let withRamp = def.applying(instanceOverride: WPESceneParticleInstanceOverride(alphaAnimation: ramp))
        #expect(withRamp.overrideAlphaAnimation != nil)
        #expect(
            withRamp.offsettingOrigin(by: SIMD3<Double>(1, 2, 3)).overrideAlphaAnimation
                == withRamp.overrideAlphaAnimation
        )
    }
}
