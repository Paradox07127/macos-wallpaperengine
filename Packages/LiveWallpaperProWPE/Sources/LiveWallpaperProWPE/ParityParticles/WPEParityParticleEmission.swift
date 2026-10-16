extension WPEParityParticleSystem {
    /// 2378a0: the signed periodic clock advances only inside the ordinary emission gate. Rate requested before
    /// capacity or per-period limits is removed from the accumulator; the burst is independent of those limits.
    mutating func emit(_ index: Int, dt: Float) {
        let emitter = config.emitters[index]
        var state = emitterStates[index]
        if !state.disabled, state.delayLeft <= 0, liveCount < capacity {
            var rate = emitter.rate * instance.count
            if emitter.periodic {
                if state.periodTimer > 0 {
                    state.periodTimer -= dt
                    if state.periodTimer < 0 {
                        state.periodTimer = -rng.draw(emitter.periodicDelayMin, emitter.periodicDelayMax)
                    }
                } else {
                    state.periodTimer += dt
                    if state.periodTimer < 0 {
                        rate *= 0
                    } else {
                        state.periodTimer = rng.draw(emitter.periodicDurationMin, emitter.periodicDurationMax)
                        state.burstPending = emitter.instantaneous > 0
                        state.emittedThisPeriod = 0
                        restartPeriodChildren()
                    }
                }
            }
            // count binds rate and maxtoemitperperiod only; the burst reads the raw value (2378a0.c:423-427).
            let burst = state.burstPending ? emitter.instantaneous : 0
            state.burstPending = false
            let accumulated = state.accumulator + rate * dt
            var count = burst
            if accumulated < 1 || state.durationLeft < 0 {
                state.accumulator = accumulated - Float(burst)
            } else {
                let requested = Int(accumulated.rounded(.down))
                state.accumulator = accumulated - Float(requested + burst)
                var rateCount = emitter.maxOnePerFrame ? min(requested, 1) : requested
                if emitter.periodic, emitter.maxPerPeriod > 0 {
                    rateCount = min(rateCount, max(0, emitter.maxPerPeriod - state.emittedThisPeriod))
                    state.emittedThisPeriod += rateCount
                }
                count += rateCount
            }
            for _ in 0 ..< min(max(count, 0), capacity - liveCount) {
                spawn(emitter)
            }
        }
        // A full/disabled emitter still handles its delay or duration. Expiry never revives a detached follow.
        if state.delayLeft > 0 {
            state.delayLeft -= dt
        } else if state.durationLeft > 0 {
            state.durationLeft -= dt
            if state.durationLeft <= 0 {
                state.durationLeft = -1
                state.disabled = true
            }
        } else if emitter.rate * instance.count <= 0, !emitter.periodic || emitter.instantaneous == 0 {
            state.disabled = true
        }
        emitterStates[index] = state
    }

    /// 22f790 resets only static children carrying edge.flags bit 1, preserving live slots and CP/history.
    /// The parent's sequence reset flags are handled independently from child emitter restart.
    private mutating func restartPeriodChildren() {
        for (index, child) in config.children.enumerated() where child.trigger == .always && child.flags & 2 != 0 {
            children[childGroup[index]].resetFinishedEventThroughStaticChildren()
        }
        for (index, initializer) in config.initializers.enumerated() {
            if case let .sequenceBetween(field) = initializer, field.flags & 0x20 != 0 {
                sequenceStates[index].t = 0
            }
        }
    }
}
