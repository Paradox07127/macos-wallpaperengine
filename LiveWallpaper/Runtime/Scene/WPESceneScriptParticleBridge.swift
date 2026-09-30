#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperCore

/// Commands are values crossing the script/render boundary, never simulator references.
enum WPEParticlePlaybackCommand: Sendable, Equatable {
    case play, pause, stop
    case emit(Int)
}

struct WPESceneScriptParticleCommand: Sendable, Equatable {
    let objectID: String
    let command: WPEParticlePlaybackCommand
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
        pending.append(.init(objectID: objectID, command: command))
    }

    private func isPlaying(objectID: String) -> Bool {
        var snapshot = shared?.particlePlaybackSnapshot(objectID: objectID)
            ?? .init(liveParticleCount: 0, isEmitting: true)
        for event in pending where event.objectID == objectID {
            switch event.command {
            case .play: snapshot = .init(liveParticleCount: snapshot.liveParticleCount, isEmitting: true)
            case .pause: snapshot = .init(liveParticleCount: snapshot.liveParticleCount, isEmitting: false)
            case .stop: snapshot = .init(liveParticleCount: 0, isEmitting: false)
            case let .emit(count): snapshot = .init(liveParticleCount: max(snapshot.liveParticleCount, count), isEmitting: snapshot.isEmitting)
            }
        }
        return snapshot.isPlaying
    }

    func install(on handle: JSValue, objectID: String, in context: JSContext) {
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
