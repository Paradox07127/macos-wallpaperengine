import SwiftUI

// MARK: - Pure decision + reduction (unit-tested, no capture dependencies)

/// Field-driven audio-layer math for the Now Playing widget: the reactive
/// visuals exist only while every gate below says yes, so paused tracks,
/// reduce-motion, suspension, and silence never draw an empty spectrum.
enum NowPlayingAudioLayer {
    /// Below this every bin counts as noise floor — the whole layer hides.
    static let silenceThreshold: Float = 0.02
    /// Recent-audibility hold so inter-track gaps don't flash the layer off.
    static let audibleHold: TimeInterval = 1.0
    /// Release factor for one reference tick: attack is instant, decay keeps ~82%.
    static let releaseFactor: Float = 0.82
    /// The tick `releaseFactor` is calibrated on — the layer's 30fps timeline.
    static let referenceTickRate: Double = 30
    /// Leading bins whose mean drives the bass drive and the aurora band count.
    static let lowBandCount = 8
    /// Faded out and quiet this long: stop ticking until audio returns.
    static let idleSilence: TimeInterval = 3.0

    nonisolated static func shouldRun(
        phase: MonitorNowPlayingPhase?,
        reduceMotion: Bool,
        suspended: Bool,
        capturing: Bool,
        audioReactive: Bool
    ) -> Bool {
        phase == .playing && !reduceMotion && !suspended && capturing && audioReactive
    }

    /// 64 bins → `bands.count` bands: channels averaged, bins merged by energy
    /// mean. Callers keep `bands` allocated across ticks (fixed capacity).
    /// More bands than bins duplicates bins instead of leaving holes.
    nonisolated static func mergedBands(left: [Float], right: [Float], into bands: inout [Float]) {
        let bandCount = bands.count
        guard bandCount > 0 else { return }
        let binCount = min(left.count, right.count)
        guard binCount > 0 else {
            for index in bands.indices { bands[index] = 0 }
            return
        }
        for band in 0..<bandCount {
            let start = band * binCount / bandCount
            let end = min(max((band + 1) * binCount / bandCount, start + 1), binCount)
            var sum: Float = 0
            for bin in start..<end {
                sum += (left[bin] + right[bin]) * 0.5
            }
            bands[band] = sum / Float(end - start)
        }
    }

    /// Channel-averaged mean over a bin range, clamped to what both channels have.
    nonisolated static func meanEnergy(left: [Float], right: [Float], in range: Range<Int>) -> Float {
        let upper = min(min(left.count, right.count), range.upperBound)
        let lower = max(0, range.lowerBound)
        guard upper > lower else { return 0 }
        var sum: Float = 0
        for bin in lower..<upper {
            sum += (left[bin] + right[bin]) * 0.5
        }
        return sum / Float(upper - lower)
    }

    /// Mean of the first `lowBandCount` merged-channel bins (0…1).
    nonisolated static func lowBandEnergy(left: [Float], right: [Float]) -> Float {
        meanEnergy(left: left, right: right, in: 0..<lowBandCount)
    }

    /// The three instantaneous drives. Split by bin fraction, so at the shipped
    /// 64-bin frame these are bins 0–7 (bass, the `lowBandCount` band), 8–31
    /// (mid) and 32–63 (treble).
    nonisolated static func instantDrives(
        left: [Float], right: [Float]
    ) -> (bass: Float, mid: Float, treb: Float) {
        let count = min(left.count, right.count)
        guard count > 0 else { return (0, 0, 0) }
        let bassEnd = max(1, min(lowBandCount, count))
        let midEnd = max(bassEnd, count / 2)
        return (
            lowBandEnergy(left: left, right: right),
            meanEnergy(left: left, right: right, in: bassEnd..<midEnd),
            meanEnergy(left: left, right: right, in: midEnd..<count)
        )
    }

    /// Any bin at or above the noise floor counts as signal.
    nonisolated static func isAudible(left: [Float], right: [Float]) -> Bool {
        left.contains { $0 >= silenceThreshold } || right.contains { $0 >= silenceThreshold }
    }

