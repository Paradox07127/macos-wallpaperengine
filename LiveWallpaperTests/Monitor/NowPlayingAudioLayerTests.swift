import XCTest
@testable import LiveWallpaper

final class NowPlayingAudioLayerTests: XCTestCase {
    private typealias Layer = NowPlayingAudioLayer

    // MARK: shouldRun — full truth table

    func testShouldRunTruthTable() {
        let phases: [MonitorNowPlayingPhase?] = [.playing, .paused, .awaitingFirstEvent, .noPlayer, nil]
        let bools = [false, true]
        for phase in phases {
            for reduceMotion in bools {
                for suspended in bools {
                    for capturing in bools {
                        for audioReactive in bools {
                            let expected = phase == .playing && !reduceMotion && !suspended
                                && capturing && audioReactive
                            XCTAssertEqual(
                                Layer.shouldRun(
                                    phase: phase,
                                    reduceMotion: reduceMotion,
                                    suspended: suspended,
                                    capturing: capturing,
                                    audioReactive: audioReactive
                                ),
                                expected,
                                "phase=\(String(describing: phase)) reduceMotion=\(reduceMotion) suspended=\(suspended) capturing=\(capturing) audioReactive=\(audioReactive)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// The user switch is a gate of its own: everything else can say yes.
    func testAudioReactiveSwitchOffStopsTheLayer() {
        XCTAssertFalse(
            Layer.shouldRun(
                phase: .playing, reduceMotion: false, suspended: false,
                capturing: true, audioReactive: false
            )
        )
        XCTAssertFalse(NowPlayingOptions([NowPlayingOptions.Key.audioReactive: .bool(false)]).audioReactive)
    }

    // MARK: mergedBands — 64 → N reduction

    func testMergedBandsPreservesMeanEnergyOnEvenSplit() {
        let bins = (0..<64).map { Float($0) / 64 }
        var bands = [Float](repeating: 0, count: 16)
        Layer.mergedBands(left: bins, right: bins, into: &bands)

        let binMean = bins.reduce(0, +) / 64
        let bandMean = bands.reduce(0, +) / 16
        XCTAssertEqual(bandMean, binMean, accuracy: 1e-5)

        // Each band is the energy mean of its own 4-bin slice.
        for band in 0..<16 {
            let slice = bins[(band * 4)..<(band * 4 + 4)]
            XCTAssertEqual(bands[band], slice.reduce(0, +) / 4, accuracy: 1e-5, "band \(band)")
        }
    }

    func testMergedBandsSingleBandIsGlobalMean() {
        let bins = (0..<64).map { Float($0).truncatingRemainder(dividingBy: 7) / 7 }
        var bands = [Float](repeating: 0, count: 1)
        Layer.mergedBands(left: bins, right: bins, into: &bands)
        XCTAssertEqual(bands[0], bins.reduce(0, +) / 64, accuracy: 1e-5)
    }

    func testMergedBandsMoreBandsThanBinsDuplicatesInsteadOfLeavingHoles() {
        let bins = (0..<64).map { Float($0) / 64 }
        var bands = [Float](repeating: -1, count: 128)
        Layer.mergedBands(left: bins, right: bins, into: &bands)
        for bin in 0..<64 {
            XCTAssertEqual(bands[bin * 2], bins[bin], accuracy: 1e-6, "band \(bin * 2)")
            XCTAssertEqual(bands[bin * 2 + 1], bins[bin], accuracy: 1e-6, "band \(bin * 2 + 1)")
        }
    }

    func testMergedBandsAveragesChannels() {
        let left = [Float](repeating: 1, count: 64)
        let right = [Float](repeating: 0, count: 64)
        var bands = [Float](repeating: 0, count: 8)
        Layer.mergedBands(left: left, right: right, into: &bands)
        for value in bands {
            XCTAssertEqual(value, 0.5, accuracy: 1e-6)
        }
    }

    func testMergedBandsEmptyInputZeroesBands() {
        var bands = [Float](repeating: 0.7, count: 4)
        Layer.mergedBands(left: [], right: [], into: &bands)
        XCTAssertEqual(bands, [0, 0, 0, 0])
    }

    // MARK: lowBandEnergy

    func testLowBandEnergyIsMeanOfLeadingBinsOnly() {
        var left = [Float](repeating: 0, count: 64)
        var right = [Float](repeating: 0, count: 64)
        for bin in 0..<Layer.lowBandCount {
            left[bin] = 0.8
            right[bin] = 0.4
        }
        // Loud high bins must not leak into the low-band figure.
        for bin in Layer.lowBandCount..<64 {
            left[bin] = 1
            right[bin] = 1
        }
        XCTAssertEqual(Layer.lowBandEnergy(left: left, right: right), 0.6, accuracy: 1e-6)
    }

    func testLowBandEnergyEmptyInputIsZero() {
        XCTAssertEqual(Layer.lowBandEnergy(left: [], right: []), 0)
    }

    // MARK: Silence detection + hold

    func testIsAudibleThreshold() {
        let quiet = [Float](repeating: Layer.silenceThreshold - 0.001, count: 64)
        XCTAssertFalse(Layer.isAudible(left: quiet, right: quiet))

        var oneLoudBin = quiet
        oneLoudBin[40] = Layer.silenceThreshold
        XCTAssertTrue(Layer.isAudible(left: oneLoudBin, right: quiet))
        XCTAssertTrue(Layer.isAudible(left: quiet, right: oneLoudBin))
    }

    func testSilenceGateHoldSemantics() {
        var gate = Layer.SilenceGate()

        // Never audible: inactive from the start.
        XCTAssertFalse(gate.update(audible: false, now: 10))

        // Audible now: active.
        XCTAssertTrue(gate.update(audible: true, now: 11))

        // Silent but within the hold window: still active (no flicker between songs).
        XCTAssertTrue(gate.update(audible: false, now: 11 + Layer.audibleHold - 0.05))
        XCTAssertTrue(gate.update(audible: false, now: 11 + Layer.audibleHold))

        // Past the hold window: inactive.
        XCTAssertFalse(gate.update(audible: false, now: 11 + Layer.audibleHold + 0.05))

        // Audio returning re-arms the hold.
        XCTAssertTrue(gate.update(audible: true, now: 20))
        XCTAssertTrue(gate.update(audible: false, now: 20.5))
    }

    // MARK: Smoothing — attack instant, release geometric

    /// One reference tick — at this dt the envelope is exactly `releaseFactor`.
    private let tick = 1.0 / Double(Layer.referenceTickRate)

    func testSmoothingAttackIsInstant() {
        XCTAssertEqual(Layer.smoothed(previous: 0.2, target: 0.9, dt: tick), 0.9)
        XCTAssertEqual(Layer.smoothed(previous: 0, target: 1, dt: tick), 1)
    }

    func testSmoothingReleaseDecaysMonotonically() {
        var value: Float = 1
        var previous = value
        for step in 0..<20 {
            value = Layer.smoothed(previous: value, target: 0, dt: tick)
            XCTAssertLessThan(value, previous, "tick \(step) should decay")
            XCTAssertEqual(value, previous * Layer.releaseFactor, accuracy: 1e-6)
            previous = value
        }
        XCTAssertGreaterThan(value, 0, "geometric release never goes negative")
    }

    func testSmoothingReleaseStopsAtHigherTarget() {
        // A target above the decayed value wins immediately (attack over release).
        XCTAssertEqual(Layer.smoothed(previous: 0.5, target: 0.45, dt: tick), 0.45, accuracy: 1e-6)
        XCTAssertEqual(Layer.smoothed(previous: 0.5, target: 0.41, dt: tick), 0.41, accuracy: 1e-6)
        XCTAssertEqual(
            Layer.smoothed(previous: 0.5, target: 0.3, dt: tick),
            0.5 * Layer.releaseFactor, accuracy: 1e-6
        )
    }

    // MARK: Frame-rate normalized release

    func testSmoothingAtTheReferenceTickMatchesTheFixedFactor() {
        let dt = 1.0 / Layer.referenceTickRate
        XCTAssertEqual(
            Layer.smoothed(previous: 1, target: 0, dt: dt), Layer.releaseFactor, accuracy: 1e-5
        )
        XCTAssertEqual(Layer.smoothed(previous: 0.2, target: 0.9, dt: dt), 0.9, "attack stays instant")
    }

    /// Same wall-clock second, three different frame rates: the envelope must
    /// land in the same place, or a dropped frame slows the visuals down.
    func testReleaseIsFrameRateIndependent() {
        func decayed(steps: Int, dt: TimeInterval) -> Float {
            var value: Float = 1
            for _ in 0..<steps { value = Layer.smoothed(previous: value, target: 0, dt: dt) }
            return value
        }

        let thirty = decayed(steps: 30, dt: 1.0 / 30.0)
        let sixty = decayed(steps: 60, dt: 1.0 / 60.0)
        let fifteen = decayed(steps: 15, dt: 1.0 / 15.0)

        XCTAssertEqual(thirty, sixty, accuracy: 1e-4, "60fps must not decay twice as fast")
        XCTAssertEqual(thirty, fifteen, accuracy: 1e-4, "15fps must not decay half as fast")
        XCTAssertEqual(thirty, pow(Layer.releaseFactor, 30), accuracy: 1e-4)
    }

    func testReleaseWithVaryingFrameTimesTracksElapsedTime() {
        // A stuttering second (alternating 30fps / 60fps frames) still lands on
        // one second's worth of decay.
        var value: Float = 1
        var elapsed: TimeInterval = 0
        var short = true
        while elapsed < 1 {
            let dt = short ? 1.0 / 60.0 : 1.0 / 30.0
            short.toggle()
            value = Layer.smoothed(previous: value, target: 0, dt: dt)
            elapsed += dt
        }
        XCTAssertEqual(value, pow(Layer.releaseFactor, Float(elapsed * 30)), accuracy: 1e-4)
    }

    func testLongStallIsCappedInsteadOfZeroingTheEnvelope() {
        // A parked layer resuming after minutes must not snap the visuals off.
        let capped = Layer.smoothed(previous: 1, target: 0, dt: 120)
        XCTAssertEqual(capped, pow(Layer.releaseFactor, Float(0.25 * 30)), accuracy: 1e-5)
        XCTAssertEqual(Layer.smoothed(previous: 0.5, target: 0, dt: -1), 0.5, accuracy: 1e-6)
    }

    // MARK: Six drive quantities

    func testSilenceLeavesEveryDriveAtZero() {
        let quiet = [Float](repeating: 0, count: 64)
        let instant = Layer.instantDrives(left: quiet, right: quiet)
        XCTAssertEqual(instant.bass, 0)
        XCTAssertEqual(instant.mid, 0)
        XCTAssertEqual(instant.treb, 0)

        var drives = Layer.Drives()
        drives.advance(left: quiet, right: quiet, dt: 1.0 / 30.0)
        XCTAssertEqual(drives, Layer.Drives())
    }

    func testEmptyFrameLeavesEveryDriveAtZero() {
        let instant = Layer.instantDrives(left: [], right: [])
        XCTAssertEqual(instant.bass, 0)
        XCTAssertEqual(instant.mid, 0)
        XCTAssertEqual(instant.treb, 0)
    }

    /// Energy in one band must not leak into the other two — at 64 bins the
    /// split is 0–7 bass, 8–31 mid, 32–63 treble.
    func testEachBandLiftsOnlyItsOwnDrive() {
        func frame(_ range: Range<Int>) -> [Float] {
            var bins = [Float](repeating: 0, count: 64)
            for bin in range { bins[bin] = 0.5 }
            return bins
        }

        let bass = Layer.instantDrives(left: frame(0..<8), right: frame(0..<8))
        XCTAssertEqual(bass.bass, 0.5, accuracy: 1e-6)
        XCTAssertEqual(bass.mid, 0)
        XCTAssertEqual(bass.treb, 0)

        let mid = Layer.instantDrives(left: frame(8..<32), right: frame(8..<32))
        XCTAssertEqual(mid.bass, 0)
        XCTAssertEqual(mid.mid, 0.5, accuracy: 1e-6)
        XCTAssertEqual(mid.treb, 0)

        let treble = Layer.instantDrives(left: frame(32..<64), right: frame(32..<64))
        XCTAssertEqual(treble.bass, 0)
        XCTAssertEqual(treble.mid, 0)
        XCTAssertEqual(treble.treb, 0.5, accuracy: 1e-6)
    }

    func testInstantDrivesAverageChannels() {
        let left = [Float](repeating: 1, count: 64)
        let right = [Float](repeating: 0, count: 64)
        let instant = Layer.instantDrives(left: left, right: right)
        XCTAssertEqual(instant.bass, 0.5, accuracy: 1e-6)
        XCTAssertEqual(instant.mid, 0.5, accuracy: 1e-6)
        XCTAssertEqual(instant.treb, 0.5, accuracy: 1e-6)
    }

    func testAttenuatedDrivesTrackInstantOnesUpAndLagThemDown() {
        let loud = [Float](repeating: 0.8, count: 64)
        let quiet = [Float](repeating: 0, count: 64)
        let dt = 1.0 / 30.0

        var drives = Layer.Drives()
        drives.advance(left: loud, right: loud, dt: dt)
        XCTAssertEqual(drives.bass, 0.8, accuracy: 1e-6)
        XCTAssertEqual(drives.bassAtt, 0.8, accuracy: 1e-6, "attack is instant")

        // The instant drives drop on the first silent frame; the envelopes decay.
        var previous = drives
        for tick in 0..<20 {
            drives.advance(left: quiet, right: quiet, dt: dt)
            XCTAssertEqual(drives.bass, 0, "tick \(tick): instant drive follows the frame")
            XCTAssertEqual(drives.mid, 0)
            XCTAssertEqual(drives.treb, 0)
            XCTAssertLessThan(drives.bassAtt, previous.bassAtt, "tick \(tick) bass envelope")
            XCTAssertLessThan(drives.midAtt, previous.midAtt, "tick \(tick) mid envelope")
            XCTAssertLessThan(drives.trebAtt, previous.trebAtt, "tick \(tick) treble envelope")
            previous = drives
        }
        XCTAssertGreaterThan(drives.bassAtt, 0)
    }

    func testDriveEnvelopesAreFrameRateIndependent() {
        let loud = [Float](repeating: 0.7, count: 64)
        let quiet = [Float](repeating: 0, count: 64)

        func settled(steps: Int, dt: TimeInterval) -> Layer.Drives {
            var drives = Layer.Drives()
            drives.advance(left: loud, right: loud, dt: dt)
            for _ in 0..<steps { drives.advance(left: quiet, right: quiet, dt: dt) }
            return drives
        }

        let thirty = settled(steps: 30, dt: 1.0 / 30.0)
        let sixty = settled(steps: 60, dt: 1.0 / 60.0)
        XCTAssertEqual(thirty.bassAtt, sixty.bassAtt, accuracy: 1e-4)
        XCTAssertEqual(thirty.midAtt, sixty.midAtt, accuracy: 1e-4)
        XCTAssertEqual(thirty.trebAtt, sixty.trebAtt, accuracy: 1e-4)
    }

    // MARK: Beat detection

    private func flat(_ value: Float) -> [Float] { [Float](repeating: value, count: 64) }

    func testSilenceProducesNoBeats() {
        var detector = Layer.BeatDetector()
        var beats = 0
        for frame in 0..<300 where detector.step(
            bins: flat(0), now: Double(frame) / 30, sensitivity: 1.5
        ) {
            beats += 1
        }
        XCTAssertEqual(beats, 0)
        XCTAssertEqual(detector.pulse(now: 10), 0)
    }

    func testPeriodicSpikesAreDetectedAtTheRightInterval() {
        var detector = Layer.BeatDetector()
        var beats: [TimeInterval] = []
        // A 120 BPM kick: one loud frame every 15 ticks, silence between.
        for frame in 0..<300 {
            let now = Double(frame) / 30
            let bins = frame % 15 == 0 && frame > 0 ? flat(0.9) : flat(0)
            if detector.step(bins: bins, now: now, sensitivity: 1.5) { beats.append(now) }
        }

        XCTAssertGreaterThanOrEqual(beats.count, 15, "a clear kick must be found")
        XCTAssertLessThanOrEqual(beats.count, 20, "one beat per kick, not per frame")
        for index in 1..<beats.count {
            XCTAssertEqual(beats[index] - beats[index - 1], 0.5, accuracy: 0.02, "gap \(index)")
        }
        // The pulse rides the last beat and is gone half a second later.
        let last = try? XCTUnwrap(beats.last)
        XCTAssertEqual(detector.pulse(now: last ?? 0), 1, accuracy: 1e-5)
        XCTAssertLessThan(detector.pulse(now: (last ?? 0) + 0.5), 0.1)
    }

    func testSteadyNoiseDoesNotFireEveryFrame() {
        var detector = Layer.BeatDetector()
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func random() -> Float {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Float(seed % 1000) / 1000
        }

        var beats = 0
        let frames = 300
        for frame in 0..<frames {
            var bins = [Float](repeating: 0, count: 64)
            for bin in bins.indices { bins[bin] = random() }
            if detector.step(bins: bins, now: Double(frame) / 30, sensitivity: 1.5) { beats += 1 }
        }
        XCTAssertLessThan(beats, frames / 6, "steady noise must not read as a beat every frame")
    }

    func testBeatsHonourTheMinimumInterval() {
        var detector = Layer.BeatDetector()
        var beats: [TimeInterval] = []
        // Spikes at 7.5 Hz — faster than the 240 BPM ceiling allows.
        for frame in 0..<150 {
            let now = Double(frame) / 30
            let bins = frame % 4 == 0 && frame > 0 ? flat(0.9) : flat(0)
            if detector.step(bins: bins, now: now, sensitivity: 1.5) { beats.append(now) }
        }

        XCTAssertGreaterThan(beats.count, 3, "the spikes are real onsets")
        for index in 1..<beats.count {
            XCTAssertGreaterThanOrEqual(
                beats[index] - beats[index - 1],
                Layer.BeatDetector.minimumInterval - 1e-9,
                "gap \(index) is under the 240 BPM ceiling"
            )
        }
    }

    func testHigherSensitivityFindsFewerBeats() {
        func beats(sensitivity: Float) -> Int {
            var detector = Layer.BeatDetector()
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            var count = 0
            for frame in 0..<300 {
                seed ^= seed << 13
                seed ^= seed >> 7
                seed ^= seed << 17
                let level = Float(seed % 1000) / 1000
                if detector.step(bins: flat(level), now: Double(frame) / 30, sensitivity: sensitivity) {
                    count += 1
                }
            }
            return count
        }
        XCTAssertLessThanOrEqual(beats(sensitivity: 2.5), beats(sensitivity: 0.8))
    }

    // MARK: Ripple slots

    func testRippleSlotsExpireAndRecycleOldestFirst() throws {
        var slots = Layer.RippleSlots()
        XCTAssertNil(slots.progress(0, now: 0), "an untouched slot draws nothing")

        slots.trigger(at: 100)
        XCTAssertEqual(slots.progress(0, now: 100), 0)
        XCTAssertEqual(
            try XCTUnwrap(slots.progress(0, now: 100 + Layer.RippleSlots.duration / 2)),
            0.5,
            accuracy: 1e-9
        )
        XCTAssertNil(slots.progress(0, now: 100 + Layer.RippleSlots.duration + 0.01))

        // Five beats into four slots: the fifth lands back on the first.
        for index in 1...4 { slots.trigger(at: 100 + Double(index) * 0.1) }
        XCTAssertEqual(slots.progress(0, now: 100.4), 0)
        XCTAssertNil(slots.progress(Layer.RippleSlots.capacity, now: 100.4), "out of range")
    }

    // MARK: Idle parking

    func testShouldIdleTruthTable() {
        XCTAssertFalse(Layer.shouldIdle(fade: 1, silentFor: 60), "visible layers keep ticking")
        XCTAssertFalse(Layer.shouldIdle(fade: 0.5, silentFor: 60))
        XCTAssertFalse(Layer.shouldIdle(fade: 0, silentFor: 0), "audio just stopped")
        XCTAssertFalse(Layer.shouldIdle(fade: 0, silentFor: Layer.idleSilence - 0.01))
        XCTAssertTrue(Layer.shouldIdle(fade: 0, silentFor: Layer.idleSilence))
        XCTAssertTrue(Layer.shouldIdle(fade: 0.0005, silentFor: Layer.idleSilence + 30))
    }

    // MARK: Effect amplitude ceilings

    func testEffectAmplitudesStayUnderTheirCeilingsAtMaximumIntensity() {
        typealias Effects = Layer.Effects
        let intensity = NowPlayingOptions.Limits.audioIntensity.upperBound
        XCTAssertEqual(intensity, 2.0)

        for step in 0...20 {
            let drive = Float(step) / 20
            XCTAssertLessThanOrEqual(Effects.shakeOffset(bass: drive, intensity: intensity), 4)
            XCTAssertLessThanOrEqual(Effects.shakeRotation(bass: drive, intensity: intensity), 0.6)
            XCTAssertLessThanOrEqual(Effects.chromaticOffset(treb: drive, intensity: intensity), 3)
            XCTAssertLessThanOrEqual(
                Effects.pulseGain(bassAtt: drive, beat: 1, intensity: intensity), 1.4
            )
            XCTAssertLessThanOrEqual(
                Effects.rippleAlpha(progress: 0, fade: 1, intensity: intensity), 1
            )
            XCTAssertLessThanOrEqual(
                Effects.liveParticles(count: 64, bass: drive, intensity: intensity), 64
            )
        }

        // Silence parks every effect at rest.
        XCTAssertEqual(Effects.shakeOffset(bass: 0, intensity: intensity), 0)
        XCTAssertEqual(Effects.chromaticOffset(treb: 0, intensity: intensity), 0)
        XCTAssertEqual(Effects.pulseGain(bassAtt: 0, beat: 0, intensity: intensity), 1)
        XCTAssertGreaterThan(
            Effects.pulseGain(bassAtt: 0, beat: 1, intensity: 1),
            Effects.pulseGain(bassAtt: 0, beat: 0, intensity: 1),
            "a beat flashes on top of the bass breathing"
        )
        XCTAssertEqual(Effects.alpha(9), 1)
        XCTAssertEqual(Effects.alpha(-9), 0)
        XCTAssertEqual(Effects.alpha(.nan), 0)
    }

    func testEffectAmplitudesGrowWithIntensityUntilTheyClamp() {
        typealias Effects = Layer.Effects
        XCTAssertLessThan(
            Effects.shakeOffset(bass: 0.2, intensity: 0.5),
            Effects.shakeOffset(bass: 0.2, intensity: 1.0)
        )
        XCTAssertLessThan(
            Effects.chromaticOffset(treb: 0.1, intensity: 0.5),
            Effects.chromaticOffset(treb: 0.1, intensity: 1.0)
        )
        XCTAssertGreaterThanOrEqual(Effects.liveParticles(count: 32, bass: 0, intensity: 1), 1)
        XCTAssertLessThan(
            Effects.liveParticles(count: 32, bass: 0.1, intensity: 1),
            Effects.liveParticles(count: 32, bass: 0.6, intensity: 1)
        )
    }

    func testDeterministicNoiseIsBoundedAndRepeatable() {
        for step in 0...100 {
            let time = Double(step) * 0.37
            let value = Layer.noise(time, phase: 1.7)
            XCTAssertLessThanOrEqual(abs(value), 1.0001, "noise stays in −1…1 at t=\(time)")
            XCTAssertEqual(value, Layer.noise(time, phase: 1.7), "same instant, same wobble")
        }
    }
}
