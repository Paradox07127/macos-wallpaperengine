#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Windows-backed independent particle child instances")
struct WPEParticleInstanceCoordinatorTests {
    @Test func frameArenaPreservesOutputAcrossSystemsAndInFlightSlots() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let arena = WPEParticleFrameArena(device: device)
        var owned: [WPEParticleSystem] = []
        var shared: [WPEParticleSystem] = []
        for renderer in ["sprite", "rope", "ropetrail"] {
            let definition = WPEParticleDefinitionParser.parse(dictionary: [
                "maxcount": 8192, "renderer": [["name": renderer]],
                "emitter": [["name": "boxrandom", "rate": 8, "instantaneous": 5]],
                "initializer": [["name": "lifetimerandom", "min": 0.5, "max": 0.7],
                                ["name": "velocityrandom", "min": "2 5 0", "max": "8 10 0"]],
            ])
            try owned.append(#require(WPEParticleSystem(definition: definition, device: device, seed: 88)))
            let system = try #require(WPEParticleSystem(definition: definition, device: device, seed: 88, usesFrameArena: true))
            #expect(system.ownedRenderBufferBytes == 0)
            shared.append(system)
        }
        func bytes(_ system: WPEParticleSystem) -> Data {
            let length = system.usesRibbonGeometry
                ? system.ropeVertexCount * MemoryLayout<WPEParticleRopeVertex>.stride
                : system.liveInstanceCount * MemoryLayout<WPEParticleInstance>.stride
            guard length > 0 else { return Data() }
            let buffer = system.usesRibbonGeometry ? system.ropeVertexBuffer : system.instanceBuffer
            guard let buffer else { return Data() }
            return Data(bytes: buffer.contents().advanced(by: system.renderBufferOffset), count: length)
        }
        var heldSlice: WPEParticleRenderSlice?
        var heldBytes = Data()
        for frame in 0 ... 180 {
            let slot = frame % 2
            for (a, b) in zip(owned, shared) {
                a.tick(now: Double(frame) / 60, frameSlot: slot)
                b.advanceSimulation(now: Double(frame) / 60)
            }
            #expect(arena.prepare(shared, frameSlot: slot))
            for (a, b) in zip(owned, shared) {
                #expect(a.playbackSnapshot == b.playbackSnapshot)
                #expect(a.ropeVertexCount == b.ropeVertexCount)
                #expect(bytes(a) == bytes(b))
            }
            if frame == 0 {
                let system = shared[0]
                heldSlice = .init(buffer: system.instanceBuffer, offset: system.renderBufferOffset,
                                  length: system.requiredRenderByteCount)
                heldBytes = bytes(system)
            } else if frame == 1, let heldSlice {
                #expect(Data(bytes: heldSlice.buffer.contents().advanced(by: heldSlice.offset), count: heldSlice.length) == heldBytes)
                #expect(heldSlice.buffer !== shared[0].instanceBuffer)
            }
        }
        #expect(arena.allocatedBytes < owned.reduce(0) { $0 + $1.ownedRenderBufferBytes })
        let allocations = arena.allocationCount
        #expect(arena.prepare(shared, frameSlot: 0))
        #expect(arena.allocationCount == allocations)
    }