    /// Attack-fast / release-slow envelope, normalized to the elapsed frame:
    /// `releaseFactor` is per 1/30 s, so a dropped frame must decay by that
    /// many ticks' worth or the visuals slow down exactly when the machine is
    /// busiest. A long stall is capped at 0.25 s so a resumed layer doesn't
    /// snap to zero.
    nonisolated static func smoothed(previous: Float, target: Float, dt: TimeInterval) -> Float {
        let ticks = Float(min(max(dt, 0), 0.25) * referenceTickRate)
        return max(target, previous * pow(releaseFactor, ticks))
    }

    /// Faded out and silent long enough that ticking at 30fps buys nothing.
    nonisolated static func shouldIdle(fade: Double, silentFor: TimeInterval) -> Bool {
        fade <= 0.001 && silentFor >= idleSilence
    }

    /// The six drive quantities: instant values hit on the frame they arrive
    /// (punch), the `…Att` envelopes fall slowly behind them (breath).
    struct Drives: Equatable {
        var bass: Float = 0
        var mid: Float = 0
        var treb: Float = 0
        var bassAtt: Float = 0
        var midAtt: Float = 0
        var trebAtt: Float = 0

        mutating func advance(left: [Float], right: [Float], dt: TimeInterval) {
            let instant = NowPlayingAudioLayer.instantDrives(left: left, right: right)
            bass = instant.bass
            mid = instant.mid
            treb = instant.treb
            bassAtt = NowPlayingAudioLayer.smoothed(previous: bassAtt, target: bass, dt: dt)
            midAtt = NowPlayingAudioLayer.smoothed(previous: midAtt, target: mid, dt: dt)
            trebAtt = NowPlayingAudioLayer.smoothed(previous: trebAtt, target: treb, dt: dt)
        }
    }

    /// Silence latch with hold: stays active while audible now or within the
    /// last `audibleHold` seconds, so per-frame dips don't flicker the layer.
    struct SilenceGate {
        private var lastAudible: TimeInterval?

        mutating func update(audible: Bool, now: TimeInterval) -> Bool {
            if audible {
                lastAudible = now
                return true
            }
            guard let lastAudible else { return false }
            return now - lastAudible <= NowPlayingAudioLayer.audibleHold
        }
    }

    /// Spectral-flux onset detector: a frame whose rising energy stands out
    /// from the last ~1.5 s of flux is a beat. Buffers are sized once, so a
    /// step costs arithmetic only.
    struct BeatDetector {
        /// ~1.5 s of history at the reference tick.
        static let historyCapacity = 45
        /// 240 BPM ceiling — closer onsets are the same beat's harmonics.
        static let minimumInterval: TimeInterval = 0.25
        /// Absolute floor: near-silence has a near-zero mean *and* deviation,
        /// so without this every rounding wobble clears the threshold.
        static let fluxFloor: Float = 0.15
        /// Beat brightness time constant (1 → ~0.004 over half a second).
        static let pulseDecay: TimeInterval = 0.18
        /// Below this many frames the mean/deviation are still meaningless.
        private static let warmupFrames = 8

        private var previous: [Float] = []
        private var history = [Float](repeating: 0, count: historyCapacity)
        private var filled = 0
        private var cursor = 0
        private var lastBeat: TimeInterval?

