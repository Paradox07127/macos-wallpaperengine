#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Commands are values crossing the script/render boundary, never simulator references.
enum WPEParticlePlaybackCommand: Sendable, Equatable {
    case play, pause, stop
    case emit(Int)
    case modify(WPEParticleInstanceMutation)
}

struct WPESceneScriptParticleCommand: Sendable, Equatable {
    let objectID: String
    let command: WPEParticlePlaybackCommand
    var emissionValues: WPEParticleInstanceValues?
}

struct WPEParticlePlaybackSnapshot: Sendable, Equatable {
    let liveParticleCount: Int
    let isEmitting: Bool
    var isPlaying: Bool {
        isEmitting || liveParticleCount > 0
    }
}

/// Owned by one VM lane. Exceptions invalidate the entire callback's command batch.
/// No JSValue/JSContext is retained by this bridge or its cross-thread store.
final class WPESceneScriptParticleBridge {
    static let maximumCommandsPerEvaluation = 256
    private weak var shared: WPESharedScriptState?
    private var pending: [WPESceneScriptParticleCommand] = []
    private var failed = false
    private var active = false

    init(shared: WPESharedScriptState?) {
        self.shared = shared
    }

    func beginEvaluation() {
        pending.removeAll(keepingCapacity: true)
        failed = false
        active = true
    }

    func failEvaluation() {
        failed = true
    }

    func finishEvaluation(commit: Bool) {
        defer {
            pending.removeAll(keepingCapacity: true)
            active = false
        }
        guard commit, !failed, !pending.isEmpty else { return }
        shared?.enqueueParticleCommands(pending)
    }

    private func append(_ command: WPEParticlePlaybackCommand, objectID: String) {
        guard active, !failed else { return }
        guard pending.count < Self.maximumCommandsPerEvaluation else {
            failed = true
            shared?.sceneScriptLoadToken?.failClosed(.particleCommandLimitExceeded(
                limit: Self.maximumCommandsPerEvaluation
            ))
            return
        }
        let emissionValues: WPEParticleInstanceValues? = if case .emit = command {
            values(objectID: objectID)
        } else {
            nil
        }
        pending.append(.init(objectID: objectID, command: command, emissionValues: emissionValues))
    }

    private func isPlaying(objectID: String) -> Bool {
        var snapshot = shared?.particlePlaybackSnapshot(objectID: objectID)
            ?? .init(liveParticleCount: 0, isEmitting: true)
        for event in pending where event.objectID == objectID {
            switch event.command {
            case .play: snapshot = .init(liveParticleCount: snapshot.liveParticleCount, isEmitting: true)
            case .pause: snapshot = .init(liveParticleCount: snapshot.liveParticleCount, isEmitting: false)
            case .stop: snapshot = .init(liveParticleCount: 0, isEmitting: false)
            case .modify: break
            case let .emit(count): snapshot = .init(liveParticleCount: max(snapshot.liveParticleCount, count), isEmitting: snapshot.isEmitting)
            }
        }
        return snapshot.isPlaying
    }

    private func values(objectID: String) -> WPEParticleInstanceValues {
        var values = shared?.particleInstanceValues(objectID: objectID) ?? .init()
        for event in pending where event.objectID == objectID {
            if case let .modify(mutation) = event.command {
                values.apply(mutation)
            }
        }
        return values
    }

    private func liveVector(property: WPEParticleInstanceProperty, objectID: String, in context: JSContext) -> JSValue? {
        let value = values(objectID: objectID).value(for: property)
        guard let vector = context.objectForKeyedSubscript("Vec3")?.construct(withArguments: [value.x, value.y, value.z]),
              let object = context.objectForKeyedSubscript("Object"),
              let define = object.objectForKeyedSubscript("defineProperty") else { return nil }
        for (index, component) in ["x", "y", "z"].enumerated() {
            let get: @convention(block) () -> Double = { [weak self] in
                self?.values(objectID: objectID).value(for: property)[index] ?? 0
            }
            let set: @convention(block) (JSValue) -> Void = { [weak self, weak context] raw in
                guard let self else { return }
                guard Self.isFloatFinite(raw) else {
                    failEvaluation()
                    if let context {
                        context.exception = JSValue(newErrorFromMessage: "Particle instance vector component must be finite", in: context)
                    }
                    return
                }
                var current = values(objectID: objectID).value(for: property)
                current[index] = raw.toDouble()
                append(.modify(.init(property: property, value: current)), objectID: objectID)
            }
            guard let descriptor = JSValue(newObjectIn: context) else { continue }
            descriptor.setObject(get, forKeyedSubscript: "get" as NSString)
            descriptor.setObject(set, forKeyedSubscript: "set" as NSString)
            descriptor.setObject(true, forKeyedSubscript: "enumerable" as NSString)
            descriptor.setObject(true, forKeyedSubscript: "configurable" as NSString)
            define.call(withArguments: [vector, component, descriptor])
        }
        return vector
    }

