#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperProWPE

/// Linked property tracks share one clock. Only script-controlled clocks need
/// alpha overlays; ordinary tracks retain the existing uniform sampling path.
final class WPESceneTimelineStore: @unchecked Sendable {
    private struct Key: Hashable {
        let objectID: String
        let property: String
    }

    private struct Clock {
        var anchorTime: Double = 0
        var anchorSeconds: Double = 0
        var rate: Double = 1
        var paused = false
        var controlled = false

        func seconds(at time: Double) -> Double {
            max(0, anchorSeconds + (paused ? 0 : max(0, time - anchorTime) * rate))
        }
    }

    private let lock = NSLock()
    private var tracks: [Key: WPESceneAnimatedValue] = [:]
    private var roots: [Key: Key] = [:]
    private var clocks: [Key: Clock] = [:]
    private var time: Double = 0
    private var token: WPESceneScriptInstanceLimitToken?

    func configure(document: WPESceneDocument, token: WPESceneScriptInstanceLimitToken? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
        tracks = [:]
        roots = [:]
        clocks = [:]
        time = 0
        for image in document.imageObjects {
            tracks[Key(objectID: image.id, property: "alpha")] = image.alphaAnimation
            tracks[Key(objectID: image.id, property: "origin")] = image.originAnimation
        }
        for host in document.transformHostObjects {
            tracks[Key(objectID: host.id, property: "origin")] = host.originAnimation
        }
        for key in tracks.keys {
            var root = key
            var visited: Set<Key> = [key]
            while let parent = tracks[root]?.parentKey {
                let next = Key(objectID: key.objectID, property: parent)
                guard tracks[next] != nil, visited.insert(next).inserted else { break }
                root = next
            }
            roots[key] = root
            var clock = Clock()
            if case .value(true)? = tracks[root]?.animation.startPaused {
                clock.paused = true
            }
            clocks[root] = clock
        }
    }

    func publishTime(_ time: Double) {
        guard time.isFinite else { return }
        lock.lock()
        self.time = max(self.time, time)
        lock.unlock()
    }

    func seconds(objectID: String, property: String, at time: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(objectID: objectID, property: property)
        return roots[key].flatMap { clocks[$0]?.seconds(at: time) } ?? time
    }

    func alphaOverrides(at time: Double) -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: Double] = [:]
        for (key, track) in tracks where key.property == "alpha" {
            guard let root = roots[key], let clock = clocks[root], clock.controlled,
                  let alpha = track.scalar(at: clock.seconds(at: time)) else { continue }
            result[key.objectID] = min(max(alpha, 0), 1)
        }
        return result
    }

    func property(objectID: String, name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let available = tracks.keys.filter { $0.objectID == objectID }.sorted { $0.property < $1.property }
        if !name.isEmpty {
            return available.first { key in
                if key.property == name {
                    return true
                }
                if case let .value(authoredName)? = tracks[key]?.animation.name {
                    return authoredName == name
                }
                return false
            }?.property
        }
        return available.first(where: { roots[$0] == $0 })?.property ?? available.first?.property
    }

    func read(objectID: String, property: String, field: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(objectID: objectID, property: property)
        guard let root = roots[key], let clock = clocks[root], let track = tracks[key] else { return 0 }
        switch field {
        case "rate": return clock.rate
        case "frame": return track.animation.frame(at: clock.seconds(at: time))
        default: return 0
        }
    }

    func command(objectID: String, property: String, operation: String, value: Double) {
        guard value.isFinite else { return }
        let mutate = {
            self.lock.lock()
            defer { self.lock.unlock() }
            let key = Key(objectID: objectID, property: property)
            guard let root = self.roots[key], var clock = self.clocks[root], let track = self.tracks[key] else { return }
            let seconds = clock.seconds(at: self.time)
            switch operation {
            case "rate":
                guard clock.rate != value else { return }
                clock.rate = value
            case "play": clock.paused = false
            case "pause": clock.paused = true
            case "stop": clock.paused = true
            case "frame": break
            default: return
            }
            clock.anchorTime = self.time
            clock.anchorSeconds = operation == "frame" ? max(0, value) / track.animation.fps
                : operation == "stop" ? 0 : seconds
            clock.controlled = true
            self.clocks[root] = clock
        }
        if let token {
            _ = token.withCompletionPermission(mutate)
        } else {
            mutate()
        }
    }
}

/// Both layer and transform VMs use the same host clock. JS handles and their
/// identity cache stay inside their owning context, never in the shared store.
func wpeInstallTimelineAnimation(
    on handle: JSValue, objectID: String, shared: WPESharedScriptState?, in context: JSContext
) {
    guard let store = shared?.timelineAnimations else { return }
    let resolve: @convention(block) (String) -> String? = { [weak store] name in
        store?.property(objectID: objectID, name: name)
    }
    let read: @convention(block) (String, String) -> Double = { [weak store] property, field in
        store?.read(objectID: objectID, property: property, field: field) ?? 0
    }
    let command: @convention(block) (String, String, Double) -> Void = { [weak store] property, operation, value in
        store?.command(objectID: objectID, property: property, operation: operation, value: value)
    }
    let factory = context.evaluateScript("""
    (function(resolve, read, command) {
        const handles = Object.create(null);
        return function(name) {
            const key = resolve(typeof name === 'string' ? name : '');
            if (key == null) return undefined;
            if (handles[key]) return handles[key];
            const animation = {
                play: function() { command(key, 'play', 0); },
                pause: function() { command(key, 'pause', 0); },
                stop: function() { command(key, 'stop', 0); },
                setFrame: function(frame) { command(key, 'frame', Number(frame)); },
                getFrame: function() { return read(key, 'frame'); }
            };
            Object.defineProperty(animation, 'rate', {
                get: function() { return read(key, 'rate'); },
                set: function(value) { command(key, 'rate', Number(value)); }
            });
            handles[key] = animation;
            return animation;
        };
    })
    """)
    if let getAnimation = factory?.call(withArguments: [resolve, read, command]) {
        handle.setObject(getAnimation, forKeyedSubscript: "getAnimation" as NSString)
    }
}
#endif