        mutating func step(bins: [Float], now: TimeInterval, sensitivity: Float) -> Bool {
            guard !bins.isEmpty else { return false }
            guard previous.count == bins.count else {
                // Own buffer, never the caller's storage: the broker keeps its
                // frame alive, so aliasing it would copy-on-write every frame.
                previous = [Float](repeating: 0, count: bins.count)
                for index in bins.indices { previous[index] = bins[index] }
                return false
            }

            var flux: Float = 0
            for index in bins.indices {
                flux += max(0, bins[index] - previous[index])
                previous[index] = bins[index]
            }

            history[cursor] = flux
            cursor = (cursor + 1) % Self.historyCapacity
            filled = min(filled + 1, Self.historyCapacity)
            guard filled >= Self.warmupFrames else { return false }

            var sum: Float = 0
            for index in 0..<filled { sum += history[index] }
            let mean = sum / Float(filled)
            var variance: Float = 0
            for index in 0..<filled {
                let delta = history[index] - mean
                variance += delta * delta
            }
            let deviation = (variance / Float(filled)).squareRoot()

            guard flux >= Self.fluxFloor, flux > mean + sensitivity * deviation else { return false }
            if let lastBeat, now - lastBeat < Self.minimumInterval { return false }
            lastBeat = now
            return true
        }

        /// 1 on the beat frame, decaying exponentially after it.
        func pulse(now: TimeInterval) -> Float {
            guard let lastBeat, now >= lastBeat else { return 0 }
            return exp(Float(-(now - lastBeat) / Self.pulseDecay))
        }
    }

    /// Fixed-capacity ripple slots: a beat claims the next slot round-robin,
    /// which overwrites the oldest ring once all four are alive.
    struct RippleSlots {
        static let capacity = 4
        static let duration: TimeInterval = 0.9

        private var starts = [TimeInterval](repeating: -.greatestFiniteMagnitude, count: capacity)
        private var next = 0

        mutating func trigger(at time: TimeInterval) {
            starts[next] = time
            next = (next + 1) % Self.capacity
        }

        /// 0…1 age of slot `index`, or nil when it is empty or already faded.
        func progress(_ index: Int, now: TimeInterval) -> Double? {
            guard index >= 0, index < Self.capacity else { return nil }
            let age = now - starts[index]
            guard age >= 0, age <= Self.duration else { return nil }
            return age / Self.duration
        }
    }

    /// Effect amplitudes. Every one is clamped to a ceiling the user's intensity
    /// dial cannot push past, so a 2× intensity still cannot shove the layer
    /// visibly out of place or blow an alpha past opaque.
    enum Effects {
        static let maxShakeOffset: CGFloat = 4
        static let maxShakeRotationDegrees: Double = 0.6
        static let maxChromaticOffset: CGFloat = 3
        static let maxPulseGain: Double = 1.4

        /// Kick displacement in points, from the instant bass.
        nonisolated static func shakeOffset(bass: Float, intensity: Double) -> CGFloat {
            CGFloat(limited(Double(bass) * 6 * intensity, to: Double(maxShakeOffset)))
        }

        /// Kick tilt in degrees (unsigned — the caller takes the sign from noise).
        nonisolated static func shakeRotation(bass: Float, intensity: Double) -> Double {
            limited(Double(bass) * 0.9 * intensity, to: maxShakeRotationDegrees)
        }

        /// RGB channel separation in points, from the instant treble.
        nonisolated static func chromaticOffset(treb: Float, intensity: Double) -> CGFloat {
            CGFloat(limited(Double(treb) * 5 * intensity, to: Double(maxChromaticOffset)))
        }

        /// Multiplier on every drawn alpha: the bass envelope breathes, the beat
        /// pulse adds the flash on the hit. Their sum stays under one ceiling.
        nonisolated static func pulseGain(bassAtt: Float, beat: Float, intensity: Double) -> Double {
            let lift = (Double(bassAtt) * 0.4 + Double(beat) * 0.15) * intensity
            return 1 + limited(lift, to: maxPulseGain - 1)
        }

        /// How many of `capacity` particles are alive at this bass level.
        nonisolated static func liveParticles(count: Int, bass: Float, intensity: Double) -> Int {
            guard count > 0 else { return 0 }
            let share = limited(0.25 + Double(bass) * 1.5 * intensity, to: 1)
            return max(1, Int((Double(count) * share).rounded()))
        }

        /// Ring alpha at `progress` through a ripple's life.
        nonisolated static func rippleAlpha(progress: Double, fade: Double, intensity: Double) -> Double {
            limited((1 - progress) * 0.45 * fade * intensity, to: 1)
        }

