#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

/// A loaded definition/material prototype is shared; every trigger owns its pool,
/// clock and descendant relationships. Prototypes never serve as event instances.
final class WPEParticleTemplate {
    struct Child {
        let reference: WPEParticleChildReference
        let template: WPEParticleTemplate
    }

    let prototype: WPEParticleSystem
    var children: [Child] = []

    init(_ prototype: WPEParticleSystem) {
        self.prototype = prototype
    }
}

final class WPEParticleInstanceCoordinator {
    struct Binding {
        let system: WPEParticleSystem
        let prototype: WPEParticleSystem
    }

    private final class Instance {
        let system: WPEParticleSystem
        let template: WPEParticleTemplate
        let referenceIndex: Int?
        weak var parent: Instance?
        var followedParticle: WPEParticleIdentity?
        var followsParent = false
        var emissionEndedWithParent = false
        var children: [Instance] = []
        var childCounts: [Int]

        init(system: WPEParticleSystem, template: WPEParticleTemplate,
             parent: Instance? = nil, referenceIndex: Int? = nil) {
            self.system = system
            self.template = template
            self.parent = parent
            self.referenceIndex = referenceIndex
            childCounts = .init(repeating: 0, count: template.children.count)
            if template.children.contains(where: \.reference.rollsProbabilityPerEvent) {
                system.beginRecordingParticleEvents()
            }
        }

        func appendChild(_ child: Instance) {
            children.append(child)
            childCounts[child.referenceIndex!] += 1
        }
    }

    /// Event pools are bounded separately from the existing authored root pools.
    /// The slot budget covers CPU particles and in-flight GPU buffers.
    static let maximumEventInstances = 1024
    static let maximumEventParticleSlots = 65536
    private let device: MTLDevice
    private var roots: [Instance] = []
    private(set) var eventInstanceCount = 0
    private(set) var eventParticleSlots = 0
    private(set) var createdEventInstances = 0
    private(set) var releasedEventInstances = 0
    private(set) var rejectedEventInstances = 0
    private var creationOrdinal: UInt64 = 0
    private var random: SplitMix64
    private var previousTime: Double?
    private var previousInterval: Double = 0
    private var cachedBindings: [Binding]?
    private(set) var bindingRevision: UInt64 = 0

    init(templates: [WPEParticleTemplate], device: MTLDevice, seed: UInt64) {
        self.device = device
        random = SplitMix64(seed: seed)
        for template in templates {
            let root = Instance(system: template.prototype, template: template)
            roots.append(root)
            addStaticChildren(to: root, reusePrototypes: true)
        }
    }

    var bindings: [Binding] {
        if let cachedBindings {
            return cachedBindings
        }
        var result: [Binding] = []
        func append(_ instance: Instance) {
            result.append(.init(system: instance.system, prototype: instance.template.prototype))
            for child in instance.children {
                append(child)
            }
        }
        for root in roots {
            append(root)
        }
        cachedBindings = result
        return result
    }

    var liveParticleCount: Int {
        func count(_ instance: Instance) -> Int {
            instance.children.reduce(instance.system.liveParticleCount) { $0 + count($1) }
        }
        return roots.reduce(0) { $0 + count($1) }
    }

    /// One substep clock for the entire tree. A follower sees its own parent's
    /// same-substep position, including a terminal death snapshot, before ticking.
    func tick(now: Double, frameSlot: Int = 0, configure: (WPEParticleSystem) -> Void = { _ in }) {
        tick(now: now, frameSlot: frameSlot, shouldPrepareRenderData: { _ in true }, configure: configure)
    }

    func tick(now: Double, frameSlot: Int = 0,
              shouldPrepareRenderData: (WPEParticleSystem) -> Bool,
              configure: (WPEParticleSystem) -> Void = { _ in }) {
        guard now.isFinite else { return }
        let raw = max(0, now - (previousTime ?? now))
        let delta = min(raw, max(0.1, 2 * previousInterval))
        previousTime = now
        previousInterval = delta
        let steps = max(1, Int(ceil(delta * 60 - 1e-6)))
        for index in 0 ..< steps {
            let time = now - delta + Double(index + 1) * delta / Double(steps)
            for root in roots {
                advance(root, now: time, configure: configure)
            }
        }
        for binding in bindings where shouldPrepareRenderData(binding.system) {
            binding.system.prepareRenderData(frameSlot: frameSlot)
        }
    }