    @Test func eventInstancesShareImmutableAtlasAndKeepSeparateIdentity() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let definition = WPEParticleDefinitionParser.parse(dictionary: ["maxcount": 8])
        let sheet = WPEParticleSpriteSheet(
            cols: 1, rows: 1, frameCount: 2, baseFrameRate: 10,
            isAlphaMask: false, frameRects: [SIMD4(0, 0, 0.5, 1), SIMD4(0.5, 0, 1, 1)]
        )
        let prototype = try #require(WPEParticleSystem(
            definition: definition, device: device, spriteSheet: sheet, seed: 1, usesFrameArena: true
        ))
        let first = try #require(prototype.makeEventInstance(device: device, seed: 2))
        let second = try #require(prototype.makeEventInstance(device: device, seed: 3))
        #expect(first !== second && first !== prototype)
        #expect(first.frameRectsBuffer === prototype.frameRectsBuffer)
        #expect(second.frameRectsBuffer === prototype.frameRectsBuffer)
        #expect(first.ownedRenderBufferBytes == 0 && second.ownedRenderBufferBytes == 0)
    }

    @Test func bindingCacheInvalidatesForBirthReleaseAndRestart() throws {
        let (tree, root) = try makeTree(kind: "eventfollow", maximum: 1)
        #expect(tree.bindings.count == 1)
        let initial = tree.bindingRevision
        tree.tick(now: 0)
        tree.tick(now: 0.05)
        #expect(tree.bindingRevision == initial)
        for frame in 4 ... 150 {
            tree.tick(now: Double(frame) / 60)
        }
        #expect(tree.bindings.count == 2)
        let created = tree.bindingRevision
        tree.tick(now: 2.51)
        #expect(tree.bindingRevision == created)
        tree.apply([.init(objectID: "test", command: .stop)])
        #expect(tree.bindingRevision > created)
        #expect(tree.bindings.count == 1)
        tree.apply([.init(objectID: "test", command: .play)])
        for frame in 151 ... 300 {
            tree.tick(now: Double(frame) / 60)
        }
        #expect(tree.bindings.count == 2)
        #expect(tree.bindings.last?.system !== root)
        #expect(tree.eventInstanceCount == 1)
    }

    @Test(arguments: ["sprite", "rope", "ropetrail"])
    func renderPreparationLeavesSimulationAndHistoryUnchanged(renderer: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 16, "renderer": [["name": renderer]],
            "emitter": [["name": "boxrandom", "rate": 8]],
            "initializer": [["name": "lifetimerandom", "min": 0.5, "max": 0.7],
                            ["name": "velocityrandom", "min": "2 5 0", "max": "8 10 0"]],
        ])
        let immediate = try #require(WPEParticleSystem(definition: definition, device: device, seed: 55))
        let deferred = try #require(WPEParticleSystem(definition: definition, device: device, seed: 55))
        for frame in 0 ... 180 {
            let now = Double(frame) / 60
            immediate.tick(now: now, frameSlot: frame % 2)
            deferred.advanceSimulation(now: now)
            #expect(deferred.playbackSnapshot == immediate.playbackSnapshot)
            if let identity = immediate.primaryLiveParticleIdentity {
                #expect(deferred.snapshot(for: identity) == immediate.snapshot(for: identity))
            }
            if frame % 4 != 0 {
                continue
            }
            deferred.prepareRenderData(frameSlot: frame % 2)
            let bytes = immediate.usesRibbonGeometry
                ? immediate.ropeVertexCount * MemoryLayout<WPEParticleRopeVertex>.stride
                : immediate.liveInstanceCount * MemoryLayout<WPEParticleInstance>.stride
            let a = immediate.usesRibbonGeometry ? immediate.ropeVertexBuffer : immediate.instanceBuffer
            let b = deferred.usesRibbonGeometry ? deferred.ropeVertexBuffer : deferred.instanceBuffer
            if let a, let b {
                #expect(Data(bytes: a.contents(), count: bytes) == Data(bytes: b.contents(), count: bytes))
            }
        }
    }

    @Test(arguments: ["eventspawn", "eventdeath", "eventfollow"])
    func deferredOutputPreservesLifecycleAndFrameBuffers(kind: String) throws {
        let (immediate, _) = try makeTree(kind: kind)
        let (deferred, _) = try makeTree(kind: kind)
        for frame in 0 ... 200 {
            let time = Double(frame) / 15
            let slot = frame % 2
            immediate.tick(now: time, frameSlot: slot)
            deferred.tick(now: time, frameSlot: slot, shouldPrepareRenderData: { _ in false })
            let left = immediate.bindings
            let right = deferred.bindings
            #expect(left.count == right.count)
            #expect(immediate.eventInstanceCount == deferred.eventInstanceCount)
            #expect(immediate.eventParticleSlots == deferred.eventParticleSlots)
            #expect(immediate.createdEventInstances == deferred.createdEventInstances)
            #expect(immediate.releasedEventInstances == deferred.releasedEventInstances)
            for (a, b) in zip(left, right) {
                #expect(a.system.playbackSnapshot == b.system.playbackSnapshot)
                #expect(a.system.particleEventsThisTick == b.system.particleEventsThisTick)
                #expect(a.system.primaryLiveParticleIdentity == b.system.primaryLiveParticleIdentity)
                #expect(a.system.instanceOriginOffset == b.system.instanceOriginOffset)
                b.system.prepareRenderData(frameSlot: slot)
                let bytes = a.system.liveInstanceCount * MemoryLayout<WPEParticleInstance>.stride
                #expect(Data(bytes: a.system.instanceBuffer.contents(), count: bytes)
                    == Data(bytes: b.system.instanceBuffer.contents(), count: bytes))
            }
        }
    }

    @Test(arguments: ["eventspawn", "eventdeath", "eventfollow"])
    func twoParentsOwnIndependentClocksAndOrigins(kind: String) throws {
        let (tree, root) = try makeTree(kind: kind)
        let finalFrame = kind == "eventdeath" ? 450 : 270
        for frame in 0 ... finalFrame {
            tree.tick(now: Double(frame) / 60)
        }
        let children = tree.bindings.filter { $0.system !== root }
        try #require(children.count == 2)
        #expect(children[0].system !== children[1].system)
        let allChildrenEmit = children.allSatisfy(\.system.playbackSnapshot.isEmitting)
        #expect(allChildrenEmit)
        if kind == "eventfollow" {
            #expect(abs(children[0].system.instanceOriginOffset.x - children[1].system.instanceOriginOffset.x) > 20)
            for frame in 271 ... 570 {
                tree.tick(now: Double(frame) / 60)
            }
            #expect(tree.bindings.count == 1)
        } else {
            #expect(children.allSatisfy { abs($0.system.instanceOriginOffset.x - (kind == "eventdeath" ? 48 : 0)) < 0.001 })
            #expect(children[0].system.liveInstanceCount != children[1].system.liveInstanceCount)
        }
    }

    @Test func wholeFollowInstanceMovesOldParticlesAndFreezesAtDeath() throws {
        let (tree, root) = try makeTree(kind: "eventfollow")
        for frame in 0 ... 150 {
            tree.tick(now: Double(frame) / 60)
        }
        let child = try #require(tree.bindings.first { $0.system !== root }?.system)
        let identity = try #require(child.primaryLiveParticleIdentity)
        let before = try #require(child.snapshot(for: identity))
        for frame in 151 ... 165 {
            tree.tick(now: Double(frame) / 60)
        }
        let after = try #require(child.snapshot(for: identity))
        #expect(abs((after.displayPosition.x - before.displayPosition.x) - 4) < 0.1)
        #expect(abs(after.position.x - before.position.x) < 0.001)
        for frame in 166 ... 315 {
            tree.tick(now: Double(frame) / 60)
        }
        #expect(!child.playbackSnapshot.isEmitting)
        #expect(child.liveInstanceCount > 0)
        let frozen = child.instanceOriginOffset
        for frame in 316 ... 330 {
            tree.tick(now: Double(frame) / 60)
        }
        #expect(child.instanceOriginOffset == frozen)
    }

    @Test func stopReleasesDescendantsAndPlayCannotRetargetRecycledParentSlots() throws {
        let (tree, root) = try makeTree(kind: "eventfollow")
        for frame in 0 ... 150 {
            tree.tick(now: Double(frame) / 60)
        }
        let oldChild = try #require(tree.bindings.first { $0.system !== root }?.system)
        tree.apply([.init(objectID: "test", command: .stop)])
        #expect(tree.bindings.count == 1)
        #expect(root.liveInstanceCount == 0)
        tree.apply([.init(objectID: "test", command: .play)])
        for frame in 151 ... 300 {
            tree.tick(now: Double(frame) / 60)
        }
        #expect(tree.bindings.contains { $0.system !== root })
        #expect(!tree.bindings.contains { $0.system === oldChild })
    }

    @Test func referenceLimitIsInstanceScopedAndProbabilityZeroCreatesNothing() throws {
        let (bounded, root) = try makeTree(kind: "eventspawn", maximum: 1)
        for frame in 0 ... 390 {
            bounded.tick(now: Double(frame) / 60)
        }
        #expect(bounded.bindings.filter { $0.system !== root }.count == 1)
        let (zero, _) = try makeTree(kind: "eventspawn", probability: 0)
        for frame in 0 ... 390 {
            zero.tick(now: Double(frame) / 60)
        }
        #expect(zero.bindings.count == 1)
    }

    @Test func eventPrewarmMatchesFullLockstepReplayIncludingPersistentChildren() throws {
        let (live, _) = try makeTree(kind: "eventspawn")
        let (warm, root) = try makeTree(kind: "eventspawn")
        for frame in 0 ... 330 {
            live.tick(now: Double(frame) / 60)
        }
        warm.prewarm(secondsByRoot: [ObjectIdentifier(root): 5.5])
        #expect(warm.bindings.count == live.bindings.count)
        for (a, b) in zip(warm.bindings, live.bindings) {
            #expect(a.system.liveInstanceCount == b.system.liveInstanceCount)
            #expect(a.system.instanceOriginOffset == b.system.instanceOriginOffset)
            if let ai = a.system.primaryLiveParticleIdentity, let bi = b.system.primaryLiveParticleIdentity {
                let ap = try #require(a.system.snapshot(for: ai))
                let bp = try #require(b.system.snapshot(for: bi))
                #expect(abs(ap.age - bp.age) < 0.02)
                #expect(abs(ap.position.y - bp.position.y) < 0.2)
            }
        }
        warm.tick(now: 1.0 / 60)
        #expect(warm.bindings.count == live.bindings.count)
    }

    @Test func pauseResumePreservesIndependentChildrenWithoutRevivingDeadFollowers() throws {
        let (tree, root) = try makeTree(kind: "eventfollow")
        for frame in 0 ... 330 {
            tree.tick(now: Double(frame) / 60)
        }
        let children = tree.bindings.filter { $0.system !== root }
        try #require(children.count == 2)
        let first = children[0].system
        let second = children[1].system
        #expect(!first.playbackSnapshot.isEmitting && second.playbackSnapshot.isEmitting)
        tree.apply([.init(objectID: "test", command: .pause)])
        tree.tick(now: 5.6)
        tree.apply([.init(objectID: "test", command: .play)])
        #expect(!first.playbackSnapshot.isEmitting)
        #expect(second.playbackSnapshot.isEmitting)
    }

    @Test func pauseLongerThanChildLifetimeKeepsEventChildrenForPlay() throws {
        let (tree, root) = try makeTree(kind: "eventspawn")
        for frame in 0 ... 150 {
            tree.tick(now: Double(frame) / 60)
        }
        let children = tree.bindings.filter { $0.system !== root }.map(\.system)
        try #require(!children.isEmpty)
        tree.apply([.init(objectID: "test", command: .pause)])
        for frame in 151 ... 450 {
            tree.tick(now: Double(frame) / 60)
        }
        #expect(children.allSatisfy { $0.liveInstanceCount == 0 })
        tree.apply([.init(objectID: "test", command: .play)])
        for frame in 451 ... 510 {
            tree.tick(now: Double(frame) / 60)
        }
        for child in children {
            #expect(tree.bindings.contains { $0.system === child })
            #expect(child.playbackSnapshot.isEmitting)
            #expect(child.liveInstanceCount > 0)
        }
    }

    @Test func eventSlotBudgetIsObservableAndReleasedAfterStop() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func prototype(capacity: Int, burst: Int) throws -> WPEParticleSystem {
            let definition = WPEParticleDefinitionParser.parse(dictionary: [
                "maxcount": capacity, "emitter": [["name": "boxrandom", "instantaneous": burst, "rate": 0]],
                "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]],
            ])
            return try #require(WPEParticleSystem(definition: definition, device: device, seed: 29))
        }
        let parent = try prototype(capacity: 10, burst: 10)
        parent.scriptParticleObjectID = "budget"
        let root = WPEParticleTemplate(parent)
        root.children = try [.init(reference: .init(relativePath: "bounded", type: "eventspawn"),
                                   template: WPEParticleTemplate(prototype(capacity: WPEParticleSystem.absoluteCap, burst: 1)))]
        let tree = WPEParticleInstanceCoordinator(templates: [root], device: device, seed: 40)
        tree.tick(now: 0)
        #expect(tree.bindings.count == 9)
        #expect(tree.createdEventInstances == 8)
        #expect(tree.rejectedEventInstances == 2)
        #expect(tree.eventInstanceCount == 8)
        tree.apply([.init(objectID: "budget", command: .stop)])
        #expect(tree.bindings.count == 1)
        #expect(tree.releasedEventInstances == 8)
        #expect(tree.eventInstanceCount == 0)
        tree.apply([.init(objectID: "budget", command: .play)])
        tree.tick(now: 0.01)
        #expect(tree.bindings.count == 9)
        #expect(tree.createdEventInstances == 16)
        #expect(tree.rejectedEventInstances == 4)
        #expect(tree.releasedEventInstances == 8)
        #expect(tree.eventInstanceCount == 8)
    }

    @Test("Repeated event-tree churn stays bounded and matches fresh non-pooled instances",
          arguments: ["eventspawn", "eventdeath", "eventfollow"])
    func repeatedEventTreeChurn(kind: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEParticleCPUStoragePool(maximumRetainedBytes: 1024 * 1024)
        func make(pool: WPEParticleCPUStoragePool?) throws -> WPEParticleInstanceCoordinator {
            func prototype(capacity: Int, burst: Int, lifetime: Double) throws -> WPEParticleSystem {
                let definition = WPEParticleDefinitionParser.parse(dictionary: [
                    "maxcount": capacity,
                    "emitter": [["name": "boxrandom", "instantaneous": burst, "rate": 0]],
                    "initializer": [["name": "lifetimerandom", "min": lifetime, "max": lifetime],
                                    ["name": "velocityrandom", "min": "-2 -1 0", "max": "3 2 0"]],
                    "renderer": [["name": "sprite"]],
                ])
                return try #require(WPEParticleSystem(definition: definition, device: device, seed: 44,
                                                      usesFrameArena: true, cpuStoragePool: pool))
            }
            let parent = try prototype(capacity: 32, burst: 32, lifetime: 0.1)
            parent.scriptParticleObjectID = "churn"
            let root = WPEParticleTemplate(parent)
            let child = try WPEParticleTemplate(prototype(capacity: 32, burst: 3, lifetime: 0.16))
            let descendant = try WPEParticleTemplate(prototype(capacity: 16, burst: 2, lifetime: 0.2))
            child.children = [.init(reference: .init(relativePath: "static"), template: descendant)]
            root.children = [.init(reference: .init(relativePath: "event", type: kind), template: child)]
            return WPEParticleInstanceCoordinator(templates: [root], device: device, seed: 63)
        }
        let pooled = try make(pool: pool)
        let fresh = try make(pool: nil)
        let pooledArena = WPEParticleFrameArena(device: device)
        let freshArena = WPEParticleFrameArena(device: device)
        var held: WPEParticleSystem?
        weak var releasedInstance: WPEParticleSystem?
        var heldStorage: ObjectIdentifier?
        var stableAllocations: Int?
        var peakInstances = 0
        var peakRetainedBytes = 0
        for cycle in 0 ..< 500 {
            for tree in [pooled, fresh] {
                tree.apply([.init(objectID: "churn", command: .play)])
            }
            for frame in 0 ..< 24 {
                if frame == 8 || frame == 12 {
                    let command: WPEParticlePlaybackCommand = frame == 8 ? .pause : .play
                    for tree in [pooled, fresh] {
                        tree.apply([.init(objectID: "churn", command: command)])
                    }
                }
                let now = Double(cycle * 24 + frame) / 60
                for tree in [pooled, fresh] {
                    tree.tick(now: now, shouldPrepareRenderData: { _ in false })
                }
                #expect(pooled.eventInstanceCount == fresh.eventInstanceCount)
                #expect(pooled.eventParticleSlots == fresh.eventParticleSlots)
                #expect(pooled.createdEventInstances == fresh.createdEventInstances)
                #expect(pooled.releasedEventInstances == fresh.releasedEventInstances)
                peakInstances = max(peakInstances, pooled.eventInstanceCount)
                if cycle == 0, frame == 8 {
                    held = pooled.bindings.dropFirst().first?.system
                    heldStorage = held?.cpuStorageIdentity
                    releasedInstance = held
                }
                if frame == 8 || frame == 23 {
                    let left = pooled.bindings.map(\.system)
                    let right = fresh.bindings.map(\.system)
                    try #require(left.count == right.count)
                    let slot = frame % 2
                    try #require(pooledArena.prepare(left, frameSlot: slot))
                    try #require(freshArena.prepare(right, frameSlot: slot))
                    for (a, b) in zip(left, right) {
                        #expect(a.playbackSnapshot == b.playbackSnapshot)
                        #expect(a.primaryLiveParticleIdentity == b.primaryLiveParticleIdentity)
                        #expect(a.instanceOriginOffset == b.instanceOriginOffset)
                        #expect(a.particleEventsThisTick == b.particleEventsThisTick)
                        if cycle > 0, let heldStorage {
                            #expect(a.cpuStorageIdentity != heldStorage)
                        }
                        let count = a.liveInstanceCount * MemoryLayout<WPEParticleInstance>.stride
                        if count > 0 {
                            let first = Data(bytes: a.instanceBuffer.contents().advanced(by: a.renderBufferOffset), count: count)
                            let second = Data(bytes: b.instanceBuffer.contents().advanced(by: b.renderBufferOffset), count: count)
                            #expect(first == second)
                        }
                    }
                }
            }
            for tree in [pooled, fresh] {
                tree.apply([.init(objectID: "churn", command: .stop)])
                #expect(tree.eventInstanceCount == 0 && tree.eventParticleSlots == 0)
                #expect(tree.createdEventInstances == tree.releasedEventInstances)
                #expect(tree.bindings.count == 1)
            }
            if cycle == 20 {
                withExtendedLifetime(held) {}
                held = nil
                heldStorage = nil
                #expect(releasedInstance == nil)
            }
            let stats = pool.stats
            peakRetainedBytes = max(peakRetainedBytes, stats.retainedBytes)
            #expect(stats.retainedBytes <= pool.maximumRetainedBytes)
            if cycle == 30 {
                stableAllocations = stats.allocations
            } else if cycle > 30 {
                #expect(stats.allocations == stableAllocations)
            }
        }
        #expect(pooled.createdEventInstances >= 32000)
        #expect(pool.stats.reuses > 30000)
        #expect(peakInstances > 0 && peakInstances <= WPEParticleInstanceCoordinator.maximumEventInstances)
        print("[particle-churn] kind=\(kind) cycles=500 frames=12000 created=\(pooled.createdEventInstances) "
            + "allocations=\(pool.stats.allocations) reuses=\(pool.stats.reuses) "
            + "peakInstances=\(peakInstances) peakRetainedPayload=\(peakRetainedBytes)")
        pool.trim()
        #expect(pool.stats.retainedBytes == 0 && pool.stats.retainedStorages == 0)
        #expect(pooled.bindings.first?.system.liveInstanceCount == 0)
    }

    private func makeTree(kind: String, maximum: Int = 2, probability: Double = 1) throws
        -> (WPEParticleInstanceCoordinator, WPEParticleSystem) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func system(rate: Double, lifetime: Double, velocity: String, duration: Double) throws -> WPEParticleSystem {
            let definition = WPEParticleDefinitionParser.parse(dictionary: [
                "maxcount": 32, "starttime": 0,
                "emitter": [["name": "boxrandom", "rate": rate, "instantaneous": 0, "duration": duration]],
                "initializer": [["name": "lifetimerandom", "min": lifetime, "max": lifetime],
                                ["name": "velocityrandom", "min": velocity, "max": velocity]],
            ])
            return try #require(WPEParticleSystem(definition: definition, device: device, seed: 44))
        }
        let parent = try system(rate: 0.5, lifetime: 3, velocity: "16 0 0", duration: 4.1)
        parent.scriptParticleObjectID = "test"
        let root = WPEParticleTemplate(parent)
        let child = try WPEParticleTemplate(system(rate: 2, lifetime: 2, velocity: "0 8 0", duration: 0))
        child.prototype.scriptParticleObjectID = "test"
        root.children = [.init(reference: .init(relativePath: "child.json", type: kind,
                                                maxCount: maximum, probability: probability), template: child)]
        return (WPEParticleInstanceCoordinator(templates: [root], device: device, seed: 63), parent)
    }
}
#endif