        /// Any drawn alpha, kept inside 0…1 whatever the dial says.
        nonisolated static func alpha(_ value: Double) -> Double { limited(value, to: 1) }

        private nonisolated static func limited(_ value: Double, to ceiling: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), ceiling)
        }
    }

    /// Deterministic wobble in −1…1. Time-seeded rather than random so every
    /// display shakes identically at the same instant instead of each drawing
    /// its own walk.
    nonisolated static func noise(_ time: TimeInterval, phase: Double) -> Double {
        let value = time + phase
        return sin(value * 12.9898) * 0.6 + sin(value * 5.233 + 1.7) * 0.4
    }
}

#if !LITE_BUILD

// MARK: - Per-tick engine (reference type: Canvas redraws mutate it without
// touching SwiftUI state, so 30fps invalidation stays inside the TimelineView)

final class NowPlayingAudioEngine {
    private(set) var bands: [Float] = []
    private(set) var drives = NowPlayingAudioLayer.Drives()
    /// 0…1 visibility envelope (0.3s ramp) driven by the silence gate.
    private(set) var fade: Double = 0
    /// 1 on a beat frame, exponentially decaying after it.
    private(set) var beatPulse: Float = 0
    private(set) var ripples = NowPlayingAudioLayer.RippleSlots()
    /// Faded out and silent for `idleSilence` — the view stops the timeline.
    private(set) var isIdle = false

    private var scratch: [Float] = []
    private var mono: [Float] = []
    private var gate = NowPlayingAudioLayer.SilenceGate()
    private var beat = NowPlayingAudioLayer.BeatDetector()
    private var lastTick: TimeInterval?
    private var silentSince: TimeInterval?

    /// One broker pull + envelope advance per Canvas redraw.
    func step(now: TimeInterval, bandCount: Int, sensitivity: Float, tracksBeat: Bool) {
        if bands.count != bandCount {
            bands = [Float](repeating: 0, count: bandCount)
            scratch = [Float](repeating: 0, count: bandCount)
        }

        let frame = SystemAudioCaptureManager.broker.snapshot()
        let dt = lastTick.map { max(0, min(0.25, now - $0)) } ?? 1 / NowPlayingAudioLayer.referenceTickRate
        lastTick = now

        NowPlayingAudioLayer.mergedBands(left: frame.left, right: frame.right, into: &scratch)
        for index in bands.indices {
            bands[index] = NowPlayingAudioLayer.smoothed(
                previous: bands[index], target: scratch[index], dt: dt
            )
        }
        drives.advance(left: frame.left, right: frame.right, dt: dt)

        if tracksBeat {
            let binCount = min(frame.left.count, frame.right.count)
            if mono.count != binCount { mono = [Float](repeating: 0, count: binCount) }
            for bin in 0..<binCount { mono[bin] = (frame.left[bin] + frame.right[bin]) * 0.5 }
            if beat.step(bins: mono, now: now, sensitivity: sensitivity) {
                ripples.trigger(at: now)
            }
            beatPulse = beat.pulse(now: now)
        } else {
            beatPulse = 0
        }

        let audible = NowPlayingAudioLayer.isAudible(left: frame.left, right: frame.right)
        let active = gate.update(audible: audible, now: now)
        if audible {
            silentSince = nil
        } else if silentSince == nil {
            silentSince = now
        }

        let target: Double = active ? 1 : 0
        let ramp = dt / 0.3
        fade = target > fade ? min(target, fade + ramp) : max(target, fade - ramp)
        isIdle = NowPlayingAudioLayer.shouldIdle(
            fade: fade, silentFor: silentSince.map { now - $0 } ?? 0
        )
    }

    /// Cheap poll used while the timeline is parked: audio back means wake up.
    func probeAudible() -> Bool {
        let frame = SystemAudioCaptureManager.broker.snapshot()
        let audible = NowPlayingAudioLayer.isAudible(left: frame.left, right: frame.right)
        if audible {
            silentSince = nil
            isIdle = false
            // The parked stretch is not a dropped frame; resume from now.
            lastTick = nil
        }
        return audible
    }
}