    func prewarm(secondsByRoot: [ObjectIdentifier: Double], step: Double = 1.0 / 60) {
        guard step > 0, let longest = secondsByRoot.values.max(), longest > 0 else { return }
        for root in roots {
            let seconds = max(0, secondsByRoot[ObjectIdentifier(root.system)] ?? 0)
            preparePrewarm(root, start: -seconds)
        }
        for index in 0 ... Int(ceil(longest / step)) {
            let now = min(0, -longest + Double(index) * step)
            for root in roots {
                let seconds = max(0, secondsByRoot[ObjectIdentifier(root.system)] ?? 0)
                guard now >= -seconds else { continue }
                advance(root, now: now, configure: { _ in })
            }
        }
        for binding in bindings {
            if !binding.system.usesFrameArena {
                binding.system.prepareRenderData()
            }
            binding.system.finishInstancePrewarm()
        }
        previousTime = 0
        previousInterval = step
    }

    private func preparePrewarm(_ instance: Instance, start: Double) {
        instance.system.anchorInstanceClock(at: start, presimulateDelay: true)
        for child in instance.children {
            preparePrewarm(child, start: start)
        }
    }

    private func advance(_ instance: Instance, now: Double,
                         configure: (WPEParticleSystem) -> Void) {
        let system = instance.system
        if let parent = instance.parent {
            if instance.followsParent, let identity = instance.followedParticle {
                if let snapshot = parent.system.snapshot(for: identity) {
                    system.instanceOriginOffset = snapshot.position + parent.system.instanceOriginOffset
                        - parent.system.sceneTransform.renderOrigin
                } else {
                    if let death = parent.system.particleEventsThisTick.first(where: {
                        $0.kind == .death && $0.particle.identity == identity
                    }) {
                        system.instanceOriginOffset = death.particle.position + parent.system.instanceOriginOffset
                            - parent.system.sceneTransform.renderOrigin
                    }
                    pauseSubtree(instance)
                    instance.emissionEndedWithParent = true
                    instance.followsParent = false
                    instance.followedParticle = nil
                }
            } else if instance.referenceIndex.map({
                !parent.template.children[$0].reference.rollsProbabilityPerEvent
            }) == true {
                system.instanceOriginOffset = parent.system.instanceOriginOffset
            }
        }
        if let parent = instance.parent, let referenceIndex = instance.referenceIndex {
            let reference = parent.template.children[referenceIndex].reference
            if reference.setsParentParticleControlPoints {
                let start = reference.controlPointStartIndex ?? 0
                if (0 ... 7).contains(start) {
                    for (index, position) in parent.system.liveControlPointSourcePositions(limit: 8 - start).enumerated() {
                        system.injectedControlPoints[start + index] = system.sceneTransform.applyModelMatrix(toLocalPoint: position)
                    }
                }
            }
        }
        configure(system)
        system.advanceSimulation(now: now)
        for event in system.particleEventsThisTick {
            for (index, child) in instance.template.children.enumerated() {
                let kind = child.reference.eventKind
                let triggered = event.kind == .spawn && (kind == .spawn || kind == .follow)
                    || event.kind == .death && kind == .death
                guard triggered, allowsCreation(child.reference, parent: instance, index: index) else { continue }
                guard let created = makeChild(child, parent: instance, index: index) else { continue }
                created.system.instanceOriginOffset = event.particle.position + system.instanceOriginOffset
                    - system.sceneTransform.renderOrigin
                if kind == .follow {
                    created.followedParticle = event.particle.identity
                    created.followsParent = true
                }
                // Establish this instance's own birth clock, not the scene clock.
                created.system.anchorInstanceClock(at: event.simulationTime)
                instance.appendChild(created)
                addStaticChildren(to: created, reusePrototypes: false)
            }
        }
        for child in instance.children {
            advance(child, now: now, configure: configure)
        }
        instance.children.removeAll { child in
            let reference = instance.template.children[child.referenceIndex!].reference
            guard reference.rollsProbabilityPerEvent, subtreeIsIdle(child) else { return false }
            instance.childCounts[child.referenceIndex!] -= 1
            release(child)
            return true
        }
    }

