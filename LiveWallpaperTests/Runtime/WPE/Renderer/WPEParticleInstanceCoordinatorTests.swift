#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Windows-backed independent particle child instances")
struct WPEParticleInstanceCoordinatorTests {
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

    @Test func eventSlotBudgetIsObservableAndReleasedAfterStop() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func prototype(capacity: Int, burst: Int) throws -> WPEParticleSystem {
            let definition = try #require(WPEParticleDefinitionParser.parse(dictionary: [
                "maxcount": capacity, "emitter": [["name": "boxrandom", "instantaneous": burst, "rate": 0]],
                "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]],
            ]))
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
        tree.apply([.init(objectID: "budget", command: .stop)])
        #expect(tree.bindings.count == 1)
        tree.apply([.init(objectID: "budget", command: .play)])
        tree.tick(now: 0.01)
        #expect(tree.bindings.count == 9)
    }

    private func makeTree(kind: String, maximum: Int = 2, probability: Double = 1) throws
        -> (WPEParticleInstanceCoordinator, WPEParticleSystem) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func system(rate: Double, lifetime: Double, velocity: String, duration: Double) throws -> WPEParticleSystem {
            let definition = try #require(WPEParticleDefinitionParser.parse(dictionary: [
                "maxcount": 32, "starttime": 0,
                "emitter": [["name": "boxrandom", "rate": rate, "instantaneous": 0, "duration": duration]],
                "initializer": [["name": "lifetimerandom", "min": lifetime, "max": lifetime],
                                ["name": "velocityrandom", "min": velocity, "max": velocity]],
            ]))
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
