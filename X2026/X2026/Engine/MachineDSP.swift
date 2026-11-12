import Foundation

/// Four-point, third-order interpolation between `x0` and `x1`.
@inline(__always)
nonisolated func hermite(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float, _ t: Float) -> Float {
    let c1 = 0.5 * (x1 - xm1)
    let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
    let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
    return ((c3 * t + c2) * t + c1) * t + x0
}

/// A gain that glides to its target over one audio block, so turning a knob
/// never produces zipper noise.
nonisolated struct Ramp {
    private(set) var value: Float = 0
    private var step: Float = 0

    mutating func aim(_ target: Float, frames: Int) {
        step = (target - value) / Float(max(1, frames))
    }

    @inline(__always)
    mutating func next() -> Float {
        value += step
        return value
    }
}

/// One track of the record head: the last few samples it was fed (for
/// interpolating onto the moving tape) and how far its bias and the erase
/// current have ramped up.
nonisolated struct RecordHead {
    var h0: Float = 0
    var h1: Float = 0
    var h2: Float = 0
    var h3: Float = 0
    var bias: Float = 0
    var erase: Float = 0
    var leak = OnePole()
}

/// The whole machine as signal processing: six inputs, the mixer exactly as
/// drawn in the block diagram, a four-track recorder, and the headphone
/// monitor. Runs on the audio thread; touches nothing but its own memory and
/// the tape.
///
/// ## Signal flow
/// - Channels 1–2: preamp → fader → (post-fader AUX) → pan → stereo buss.
/// - Channels 3–6: each AUX and GAIN knob picks *either* its line input or its
///   tape track. GAIN → SUB PAN → sub mix; AUX (pre-fader) → AUX buss.
/// - REMIX puts the sub mix on the stereo buss. NORM keeps it off.
/// - Stereo buss (+ AUX RCV) → EQ → MASTER → LINE OUT, the meters, and the
///   REC TRK selectors: L feeds track 1 or 3, R feeds track 2 or 4.
/// - An armed track's output is its *input* except in plain PLAY; otherwise
///   it is the tape. Monitoring off the tape while recording is impossible:
///   there is only one head.
nonisolated struct MachineDSP {
    static let maximumFrames = 4096
    static let jackCount = 6
    static let trackCount = CassetteStandard.trackCount

    private static let historySize = 1 << 16
    private static let historyMask = historySize - 1

    /// Op-amp rails, relative to full scale.
    private static let rail: Float = 1.3
    /// Adjacent-track separation of 45 dB.
    private static let crosstalk: Float = 0.0056
    /// What the record bias alone leaves of an old recording (about -15 dB).
    private static let biasErasure: Float = 0.18
    /// Record-head field leaking into the neighbouring playback tracks.
    private static let recordLeak: Float = 0.03
    /// Mixer self-noise, around 78 dB below the 0 mark.
    private static let floorNoise: Float = Level.reference * 0.000126 / 0.5774

    private enum Gain {
        static let fader = 0            // 2
        static let aux12 = 2            // 2
        static let panL = 4             // 2
        static let panR = 6             // 2
        static let auxInput = 8         // 4
        static let auxTrack = 12        // 4
        static let subInput = 16        // 4
        static let subTrack = 20        // 4
        static let subPanL = 24         // 4
        static let subPanR = 28         // 4
        static let auxSend = 32
        static let returnL = 33
        static let returnR = 34
        static let master = 35
        static let monitor = 36
        static let count = 37
    }

    // MARK: State

    private(set) var sampleRate = 48_000.0
    private(set) var deck = TapeDeck()
    private var medium: TapeMedium?
    private var recordProtected = false
    private var requestedMotion = TapeDeck.Motion.stop

    /// Six input jacks, `maximumFrames` samples each, filled by the host.
    let jacks: UnsafeMutablePointer<Float>
    /// LINE OUT L then R, as it would reach a master recorder.
    let lineOut: UnsafeMutablePointer<Float>

    private let gains: UnsafeMutablePointer<Ramp>
    private let channels: UnsafeMutablePointer<TapeChannel>
    private let heads: UnsafeMutablePointer<RecordHead>
    private let positions: UnsafeMutablePointer<Double>
    private let tapeBussL: UnsafeMutablePointer<Float>
    private let tapeBussR: UnsafeMutablePointer<Float>
    private let lateAux: UnsafeMutablePointer<Float>
    private let trackOut: UnsafeMutablePointer<Float>
    private let raw: UnsafeMutablePointer<Float>
    private let leak: UnsafeMutablePointer<Float>
    private var clock = 0

    // Stereo-buss equaliser: one set for what you hear, one for what is recorded.
    private var highL = Biquad()
    private var lowL = Biquad()
    private var highR = Biquad()
    private var lowR = Biquad()
    private var recordHighL = Biquad()
    private var recordLowL = Biquad()
    private var recordHighR = Biquad()
    private var recordLowR = Biquad()
    private var equaliserSettings = (-1.0, -1.0, -1.0, -1.0)

    private var couplingL = DCBlocker()
    private var couplingR = DCBlocker()
    private var recordCouplingL = DCBlocker()
    private var recordCouplingR = DCBlocker()
    private var previousLineL: Float = 0
    private var previousLineR: Float = 0

    private var meters = Quad<Float>(repeating: 0)
    private var meterAttack: Float = 0.1
    private var meterRelease: Float = 0.0001
    private var biasStep: Float = 0.002
    private var eraseStep: Float = 0.0015
    private var eraseGapFrames = 12_598

    private var effect = AuxEffect()
    /// A twin of the effects box that hears the AUX buss as the tape will:
    /// with tape-derived signal held back by the audio round trip.
    private var recordEffect = AuxEffect()
    private var mechanics = MechanicalSounds()
    /// Counts every time the fuse has had to clear the signal path.
    private(set) var fuseCount: UInt32 = 0
    private var previousLatency = 0
    private var noise = NoiseSource(seed: 0x5EED_F00D)

    // MARK: Lifetime

    init() {
        jacks = .allocate(capacity: Self.jackCount * Self.maximumFrames)
        jacks.initialize(repeating: 0, count: Self.jackCount * Self.maximumFrames)
        lineOut = .allocate(capacity: 2 * Self.maximumFrames)
        lineOut.initialize(repeating: 0, count: 2 * Self.maximumFrames)
        gains = .allocate(capacity: Gain.count)
        gains.initialize(repeating: Ramp(), count: Gain.count)
        channels = .allocate(capacity: Self.trackCount)
        heads = .allocate(capacity: Self.trackCount)
        for track in 0..<Self.trackCount {
            (channels + track).initialize(to: TapeChannel(seed: UInt32(track + 1)))
            (heads + track).initialize(to: RecordHead())
        }
        positions = .allocate(capacity: Self.historySize)
        positions.initialize(repeating: 0, count: Self.historySize)
        tapeBussL = .allocate(capacity: Self.historySize)
        tapeBussL.initialize(repeating: 0, count: Self.historySize)
        tapeBussR = .allocate(capacity: Self.historySize)
        tapeBussR.initialize(repeating: 0, count: Self.historySize)
        lateAux = .allocate(capacity: Self.historySize)
        lateAux.initialize(repeating: 0, count: Self.historySize)
        trackOut = .allocate(capacity: Self.trackCount)
        trackOut.initialize(repeating: 0, count: Self.trackCount)
        raw = .allocate(capacity: Self.trackCount)
        raw.initialize(repeating: 0, count: Self.trackCount)
        leak = .allocate(capacity: Self.trackCount)
        leak.initialize(repeating: 0, count: Self.trackCount)
        prepare(sampleRate: 48_000)
    }

    /// Frees everything. The struct must not be used afterwards.
    mutating func tearDown() {
        medium = nil
        effect.release()
        recordEffect.release()
        mechanics.release()
        jacks.deallocate()
        lineOut.deallocate()
        gains.deallocate()
        channels.deinitialize(count: Self.trackCount)
        channels.deallocate()
        heads.deallocate()
        positions.deallocate()
        tapeBussL.deallocate()
        tapeBussR.deallocate()
        lateAux.deallocate()
        trackOut.deallocate()
        raw.deallocate()
        leak.deallocate()
    }

    /// Sets everything up for a sample rate. Allocates; not for the audio thread.
    mutating func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        deck.configure(sampleRate: sampleRate)
        for track in 0..<Self.trackCount {
            channels[track].configure(sampleRate: sampleRate)
            heads[track].leak.setCutoff(3000, sampleRate: sampleRate)
        }
        effect.prepare(sampleRate: sampleRate)
        recordEffect.prepare(sampleRate: sampleRate)
        mechanics.prepare(sampleRate: sampleRate)
        couplingL.setCutoff(6, sampleRate: sampleRate)
        couplingR.setCutoff(6, sampleRate: sampleRate)
        recordCouplingL.setCutoff(6, sampleRate: sampleRate)
        recordCouplingR.setCutoff(6, sampleRate: sampleRate)
        for index in 0..<Self.historySize {
            tapeBussL[index] = 0
            tapeBussR[index] = 0
            lateAux[index] = 0
        }
        meterAttack = Float(1 - exp(-1 / (0.004 * sampleRate)))
        meterRelease = Float(1 - exp(-1 / (0.28 * sampleRate)))
        biasStep = Float(1 / (0.012 * sampleRate))
        eraseStep = Float(1 / (0.016 * sampleRate))
        eraseGapFrames = Int((CassetteStandard.eraseToRecordGap * CassetteStandard.framesPerMeter).rounded())
        equaliserSettings = (-1, -1, -1, -1)
    }

    var calibration: TapeDeck.Calibration {
        get { deck.calibration }
        set { deck.calibration = newValue }
    }

    // MARK: Tape

    mutating func load(medium: TapeMedium, stock: TapeStock, position: Double, recordProtected: Bool) {
        self.medium = medium
        self.recordProtected = recordProtected
        deck.load(stock: stock, position: position)
        requestedMotion = .stop
        settleHistory()
    }

    /// Takes the cassette out and reports where its tape was left.
    @discardableResult
    mutating func unload() -> Double {
        let position = deck.position
        medium = nil
        deck.unload()
        requestedMotion = .stop
        settleHistory()
        return position
    }

    /// Forget where the tape has been, so a tape change is never mistaken
    /// for a stretch of tape passing the record head.
    private mutating func settleHistory() {
        let frame = deck.oxideFrame
        for index in 0..<Self.historySize { positions[index] = frame }
        for track in 0..<Self.trackCount {
            heads[track].bias = 0
            heads[track].erase = 0
        }
    }

    /// Clears every filter and delay in the signal path.
    private mutating func blowFuse() {
        previousLineL = 0
        previousLineR = 0
        highL.reset()
        lowL.reset()
        highR.reset()
        lowR.reset()
        recordHighL.reset()
        recordLowL.reset()
        recordHighR.reset()
        recordLowR.reset()
        couplingL = DCBlocker()
        couplingR = DCBlocker()
        recordCouplingL = DCBlocker()
        recordCouplingR = DCBlocker()
        couplingL.setCutoff(6, sampleRate: sampleRate)
        couplingR.setCutoff(6, sampleRate: sampleRate)
        recordCouplingL.setCutoff(6, sampleRate: sampleRate)
        recordCouplingR.setCutoff(6, sampleRate: sampleRate)
        meters = Quad(repeating: 0)
        for index in 0..<Self.historySize {
            tapeBussL[index] = 0
            tapeBussR[index] = 0
            lateAux[index] = 0
        }
        for track in 0..<Self.trackCount {
            channels[track] = TapeChannel(seed: UInt32(track + 1))
            channels[track].configure(sampleRate: sampleRate)
            heads[track] = RecordHead()
            heads[track].leak.setCutoff(3000, sampleRate: sampleRate)
            trackOut[track] = 0
            leak[track] = 0
        }
        effect.clear()
        recordEffect.clear()
        fuseCount &+= 1
    }

    mutating func trigger(_ sound: MechanicalSound) {
        mechanics.trigger(sound)
    }

    /// The state of the transport right now, for when no audio block has run
    /// since something changed (a tape was just loaded, say).
    func idleReport() -> Telemetry {
        var report = Telemetry()
        report.hasTape = deck.hasTape
        report.position = deck.position
        report.motion = deck.motion
        report.capstan = Float(deck.capstan)
        report.windSpeed = Float(deck.windSpeed)
        report.autoStopCount = deck.autoStopCount
        report.fuseCount = fuseCount
        return report
    }

    // MARK: Tapers

    /// Rotary level pots: unity at 6 on the dial, about +7 dB flat out.
    private static func pot(_ value: Double) -> Float {
        value <= 0.004 ? 0 : Float(pow(min(1, value) / 0.6, 1.6))
    }

    /// Faders: unity between 7 and 8, as the manual keeps telling you.
    private static func fader(_ value: Double) -> Float {
        value <= 0.004 ? 0 : Float(pow(min(1, value) / 0.75, 2.5))
    }

    private mutating func aimGains(_ panel: Panel, frames: Int) {
        gains[Gain.fader].aim(Self.fader(panel.fader1), frames: frames)
        gains[Gain.fader + 1].aim(Self.fader(panel.fader2), frames: frames)
        gains[Gain.aux12].aim(Self.pot(panel.aux1), frames: frames)
        gains[Gain.aux12 + 1].aim(Self.pot(panel.aux2), frames: frames)
        gains[Gain.panL].aim(Float(cos(panel.pan1 * .pi / 2)), frames: frames)
        gains[Gain.panR].aim(Float(sin(panel.pan1 * .pi / 2)), frames: frames)
        gains[Gain.panL + 1].aim(Float(cos(panel.pan2 * .pi / 2)), frames: frames)
        gains[Gain.panR + 1].aim(Float(sin(panel.pan2 * .pi / 2)), frames: frames)
        for channel in 0..<Self.trackCount {
            // Centre-zero pots: anticlockwise brings up the line input,
            // clockwise the tape track. Never both.
            let aux = (panel.aux[channel] - 0.5) * 2
            gains[Gain.auxInput + channel].aim(Self.pot(-aux), frames: frames)
            gains[Gain.auxTrack + channel].aim(Self.pot(aux), frames: frames)
            let gain = (panel.subGain[channel] - 0.5) * 2
            gains[Gain.subInput + channel].aim(Self.pot(-gain), frames: frames)
            gains[Gain.subTrack + channel].aim(Self.pot(gain), frames: frames)
            gains[Gain.subPanL + channel].aim(Float(cos(panel.subPan[channel] * .pi / 2)), frames: frames)
            gains[Gain.subPanR + channel].aim(Float(sin(panel.subPan[channel] * .pi / 2)), frames: frames)
        }
        gains[Gain.auxSend].aim(Self.pot(panel.auxSend), frames: frames)
        gains[Gain.returnL].aim(Self.pot(panel.auxReturnL), frames: frames)
        gains[Gain.returnR].aim(Self.pot(panel.auxReturnR), frames: frames)
        gains[Gain.master].aim(Self.fader(panel.master), frames: frames)
        let monitor = panel.monitorLevel / 0.45
        gains[Gain.monitor].aim(Float(monitor * monitor), frames: frames)
    }

    /// ±12 dB at 100 Hz and 10 kHz, shelving.
    private mutating func updateEqualiser(_ panel: Panel) {
        let wanted = (panel.eqHighL, panel.eqLowL, panel.eqHighR, panel.eqLowR)
        guard wanted != equaliserSettings else { return }
        equaliserSettings = wanted
        func decibels(_ value: Double) -> Double { (value - 0.5) * 26 }
        highL.setHighShelf(frequency: 3800, gainDB: decibels(wanted.0), slope: 0.6, sampleRate: sampleRate)
        lowL.setLowShelf(frequency: 260, gainDB: decibels(wanted.1), slope: 0.6, sampleRate: sampleRate)
        highR.setHighShelf(frequency: 3800, gainDB: decibels(wanted.2), slope: 0.6, sampleRate: sampleRate)
        lowR.setLowShelf(frequency: 260, gainDB: decibels(wanted.3), slope: 0.6, sampleRate: sampleRate)
        recordHighL.setHighShelf(frequency: 3800, gainDB: decibels(wanted.0), slope: 0.6, sampleRate: sampleRate)
        recordLowL.setLowShelf(frequency: 260, gainDB: decibels(wanted.1), slope: 0.6, sampleRate: sampleRate)
        recordHighR.setHighShelf(frequency: 3800, gainDB: decibels(wanted.2), slope: 0.6, sampleRate: sampleRate)
        recordLowR.setLowShelf(frequency: 260, gainDB: decibels(wanted.3), slope: 0.6, sampleRate: sampleRate)
    }

    @inline(__always)
    private static func clip(_ x: Float) -> Float {
        rail * Saturation.soft(x / rail)
    }

    // MARK: - Render

    /// Runs the machine for `frames` samples (at most `maximumFrames`),
    /// writing the headphone signal to `left` and `right`.
    ///
    /// ## Live and late
    /// Sound from the Mac's inputs reaches us late, by the round trip through
    /// its audio hardware; so it is written to the tape that much *earlier*,
    /// at the spot the performer was hearing when they played. Everything
    /// that does not make that trip — tape tracks, the rhythm box — is "late"
    /// signal: for the tape (and LINE OUT) it is held back by the same amount
    /// so that it lands where it belongs. The headphones hear both undelayed.
    mutating func render(
        frames: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        controls: ControlFrame
    ) -> Telemetry {
        guard frames > 0 else { return idleReport() }
        let panel = controls.panel
        if controls.transport.motion != requestedMotion {
            requestedMotion = controls.transport.motion
            deck.set(motion: requestedMotion)
        }
        aimGains(panel, frames: frames)
        updateEqualiser(panel)
        effect.apply(controls.effect)
        recordEffect.apply(controls.effect)

        let pitch = (panel.pitch - 0.5) * 2
        let noiseReduction = panel.noiseReduction
        let remix = panel.remix
        let monitorSource = panel.monitor
        let metersShowMixer = panel.metersShowMixer
        let mic1: Float = panel.micGain1 ? 10 : 1
        let mic2: Float = panel.micGain2 ? 10 : 1
        let latency = min(Self.historySize - 4, max(0, controls.recordLatency))
        let internalJacks = controls.internalJacks
        let twinEffect = latency > 0 && controls.effect.connected
        if latency > 0 && previousLatency == 0 {
            // The tape's own copy of the buss is only worked out while there
            // is a round trip to allow for. When one appears, start that copy
            // from exactly where the monitor buss is now.
            recordHighL = highL
            recordLowL = lowL
            recordHighR = highR
            recordLowR = lowR
            recordCouplingL = couplingL
            recordCouplingR = couplingR
        }
        previousLatency = latency
        let mask = Self.historyMask
        let span = Self.maximumFrames

        var armed: UInt8 = 0
        if let track = panel.armedFromLeft { armed |= 1 << UInt8(track) }
        if let track = panel.armedFromRight { armed |= 1 << UInt8(track) }
        let recordWanted = (controls.transport.recordKey || controls.transport.punch)
            && !recordProtected && !controls.recordInhibit && medium != nil
        let tape = medium
        var anyRecording = false
        var sentinel: Float = 0

        for frame in 0..<frames {
            deck.advance(pitch: pitch)
            let playing = deck.motion == .play
            let recordOn = recordWanted && playing
            // The head only touches the tape while the pinch roller has it.
            let contact: Float = deck.isRolling ? Float(min(1, deck.capstan * 2.5)) : 0
            positions[clock & mask] = deck.oxideFrame

            // --- Off the tape -------------------------------------------------
            if let tape, contact > 0 {
                let position = deck.oxideFrame
                let whole = position.rounded(.down)
                let base = Int(whole)
                let fraction = Float(position - whole)
                for track in 0..<Self.trackCount {
                    raw[track] = hermite(
                        tape.read(track: track, frame: base - 1),
                        tape.read(track: track, frame: base),
                        tape.read(track: track, frame: base + 1),
                        tape.read(track: track, frame: base + 2),
                        fraction)
                }
            } else {
                for track in 0..<Self.trackCount { raw[track] = 0 }
            }

            var inputMonitor: UInt8 = 0
            for track in 0..<Self.trackCount {
                let isArmed = armed & (1 << UInt8(track)) != 0
                if isArmed && (recordOn || !playing) {
                    // Input monitor: the track passes on what it is being fed.
                    inputMonitor |= 1 << UInt8(track)
                    trackOut[track] = track & 1 == 0 ? previousLineL : previousLineR
                } else if contact > 0 {
                    var signal = raw[track]
                    if track > 0 { signal += Self.crosstalk * raw[track - 1] + leak[track - 1] }
                    if track < Self.trackCount - 1 { signal += Self.crosstalk * raw[track + 1] + leak[track + 1] }
                    trackOut[track] = channels[track].play(signal, contact: contact, noiseReduction: noiseReduction)
                } else {
                    trackOut[track] = 0
                }
            }

            // --- Channels 1–2 ------------------------------------------------
            var auxLive: Float = 0
            var auxLate: Float = 0
            var liveL = noise.next() * Self.floorNoise
            var liveR = noise.next() * Self.floorNoise
            var lateL: Float = 0
            var lateR: Float = 0

            let post1 = Saturation.soft(jacks[frame] * mic1) * gains[Gain.fader].next()
            let send1 = post1 * gains[Gain.aux12].next()
            let left1 = post1 * gains[Gain.panL].next()
            let right1 = post1 * gains[Gain.panR].next()
            if internalJacks & 0b01 != 0 {
                auxLate += send1
                lateL += left1
                lateR += right1
            } else {
                auxLive += send1
                liveL += left1
                liveR += right1
            }

            let post2 = Saturation.soft(jacks[span + frame] * mic2) * gains[Gain.fader + 1].next()
            let send2 = post2 * gains[Gain.aux12 + 1].next()
            let left2 = post2 * gains[Gain.panL + 1].next()
            let right2 = post2 * gains[Gain.panR + 1].next()
            if internalJacks & 0b10 != 0 {
                auxLate += send2
                lateL += left2
                lateR += right2
            } else {
                auxLive += send2
                liveL += left2
                liveR += right2
            }

            // --- Channels 3–6 and the sub mix ---------------------------------
            var subLiveL: Float = 0
            var subLiveR: Float = 0
            var subLateL: Float = 0
            var subLateR: Float = 0
            for channel in 0..<Self.trackCount {
                let line = Self.clip(jacks[(2 + channel) * span + frame])
                let track = trackOut[channel]
                let lineIsLate = internalJacks & (0b100 << UInt8(channel)) != 0
                // An input-monitored track is passing on the buss, not the tape.
                let trackIsLive = inputMonitor & (1 << UInt8(channel)) != 0

                let sendLine = line * gains[Gain.auxInput + channel].next()
                let sendTrack = track * gains[Gain.auxTrack + channel].next()
                if lineIsLate { auxLate += sendLine } else { auxLive += sendLine }
                if trackIsLive { auxLive += sendTrack } else { auxLate += sendTrack }

                let fromLine = line * gains[Gain.subInput + channel].next()
                let fromTrack = track * gains[Gain.subTrack + channel].next()
                let panL = gains[Gain.subPanL + channel].next()
                let panR = gains[Gain.subPanR + channel].next()
                let live = (lineIsLate ? 0 : fromLine) + (trackIsLive ? fromTrack : 0)
                let late = (lineIsLate ? fromLine : 0) + (trackIsLive ? 0 : fromTrack)
                subLiveL += live * panL
                subLiveR += live * panR
                subLateL += late * panL
                subLateR += late * panR
            }

            // --- AUX buss and the effect loop ---------------------------------
            let send = gains[Gain.auxSend].next()
            let returnL = gains[Gain.returnL].next()
            let returnR = gains[Gain.returnR].next()
            let auxSum = auxLive + auxLate
            let auxOut = Self.clip(auxSum) * send
            let wet = effect.process(auxOut)

            // --- Stereo buss → EQ → MASTER -------------------------------------
            if remix {
                liveL += subLiveL
                liveR += subLiveR
                lateL += subLateL
                lateR += subLateR
            }
            let master = gains[Gain.master].next()
            let mixedL = lowL.process(highL.process(liveL + lateL + wet.left * returnL))
            let mixedR = lowR.process(highR.process(liveR + lateR + wet.right * returnR))
            let lineL = couplingL.process(Self.clip(mixedL)) * master
            let lineR = couplingR.process(Self.clip(mixedR)) * master
            previousLineL = lineL
            previousLineR = lineR

            // The same buss as the tape hears it: late signal held back.
            tapeBussL[clock & mask] = lateL
            tapeBussR[clock & mask] = lateR
            lateAux[clock & mask] = auxLate
            var tapedL = mixedL
            var tapedR = mixedR
            var recordL = lineL
            var recordR = lineR
            if latency > 0 {
                let heldL = tapeBussL[(clock - latency) & mask]
                let heldR = tapeBussR[(clock - latency) & mask]
                var wetForTape = wet
                if twinEffect {
                    let heldAux = lateAux[(clock - latency) & mask]
                    wetForTape = recordEffect.process(Self.clip(auxLive + heldAux) * send)
                }
                tapedL = recordLowL.process(recordHighL.process(liveL + heldL + wetForTape.left * returnL))
                tapedR = recordLowR.process(recordHighR.process(liveR + heldR + wetForTape.right * returnR))
                recordL = recordCouplingL.process(Self.clip(tapedL)) * master
                recordR = recordCouplingR.process(Self.clip(tapedR)) * master
            }
            lineOut[frame] = recordL
            lineOut[span + frame] = recordR

            // Everything that could carry a non-number, before any clipping
            // has had the chance to hide it.
            sentinel = mixedL + mixedR + tapedL + tapedR + auxSum + wet.left + wet.right
                + trackOut[0] + trackOut[1] + trackOut[2] + trackOut[3]

            // --- Onto the tape ---------------------------------------------------
            let writeNow = positions[(clock - latency) & mask]
            let writePrevious = positions[(clock - latency - 1) & mask]
            let travelled = writeNow - writePrevious
            for track in 0..<Self.trackCount {
                let recording = recordOn && armed & (1 << UInt8(track)) != 0
                var head = heads[track]
                if !recording && head.bias <= 0 && head.erase <= 0 {
                    leak[track] = 0
                    continue
                }
                anyRecording = anyRecording || recording
                if recording {
                    // Bias and erase current come up as tape passes the
                    // head, so the start of a take always fades in.
                    if travelled > 0 {
                        head.bias = min(1, head.bias + biasStep)
                        head.erase = min(1, head.erase + eraseStep)
                    }
                } else {
                    head.bias = max(0, head.bias - biasStep)
                    head.erase = max(0, head.erase - eraseStep)
                }

                let magnetisation = channels[track].record(track & 1 == 0 ? recordL : recordR, noiseReduction: noiseReduction)
                head.h0 = head.h1
                head.h1 = head.h2
                head.h2 = head.h3
                head.h3 = magnetisation
                leak[track] = Self.recordLeak * head.bias * (magnetisation - head.leak.process(magnetisation))

                if let tape, travelled > 0, travelled < 16 {
                    var index = Int(writePrevious.rounded(.down)) + 1
                    let last = Int(writeNow.rounded(.down))
                    let keep = 1 - head.bias * (1 - Self.biasErasure)
                    while index <= last {
                        let t = Float((Double(index) - writePrevious) / travelled)
                        let fresh = hermite(head.h0, head.h1, head.h2, head.h3, t)
                        let old = tape.read(track: track, frame: index)
                        tape.write(track: track, frame: index, value: old * keep + fresh * head.bias)
                        // The erase head sits upstream: it is already wiping
                        // tape the record head will not reach for a quarter
                        // of a second.
                        if head.erase >= 1 {
                            tape.erase(track: track, frame: index + eraseGapFrames)
                        } else if head.erase > 0 {
                            let ahead = index + eraseGapFrames
                            tape.write(track: track, frame: ahead, value: tape.read(track: track, frame: ahead) * (1 - head.erase))
                        }
                        index += 1
                    }
                }
                heads[track] = head
            }

            // --- Headphones --------------------------------------------------
            var monitorL: Float
            var monitorR: Float
            switch monitorSource {
            case .lineAndAux:
                monitorL = lineL + auxOut
                monitorR = lineR + auxOut
            case .aux:
                monitorL = auxOut
                monitorR = auxOut
            case .lineAndSubMix:
                monitorL = lineL
                monitorR = lineR
                if !remix {
                    monitorL += subLiveL + subLateL
                    monitorR += subLiveR + subLateR
                }
            }
            let monitorGain = gains[Gain.monitor].next()
            left[frame] = Saturation.soft(monitorL * monitorGain)
            right[frame] = Saturation.soft(monitorR * monitorGain)

            // --- Meters ----------------------------------------------------------
            for column in 0..<Self.trackCount {
                var level: Float
                if metersShowMixer {
                    switch column {
                    case 0: level = abs(lineL)
                    case 1: level = abs(lineR)
                    case 3: level = abs(auxOut)
                    default: level = 0
                    }
                } else {
                    level = abs(trackOut[column])
                }
                let envelope = meters[column]
                meters[column] = envelope + (level > envelope ? meterAttack : meterRelease) * (level - envelope)
            }

            clock &+= 1
        }

        // A fuse. Nothing above should ever produce a non-number, but if it
        // did it would circulate in the filters for ever: clear them instead.
        if !sentinel.isFinite {
            blowFuse()
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            lineOut.update(repeating: 0, count: 2 * Self.maximumFrames)
        }

        mechanics.render(
            left: left, right: right, frames: frames,
            windSpeed: deck.windSpeed, windTop: deck.windTopSpeed, capstan: deck.capstan,
            level: controls.mechanicalLevel)
        // The clunks ride on top of the headphone signal: keep the sum legal.
        for frame in 0..<frames {
            left[frame] = max(-1, min(1, left[frame]))
            right[frame] = max(-1, min(1, right[frame]))
        }

        // --- Report -----------------------------------------------------------
        var report = idleReport()
        report.isRecording = anyRecording
        let playing = deck.motion == .play
        for track in 0..<Self.trackCount {
            report.meters[track] = meters[track] / Level.reference
            let isArmed = armed & (1 << UInt8(track)) != 0
            if isArmed && recordWanted && playing {
                report.lamps[track] = TrackLamp.recording.rawValue
            } else if isArmed && !playing {
                report.lamps[track] = TrackLamp.standby.rawValue
            } else {
                report.lamps[track] = TrackLamp.tape.rawValue
            }
        }
        return report
    }
}