    private func allowsCreation(_ reference: WPEParticleChildReference, parent: Instance, index: Int) -> Bool {
        if let maximum = reference.maxCount,
           parent.childCounts[index] >= max(0, maximum) {
            return false
        }
        return reference.probability > 0 && (reference.probability >= 1 || Double.random(in: 0 ..< 1, using: &random) < reference.probability)
    }

    private func makeChild(_ child: WPEParticleTemplate.Child, parent: Instance, index: Int) -> Instance? {
        let prototype = child.template.prototype
        guard eventInstanceCount < Self.maximumEventInstances,
              prototype.capacity <= Self.maximumEventParticleSlots - eventParticleSlots else {
            rejectedEventInstances += 1
            return nil
        }
        creationOrdinal &+= 1
        guard let system = prototype.makeEventInstance(device: device, seed: random.next() ^ creationOrdinal) else {
            return nil
        }
        eventInstanceCount += 1
        eventParticleSlots += system.capacity
        createdEventInstances += 1
        invalidateBindings()
        return Instance(system: system, template: child.template, parent: parent, referenceIndex: index)
    }

    private func addStaticChildren(to parent: Instance, reusePrototypes: Bool) {
        for (index, child) in parent.template.children.enumerated() where !child.reference.rollsProbabilityPerEvent {
            guard allowsCreation(child.reference, parent: parent, index: index) else { continue }
            let instance: Instance? = if reusePrototypes {
                Instance(system: child.template.prototype, template: child.template,
                         parent: parent, referenceIndex: index)
            } else {
                makeChild(child, parent: parent, index: index)
            }
            guard let instance else { continue }
            instance.system.instanceOriginOffset = parent.system.instanceOriginOffset
            parent.appendChild(instance)
            addStaticChildren(to: instance, reusePrototypes: reusePrototypes)
        }
    }

    /// A script pause is resumable, so it is not idle; a subtree whose follow parent died stays paused forever and is.
    private func subtreeIsIdle(_ instance: Instance, emissionEnded: Bool = false) -> Bool {
        let ended = emissionEnded || instance.emissionEndedWithParent
        return instance.system.isPermanentlyIdle && (ended || !instance.system.isPaused)
            && instance.children.allSatisfy { subtreeIsIdle($0, emissionEnded: ended) }
    }

    private func resumeSubtree(_ instance: Instance) {
        guard !instance.emissionEndedWithParent else { return }
        instance.system.applyPlaybackCommand(.play)
        for child in instance.children {
            resumeSubtree(child)
        }
    }

    private func pauseSubtree(_ instance: Instance) {
        instance.system.applyPlaybackCommand(.pause)
        for child in instance.children {
            pauseSubtree(child)
        }
    }

    private func release(_ instance: Instance) {
        invalidateBindings()
        for child in instance.children {
            release(child)
        }
        if instance.system !== instance.template.prototype {
            eventInstanceCount -= 1
            releasedEventInstances += 1
            eventParticleSlots -= instance.system.capacity
        }
    }

    private func invalidateBindings() {
        cachedBindings = nil
        bindingRevision &+= 1
    }

    func apply(_ commands: [WPESceneScriptParticleCommand]) {
        for event in commands {
            for root in roots where root.system.scriptParticleObjectID == event.objectID {
                switch event.command {
                case .stop:
                    root.system.applyPlaybackCommand(.stop)
                    for child in root.children {
                        release(child)
                    }
                    root.children.removeAll()
                    root.childCounts = .init(repeating: 0, count: root.template.children.count)
                case .play:
                    resumeSubtree(root)
                    if root.children.isEmpty {
                        addStaticChildren(to: root, reusePrototypes: false)
                    }
                case .pause: pauseSubtree(root)
                case let .emit(count):
                    root.system.requestEmission(count, values: event.emissionValues ?? root.system.instanceValues)
                case .modify:
                    func updateTemplate(_ template: WPEParticleTemplate) {
                        template.prototype.applyPlaybackCommand(event.command)
                        for child in template.children {
                            updateTemplate(child.template)
                        }
                    }
                    updateTemplate(root.template)
                    for binding in bindings where binding.system.scriptParticleObjectID == event.objectID
                        && binding.system !== binding.prototype {
                        binding.system.applyPlaybackCommand(event.command)
                    }
                }
            }
        }
    }
}
#endif