// MARK: - Reactive layer view (the ONLY 30fps surface in the widget)

/// Audio-reactive sublayer for the three Now Playing styles. The TimelineView
/// wraps just this view, so its 30fps ticks invalidate only the Canvas here;
/// the surrounding widget stays on the 1Hz board clock.
struct NowPlayingAudioReactiveView: View {
    enum Mode: Equatable {
        /// Poster: bottom-aligned thin spectrum bars above the progress line.
        case bars
        /// Vinyl: radial spikes outside the progress ring. `discFraction` is
        /// the platter radius as a fraction of this view's own radius.
        case radial(discFraction: CGFloat)
        /// Aurora: low-band halo breathing + drifting accent motes.
        case aurora
    }

    let mode: Mode
    let accent: Color
    let active: Bool
    let options: NowPlayingOptions

    /// Built once per parent update rather than per tick: `Gradient(colors:)`
    /// would otherwise allocate an array 30 times a second.
    private let haloGradient: Gradient

    @State private var engine = NowPlayingAudioEngine()
    @State private var idle = false

    init(mode: Mode, accent: Color, active: Bool, options: NowPlayingOptions) {
        self.mode = mode
        self.accent = accent
        self.active = active
        self.options = options
        haloGradient = Gradient(colors: [accent, accent.opacity(0)])
    }

