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
    private var previousLineL: Float = 0
    private var previousLineR: Float = 0

    private var meters = Quad<Float>(repeating: 0)
    private var meterAttack: Float = 0.1
    private var meterRelease: Float = 0.0001
    private var biasStep: Float = 0.002
    private var eraseStep: Float = 0.0015
    private var eraseGapFrames = 12_598

    private var effect = AuxEffect()
    private var mechanics = MechanicalSounds()
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
        mechanics.prepare(sampleRate: sampleRate)
        couplingL.setCutoff(6, sampleRate: sampleRate)
        couplingR.setCutoff(6, sampleRate: sampleRate)
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
        medium?.flush()
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
    mutating func render(
        frames: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        controls: ControlFrame
    ) -> Telemetry {
        let panel = controls.panel
        if controls.transport.motion != requestedMotion {
            requestedMotion = controls.transport.motion
            deck.set(motion: requestedMotion)
        }
        aimGains(panel, frames: frames)
        updateEqualiser(panel)
        effect.apply(controls.effect)

        let pitch = (panel.pitch - 0.5) * 2
        let noiseReduction = panel.noiseReduction
        let remix = panel.remix
        let monitorSource = panel.monitor
        let metersShowMixer = panel.metersShowMixer
        let mic1: Float = panel.micGain1 ? 10 : 1
        let mic2: Float = panel.micGain2 ? 10 : 1
        let latency = min(Self.historySize - 4, max(0, controls.recordLatency))
        let mask = Self.historyMask
        let span = Self.maximumFrames

        var armed: UInt8 = 0
        if let track = panel.armedFromLeft { armed |= 1 << UInt8(track) }
        if let track = panel.armedFromRight { armed |= 1 << UInt8(track) }
        let recordWanted = (controls.transport.recordKey || controls.transport.punch)
            && !recordProtected && medium != nil
        let tape = medium
        var anyRecording = false

        for frame in 0..<frames {
            deck.advance(pitch: pitch)
            let playing = deck.motion == .play
            let recordOn = recordWanted && playing
            let contact = Float(min(1, deck.capstan * 2.5))
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
            var aux: Float = 0
            var bussL = noise.next() * Self.floorNoise
            var bussR = noise.next() * Self.floorNoise

            let post1 = Saturation.soft(jacks[frame] * mic1) * gains[Gain.fader].next()
            aux += post1 * gains[Gain.aux12].next()
            bussL += post1 * gains[Gain.panL].next()
            bussR += post1 * gains[Gain.panR].next()

            let post2 = Saturation.soft(jacks[span + frame] * mic2) * gains[Gain.fader + 1].next()
            aux += post2 * gains[Gain.aux12 + 1].next()
            bussL += post2 * gains[Gain.panL + 1].next()
            bussR += post2 * gains[Gain.panR + 1].next()

            // --- Channels 3–6 and the sub mix ---------------------------------
            var subInputL: Float = 0
            var subInputR: Float = 0
            var subTapeL: Float = 0
            var subTapeR: Float = 0
            for channel in 0..<Self.trackCount {
                let line = Self.clip(jacks[(2 + channel) * span + frame])
                let track = trackOut[channel]
                aux += line * gains[Gain.auxInput + channel].next()
                    + track * gains[Gain.auxTrack + channel].next()
                let fromLine = line * gains[Gain.subInput + channel].next()
                let fromTrack = track * gains[Gain.subTrack + channel].next()
                let panL = gains[Gain.subPanL + channel].next()
                let panR = gains[Gain.subPanR + channel].next()
                if inputMonitor & (1 << UInt8(channel)) != 0 {
                    // An input-monitored track is live signal, not tape.
                    subInputL += (fromLine + fromTrack) * panL
                    subInputR += (fromLine + fromTrack) * panR
                } else {
                    subInputL += fromLine * panL
                    subInputR += fromLine * panR
                    subTapeL += fromTrack * panL
                    subTapeR += fromTrack * panR
                }
            }

            // --- AUX buss and the effect loop ---------------------------------
            let auxOut = Self.clip(aux) * gains[Gain.auxSend].next()
            let wet = effect.process(auxOut)
            bussL += wet.left * gains[Gain.returnL].next()
            bussR += wet.right * gains[Gain.returnR].next()

            // --- Stereo buss → EQ → MASTER -------------------------------------
            var tapeL: Float = 0
            var tapeR: Float = 0
            if remix {
                bussL += subInputL
                bussR += subInputR
                tapeL = subTapeL
                tapeR = subTapeR
            }
            let master = gains[Gain.master].next()
            let lineL = couplingL.process(Self.clip(lowL.process(highL.process(bussL + tapeL)))) * master
            let lineR = couplingR.process(Self.clip(lowR.process(highR.process(bussR + tapeR)))) * master

            // What goes to tape. Live inputs arrive late by the round trip
            // through the computer's audio hardware, so tape-derived signal
            // is held back by the same amount and both are written to the
            // spot on the tape the performer was actually hearing.
            var recordL = lineL
            var recordR = lineR
            if latency > 0 {
                tapeBussL[clock & mask] = tapeL
                tapeBussR[clock & mask] = tapeR
                let lateL = tapeBussL[(clock - latency) & mask]
                let lateR = tapeBussR[(clock - latency) & mask]
                recordL = Self.clip(recordLowL.process(recordHighL.process(bussL + lateL))) * master
                recordR = Self.clip(recordLowR.process(recordHighR.process(bussR + lateR))) * master
            }
            previousLineL = lineL
            previousLineR = lineR
            lineOut[frame] = recordL
            lineOut[span + frame] = recordR

            // --- Onto the tape ---------------------------------------------------
            let writeNow = positions[(clock - latency) & mask]
            let writePrevious = positions[(clock - latency - 1) & mask]
            for track in 0..<Self.trackCount {
                let recording = recordOn && armed & (1 << UInt8(track)) != 0
                var head = heads[track]
                if !recording && head.bias <= 0 && head.erase <= 0 {
                    leak[track] = 0
                    continue
                }
                anyRecording = anyRecording || recording
                head.bias = recording ? min(1, head.bias + biasStep) : max(0, head.bias - biasStep)
                head.erase = recording ? min(1, head.erase + eraseStep) : max(0, head.erase - eraseStep)

                let magnetisation = channels[track].record(track & 1 == 0 ? recordL : recordR, noiseReduction: noiseReduction)
                head.h0 = head.h1
                head.h1 = head.h2
                head.h2 = head.h3
                head.h3 = magnetisation
                leak[track] = Self.recordLeak * head.bias * (magnetisation - head.leak.process(magnetisation))

                let travelled = writeNow - writePrevious
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
                    monitorL += subInputL + subTapeL
                    monitorR += subInputR + subTapeR
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

        mechanics.render(
            left: left, right: right, frames: frames,
            windSpeed: deck.windSpeed, windTop: deck.windTopSpeed, capstan: deck.capstan,
            level: controls.mechanicalLevel)

        // --- Report -----------------------------------------------------------
        var report = Telemetry()
        report.hasTape = deck.hasTape
        report.position = deck.position
        report.motion = deck.motion
        report.capstan = Float(deck.capstan)
        report.windSpeed = Float(deck.windSpeed)
        report.autoStopCount = deck.autoStopCount
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
