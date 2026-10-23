/// SceneScript ITextureAnimation of one image layer's sprite sheet (1401fa2a0-1401fa4a0). Joined, the layer shows
/// the texture's shared frame; individual, its own `frame` and `time`. `shared` is that texture's frame and seconds
/// into it at the current scene clock.
public struct WPEParityTextureAnimation: Sendable {
    public private(set) var individual = false
    public private(set) var playing = true
    public private(set) var rate: Float = 1
    /// Unclamped, as setFrame stores it; a step outside the sheet starts from frame 0's duration.
    public private(set) var frame = 0
    /// Seconds into `frame`.
    public private(set) var time: Float = 0

    public init() {}

    public var isPlaying: Bool {
        !individual || playing
    }

    public mutating func play() {
        playing = true
    }

    public mutating func pause(shared: (frame: Int, time: Float)) {
        if !individual {
            (frame, time) = shared
        }
        playing = false
        individual = true
    }

    public mutating func stop() {
        (frame, time) = (0, 0)
        playing = false
        individual = true
    }

    public mutating func setFrame(_ frame: Int) {
        (self.frame, time) = (frame, 0)
        if !individual {
            individual = true
            playing = true
        }
    }

    public func frame(shared: Int) -> Int {
        individual ? frame : shared
    }

    public mutating func join() {
        individual = false
    }

    public mutating func setRate(_ rate: Float, shared: (frame: Int, time: Float)) {
        self.rate = rate
        if rate != 1, !individual {
            (frame, time) = shared
            individual = true
        }
    }

    /// The image update's step by dt·rate (1401fdf90.c:4510-4515, 14015fdd0): at most one frame per call, the
    /// carried time clamped into the new frame. `durations` holds each sheet frame's seconds.
    public mutating func step(dt: Float, durations: [Float]) {
        guard individual, playing, !durations.isEmpty else { return }
        let delta = dt * rate
        func duration(_ index: Int) -> Float {
            durations.indices.contains(index) ? durations[index] : durations[0]
        }
        if delta > 0 {
            time += delta
            let current = duration(frame)
            guard time >= current else { return }
            // An unsigned compare: a negative frame + 1 also wraps to 0.
            frame = durations.indices.contains(frame + 1) ? frame + 1 : 0
            time = min(time - current, durations[frame])
        } else if delta < 0 {
            time += delta
            guard time <= 0 else { return }
            frame = frame - 1 < 0 ? durations.count - 1 : frame - 1
            time = max(time + duration(frame), 0)
        }
    }

    /// One script call; `value` is setFrame's frame or the rate written. Returns isPlaying as 1/0, a getter's
    /// value, 0 otherwise.
    public mutating func perform(_ command: WPEParityScriptEngine.TextureAnimationCommand, value: Double,
                                 shared: (frame: Int, time: Float), durations: [Float]) -> Double {
        switch command {
        case .play: play()
        case .pause: pause(shared: shared)
        case .stop: stop()
        case .isPlaying: return isPlaying ? 1 : 0
        case .getFrame: return Double(frame(shared: shared.frame))
        // A frame outside Int32 is ignored; `frame + 1` stepping must not overflow.
        case .setFrame:
            if let frame = WPEAuthoredInteger.truncated(value, as: Int32.self) {
                setFrame(Int(frame))
            }
        case .join: join()
        case .getRate: return Double(rate)
        case .setRate: setRate(Float(value), shared: shared)
        case .frameCount: return Double(durations.count)
        case .duration: return Double(durations.reduce(0, +))
        }
        return 0
    }
}