    /// Bars were 2pt wide on a 2pt gap, which on a wallpaper viewed from a
    /// normal desk distance read as noise rather than as a meter. Wide enough
    /// to have a shape, with a gap that still separates them.
    private static let barWidth: CGFloat = 5
    private static let barSpacing: CGFloat = 4
    /// Floor so a quiet passage leaves a readable baseline instead of nothing.
    private static let barFloor: CGFloat = 2
    /// Fewer, thicker spokes for the same reason the bars got wider.
    private static let spokeCount = 32
    private static let spokeWidth: CGFloat = 3.5
    /// Per-channel offset direction for the chromatic split.
    private static let chromaticChannels: [(color: Color, direction: CGFloat)] = [
        (.red, -1), (.green, 0), (.blue, 1),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || idle)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                engine.step(
                    now: now,
                    bandCount: Self.bandCount(for: mode, width: size.width),
                    sensitivity: Float(options.beatSensitivity),
                    tracksBeat: options.effectRipple || options.effectPulse
                )
                guard engine.fade > 0.001 else { return }
                draw(in: &context, size: size, now: now)
            }
            // Read on the next body pass, so the flag flips outside the draw.
            .onChange(of: engine.isIdle) { _, value in idle = value }
        }
        .task(id: idle) { await pollWhileIdle() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// While the timeline is parked the engine stops pulling, so something has
    /// to notice audio coming back; 2Hz costs less than one 30fps frame.
    private func pollWhileIdle() async {
        guard idle else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            if engine.probeAudible() {
                idle = false
                return
            }
        }
    }

    private static func bandCount(for mode: Mode, width: CGFloat) -> Int {
        switch mode {
        case .bars:
            return max(1, min(64, Int((width + barSpacing) / (barWidth + barSpacing))))
        case .radial:
            return spokeCount
        case .aurora:
            return NowPlayingAudioLayer.lowBandCount
        }
    }

    // MARK: Effect wrapping (shake outside, chromatic split around the content)

    private func draw(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        let intensity = options.audioIntensity
        var stage = context
        if options.effectShake {
            applyShake(to: &stage, size: size, now: now, intensity: intensity)
        }

        let split = options.effectChromatic
            ? NowPlayingAudioLayer.Effects.chromaticOffset(treb: engine.drives.treb, intensity: intensity)
            : 0
        guard split > 0.2 else {
            drawScene(in: &stage, size: size, now: now, intensity: intensity)
            return
        }
        // Canvas cannot reach the text and cover above it, so the split lands on
        // this layer's own marks: three tinted passes added back together.
        for channel in Self.chromaticChannels {
            var pass = stage
            pass.blendMode = .plusLighter
            pass.addFilter(.colorMultiply(channel.color))
            pass.translateBy(x: channel.direction * split, y: 0)
            drawScene(in: &pass, size: size, now: now, intensity: intensity)
        }
    }

    private func applyShake(
        to context: inout GraphicsContext, size: CGSize, now: TimeInterval, intensity: Double
    ) {
        let amount = NowPlayingAudioLayer.Effects.shakeOffset(bass: engine.drives.bass, intensity: intensity)
        guard amount > 0.05 else { return }
        let angle = NowPlayingAudioLayer.Effects.shakeRotation(
            bass: engine.drives.bass, intensity: intensity
        ) * NowPlayingAudioLayer.noise(now, phase: 3.1)
        // Polar rather than per-axis: a diagonal jolt then still measures
        // `amount`, instead of the √2 an x/y pair would reach together.
        let direction = Double.pi * NowPlayingAudioLayer.noise(now, phase: 0)
        let reach = amount * CGFloat(NowPlayingAudioLayer.noise(now, phase: 2.3))
        context.translateBy(x: reach * CGFloat(cos(direction)), y: reach * CGFloat(sin(direction)))
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: .degrees(angle))
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
    }

    private func drawScene(
        in context: inout GraphicsContext, size: CGSize, now: TimeInterval, intensity: Double
    ) {
        let gain = options.effectPulse
            ? NowPlayingAudioLayer.Effects.pulseGain(
                bassAtt: engine.drives.bassAtt, beat: engine.beatPulse, intensity: intensity
            )
            : 1
        switch mode {
        case .bars:
            drawBars(in: &context, size: size, gain: gain)
        case .radial(let discFraction):
            drawRadial(in: &context, size: size, discFraction: discFraction, gain: gain)
        case .aurora:
            drawHalo(in: &context, size: size, gain: gain)
        }
        if options.effectParticles {
            drawParticles(in: &context, size: size, now: now, intensity: intensity, gain: gain)
        }
        if options.effectRipple {
            drawRipples(in: &context, size: size, now: now, intensity: intensity)
        }
    }

    // MARK: Per-mode marks

    private func drawBars(in context: inout GraphicsContext, size: CGSize, gain: Double) {
        var path = Path()
        var x: CGFloat = 0
        let radius = Self.barWidth / 2
        for value in engine.bands {
            let height = max(Self.barFloor, CGFloat(value) * size.height)
            path.addRoundedRect(
                in: CGRect(x: x, y: size.height - height, width: Self.barWidth, height: height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            x += Self.barWidth + Self.barSpacing
        }
        let alpha = NowPlayingAudioLayer.Effects.alpha(0.82 * engine.fade * gain)
        context.fill(path, with: .color(accent.opacity(alpha)))
    }

    private func drawRadial(
        in context: inout GraphicsContext, size: CGSize, discFraction: CGFloat, gain: Double
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outerRadius = min(size.width, size.height) / 2
        // 3pt clearance past the platter edge keeps spikes off the progress ring.
        let base = outerRadius * discFraction + 3
        let maxLength = max(2, outerRadius - base - 1)
        var path = Path()
        for (index, value) in engine.bands.enumerated() {
            let angle = 2 * .pi * CGFloat(index) / CGFloat(engine.bands.count) - .pi / 2
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let length = 2.5 + CGFloat(value) * maxLength
            path.move(to: CGPoint(x: center.x + direction.x * base, y: center.y + direction.y * base))
            path.addLine(to: CGPoint(
                x: center.x + direction.x * (base + length),
                y: center.y + direction.y * (base + length)
            ))
        }
        let alpha = NowPlayingAudioLayer.Effects.alpha(0.88 * engine.fade * gain)
        context.stroke(
            path,
            with: .color(accent.opacity(alpha)),
            style: StrokeStyle(lineWidth: Self.spokeWidth, lineCap: .round)
        )
    }

    /// Additive halo on top of aurora's static 0.3 glow, breathing on the bass
    /// envelope. The amplitude used to cap at 0.15 — under the glow it sits on,
    /// so the breathing was there in the numbers and invisible on screen.
    private func drawHalo(in context: inout GraphicsContext, size: CGSize, gain: Double) {
        let low = Double(engine.drives.bassAtt)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = size.width * 0.375 * (1 + 0.18 * low)
        let alpha = NowPlayingAudioLayer.Effects.alpha(0.34 * low * engine.fade * gain)
        guard alpha > 0.002 else { return }
        var halo = context
        halo.opacity = alpha
        halo.fill(
            Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )),
            with: .radialGradient(haloGradient, center: center, startRadius: 0, endRadius: radius)
        )
    }

    // MARK: Particles + ripples

    /// Tile area decides the cap (roughly small / medium / large), and the bass
    /// decides how many of them are lit right now.
    static func particleCapacity(for size: CGSize) -> Int {
        let area = size.width * size.height
        if area < 30_000 { return 16 }
        if area < 90_000 { return 32 }
        return 64
    }

    /// Rising motes: every position is a pure function of seed(index) + time —
    /// no stored particle state, so a tick costs arithmetic only.
    private func drawParticles(
        in context: inout GraphicsContext, size: CGSize, now: TimeInterval,
        intensity: Double, gain: Double
    ) {
        let capacity = Self.particleCapacity(for: size)
        let live = NowPlayingAudioLayer.Effects.liveParticles(
            count: capacity, bass: engine.drives.bass, intensity: intensity
        )
        let mid = Double(engine.drives.mid)
        let envelope = Double(engine.drives.bassAtt)
        for index in 0..<live {
            let s1 = Self.seedUnit(index, 1)
            let s2 = Self.seedUnit(index, 2)
            let s3 = Self.seedUnit(index, 3)
            let s4 = Self.seedUnit(index, 4)
            let riseSpeed = 0.015 + 0.02 * s2 + 0.09 * mid
            let phase = (now * riseSpeed + s1).truncatingRemainder(dividingBy: 1)
            let yFraction = 1 - phase
            let x = (s3 + 0.04 * sin(now * (0.4 + 0.5 * s4) + s1 * 2 * .pi)) * size.width
            let y = yFraction * size.height
            let diameter = 3.5 + 2 * s4
            let alpha = NowPlayingAudioLayer.Effects.alpha(
                engine.fade * (0.16 + 0.62 * envelope) * gain * sin(.pi * yFraction)
            )
            guard alpha > 0.004 else { continue }
            context.fill(
                Path(ellipseIn: CGRect(
                    x: x - diameter / 2, y: y - diameter / 2,
                    width: diameter, height: diameter
                )),
                with: .color(accent.opacity(alpha))
            )
        }
    }

    private func drawRipples(
        in context: inout GraphicsContext, size: CGSize, now: TimeInterval, intensity: Double
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = max(size.width, size.height) * 0.55
        for slot in 0..<NowPlayingAudioLayer.RippleSlots.capacity {
            guard let progress = engine.ripples.progress(slot, now: now) else { continue }
            let alpha = NowPlayingAudioLayer.Effects.rippleAlpha(
                progress: progress, fade: engine.fade, intensity: intensity
            )
            guard alpha > 0.004 else { continue }
            let radius = maxRadius * (0.15 + 0.85 * progress)
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                )),
                with: .color(accent.opacity(alpha)),
                lineWidth: 2.2
            )
        }
    }

    /// Deterministic per-particle seed in 0…1 (splitmix64 finalizer).
    private static func seedUnit(_ index: Int, _ salt: UInt64) -> Double {
        var hash = UInt64(index) &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xBF58_476D_1CE4_E5B9
        hash ^= hash >> 31
        hash = hash &* 0x94D0_49BB_1331_11EB
        hash ^= hash >> 29
        return Double(hash % 100_000) / 100_000
    }
}

#endif