    /// The simulation consumes instance values as Float; a Double-finite write can still become inf there.
    private static func isFloatFinite(_ raw: JSValue?) -> Bool {
        guard let raw, raw.isNumber else { return false }
        return Float(raw.toDouble()).isFinite
    }

    private func installInstance(on handle: JSValue, objectID: String, in context: JSContext) {
        guard let instance = JSValue(newObjectIn: context),
              let object = context.objectForKeyedSubscript("Object"),
              let define = object.objectForKeyedSubscript("defineProperty") else { return }
        for property in WPEParticleInstanceProperty.allCases {
            let get: @convention(block) () -> JSValue? = { [weak self, weak context] in
                guard let self, let context else { return nil }
                let value = values(objectID: objectID).value(for: property)
                if !property.isVector {
                    return JSValue(double: value.x, in: context)
                }
                return liveVector(property: property, objectID: objectID, in: context)
            }
            let set: @convention(block) (JSValue) -> Void = { [weak self, weak context] raw in
                guard let self else { return }
                let value: SIMD3<Double>
                if property.isVector {
                    let components = ["x", "y", "z"].map { raw.objectForKeyedSubscript($0) }
                    guard components.allSatisfy(Self.isFloatFinite) else {
                        failEvaluation()
                        if let context {
                            context.exception = JSValue(newErrorFromMessage: "Particle instance vector requires finite x, y, z", in: context)
                        }
                        return
                    }
                    value = SIMD3(components[0]!.toDouble(), components[1]!.toDouble(), components[2]!.toDouble())
                } else {
                    guard Self.isFloatFinite(raw) else {
                        failEvaluation()
                        if let context {
                            context.exception = JSValue(newErrorFromMessage: "Particle instance scalar requires a finite number", in: context)
                        }
                        return
                    }
                    value = SIMD3(repeating: raw.toDouble())
                }
                append(.modify(.init(property: property, value: value)), objectID: objectID)
            }
            guard let descriptor = JSValue(newObjectIn: context) else { continue }
            descriptor.setObject(get, forKeyedSubscript: "get" as NSString)
            descriptor.setObject(set, forKeyedSubscript: "set" as NSString)
            descriptor.setObject(true, forKeyedSubscript: "enumerable" as NSString)
            define.call(withArguments: [instance, property.rawValue, descriptor])
        }
        handle.setObject(instance, forKeyedSubscript: "instance" as NSString)
    }

    func install(on handle: JSValue, objectID: String, in context: JSContext) {
        installInstance(on: handle, objectID: objectID, in: context)
        for (method, command) in [("play", WPEParticlePlaybackCommand.play), ("pause", .pause), ("stop", .stop)] {
            let block: @convention(block) () -> Void = { [weak self] in
                self?.append(command, objectID: objectID)
            }
            handle.setObject(block, forKeyedSubscript: method as NSString)
        }
        let playing: @convention(block) () -> Bool = { [weak self] in
            self?.isPlaying(objectID: objectID) ?? false
        }
        handle.setObject(playing, forKeyedSubscript: "isPlaying" as NSString)
        let emit: @convention(block) (JSValue) -> Void = { [weak self, weak context] value in
            guard let self else { return }
            guard value.isNumber, value.toDouble().isFinite, value.toDouble() >= 0,
                  value.toDouble().rounded(.towardZero) == value.toDouble() else {
                failEvaluation()
                // The official SDK does not specify the omitted-count default.
                // Keep that unsupported input visible instead of fabricating a burst.
                if let context {
                    context.exception = JSValue(newErrorFromMessage: "emitParticles requires an explicit non-negative integer count", in: context)
                }
                return
            }
            append(.emit(Int(min(value.toDouble(), Double(WPEParticleSystem.absoluteCap)))), objectID: objectID)
        }
        handle.setObject(emit, forKeyedSubscript: "emitParticles" as NSString)
    }
}
#endif
