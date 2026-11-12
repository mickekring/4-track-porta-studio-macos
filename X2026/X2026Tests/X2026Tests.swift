import Foundation
import Testing
@testable import X2026

/// A machine on the bench: no audio hardware, just the core run by hand.
final class Rig {
    static let sampleRate = 48_000.0

    let core = MachineCore()
    var controls = ControlFrame()
    let medium: TapeMedium
    let stock: TapeStock
    private let url: URL
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var clock = 0

    /// Frames of leader before the oxide begins.
    var leader: Double { stock.leaderLength * CassetteStandard.framesPerMeter }

    init(stock: TapeStock = .c60, secondsIntoTape: Double = 2, flipped: Bool = false) throws {
        self.stock = stock
        url = FileManager.default.temporaryDirectory.appending(path: "x2026-test-\(UUID().uuidString).pcm")
        medium = try TapeMedium(url: url, frameCount: stock.frameCount, flipped: flipped)
        left = .allocate(capacity: 512)
        right = .allocate(capacity: 512)
        core.prepare(sampleRate: Self.sampleRate)
        controls.mechanicalLevel = 0
        insert(secondsIntoTape: secondsIntoTape)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        try? FileManager.default.removeItem(at: url)
    }

    func insert(secondsIntoTape: Double, recordProtected: Bool = false) {
        core.insert(
            medium: medium, stock: stock,
            position: leader + secondsIntoTape * CassetteStandard.sampleRate,
            recordProtected: recordProtected)
    }

    /// Runs the machine for `seconds`, feeding `signal(sampleIndex)` into input
    /// jack `jack`. Returns what came out of the left and right headphone.
    @discardableResult
    func run(seconds: Double, jack: Int = 0, signal: ((Int) -> Float)? = nil) -> (left: [Float], right: [Float]) {
        var outL: [Float] = []
        var outR: [Float] = []
        var remaining = Int(seconds * Self.sampleRate)
        outL.reserveCapacity(remaining)
        outR.reserveCapacity(remaining)
        while remaining > 0 {
            let frames = min(512, remaining)
            for index in 0..<MachineDSP.jackCount {
                let buffer = core.jacks + index * MachineCore.maximumFrames
                for frame in 0..<frames {
                    buffer[frame] = index == jack ? (signal?(clock + frame) ?? 0) : 0
                }
            }
            core.controls.post(controls)
            core.render(frames: frames, left: left, right: right)
            outL.append(contentsOf: UnsafeBufferPointer(start: left, count: frames))
            outR.append(contentsOf: UnsafeBufferPointer(start: right, count: frames))
            clock += frames
            remaining -= frames
        }
        return (outL, outR)
    }

    var telemetry: Telemetry { core.telemetry.read() ?? Telemetry() }

    /// Oxide frame under the head right now.
    var oxideFrame: Int { Int(core.tapePosition - leader) }

    func tape(track: Int, from start: Int, count: Int) -> [Float] {
        (start..<(start + count)).map { medium.read(track: track, frame: $0) }
    }
}

func rms(_ samples: some Collection<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

func decibels(_ ratio: Float) -> Float { 20 * log10(max(ratio, 1e-9)) }

func sine(_ frequency: Double, amplitude: Float = Level.reference) -> (Int) -> Float {
    { index in amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / Rig.sampleRate)) }
}

/// Frequency estimated from upward zero crossings.
func frequency(of samples: [Float], sampleRate: Double = Rig.sampleRate) -> Double {
    var first: Double?
    var last = 0.0
    var count = 0
    for index in 1..<samples.count where samples[index - 1] < 0 && samples[index] >= 0 {
        let crossing = Double(index - 1) + Double(-samples[index - 1] / (samples[index] - samples[index - 1]))
        if first == nil { first = crossing } else { count += 1 }
        last = crossing
    }
    guard let first, count > 0 else { return 0 }
    return Double(count) * sampleRate / (last - first)
}

// MARK: - Transport

@Suite("Transport")
struct TransportTests {
    private func wind(_ motion: TapeDeck.Motion, stock: TapeStock, fromEnd: Bool) -> (seconds: Double, earlySpeed: Double, lateSpeed: Double) {
        var deck = TapeDeck()
        deck.configure(sampleRate: 8000)
        let total = stock.totalLength * CassetteStandard.framesPerMeter
        deck.load(stock: stock, position: fromEnd ? total : 0)
        deck.set(motion: motion)
        var samples = 0
        var early = 0.0
        var late = 0.0
        while deck.motion != .stop && samples < 8000 * 400 {
            deck.advance(pitch: 0)
            samples += 1
            if samples == 8000 * 10 { early = abs(deck.velocity) }
            if samples == 8000 * 95 { late = abs(deck.velocity) }
        }
        print("wind \(motion) \(stock.name): \(Double(samples) / 8000) s, early \(early), late \(late) frames/sample")
        return (Double(samples) / 8000, early, late)
    }

    @Test("A C-60 fast-forwards end to end in the 105 seconds the manual specifies")
    func fastForwardTime() {
        let result = wind(.fastForward, stock: .c60, fromEnd: false)
        // 105 s of winding plus the moment the auto-stop takes to trip.
        #expect(abs(result.seconds - 105.5) < 1.5)
    }

    @Test("Rewind takes just as long")
    func rewindTime() {
        let result = wind(.rewind, stock: .c60, fromEnd: true)
        #expect(abs(result.seconds - 105.5) < 1.5)
    }

    @Test("Tape runs faster as the driven reel fills up")
    func windSpeedsUp() {
        let result = wind(.fastForward, stock: .c60, fromEnd: false)
        #expect(result.lateSpeed > result.earlySpeed * 1.5)
    }

    @Test("A C-90 has more turns of thinner tape and takes longer")
    func longerTapeTakesLonger() {
        let c60 = wind(.fastForward, stock: .c60, fromEnd: false)
        let c90 = wind(.fastForward, stock: .c90, fromEnd: false)
        #expect(c90.seconds > c60.seconds * 1.3)
    }

    @Test("Play runs at 1⅞ ips and the pitch knob moves it ten percent")
    func playSpeed() {
        for (pitch, expected) in [(0.0, 1.0), (1.0, 1.1), (-1.0, 0.9)] {
            var deck = TapeDeck()
            deck.configure(sampleRate: 48_000)
            deck.load(stock: .c60, position: 100_000)
            deck.set(motion: .play)
            for _ in 0..<48_000 { deck.advance(pitch: pitch) }
            let start = deck.position
            for _ in 0..<(48_000 * 4) { deck.advance(pitch: pitch) }
            let speed = (deck.position - start) / (48_000 * 4)
            #expect(abs(speed - expected) < 0.002)
        }
    }

    @Test("Playing off the end of the tape trips the auto-stop")
    func autoStop() {
        var deck = TapeDeck()
        deck.configure(sampleRate: 48_000)
        let total = TapeStock.c46.totalLength * CassetteStandard.framesPerMeter
        deck.load(stock: .c46, position: total - 24_000)
        deck.set(motion: .play)
        for _ in 0..<(48_000 * 2) { deck.advance(pitch: 0) }
        #expect(deck.motion == .stop)
        #expect(deck.autoStopCount == 1)
        #expect(deck.position == total)
    }

    @Test("Reel geometry is consistent")
    func geometry() {
        let geometry = ReelGeometry(stock: .c60)
        // A full C-60 pack is about 50 mm across.
        #expect(abs(geometry.fullRadius * 2 - 0.0505) < 0.002)
        let wound = 37.5
        #expect(abs(geometry.wound(turns: geometry.turns(wound: wound)) - wound) < 1e-6)
        #expect(abs(geometry.supplyTurns(at: geometry.totalLength) - geometry.fullTurns) < 1e-9)
    }

    @Test("Counter wheels carry like an odometer")
    @MainActor
    func counterWheels() {
        #expect(TapeCounterView.wheelPositions(for: 0) == [0, 0, 0])
        #expect(TapeCounterView.wheelPositions(for: 123) == [1, 2, 3])
        // Half way through 9 → 10: the tens wheel is half way too.
        let rolling = TapeCounterView.wheelPositions(for: 9.5)
        #expect(abs(rolling[1] - 0.5) < 1e-9)
        #expect(rolling[0] == 0)
        // 199.5 → both upper wheels are mid-roll.
        let cascade = TapeCounterView.wheelPositions(for: 199.5)
        #expect(abs(cascade[0] - 1.5) < 1e-9)
        #expect(abs(cascade[1] - 9.5) < 1e-9)
        // Rewinding past zero wraps to 999.
        #expect(TapeCounterView.wheelPositions(for: -1) == [9, 9, 9])
    }
}

// MARK: - Recording

@Suite("Recorder")
struct RecorderTests {
    /// Input 1 → fader at unity → panned hard left → MASTER at unity → track 1.
    private func armTrackOne(_ rig: Rig) {
        rig.controls.panel = Panel()
        rig.controls.panel.fader1 = 0.75
        rig.controls.panel.pan1 = 0
        rig.controls.panel.master = 0.75
        rig.controls.panel.recordL = .upper
    }

    /// Tracks → sub mix → REMIX → stereo buss → headphones, all at unity.
    private func mixdown(_ rig: Rig, tracks: [Int] = [0]) {
        rig.controls.panel = Panel()
        for track in tracks {
            rig.controls.panel.subGain[track] = 0.8
            rig.controls.panel.subPan[track] = 0
        }
        rig.controls.panel.remix = true
        rig.controls.panel.monitor = .lineAndSubMix
        rig.controls.panel.master = 0.75
        rig.controls.panel.monitorLevel = 0.45
    }

    @Test("What you record is what you get back: level and pitch survive the tape")
    func roundTrip() throws {
        let rig = try Rig()
        armTrackOne(rig)
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        let start = rig.oxideFrame
        rig.run(seconds: 3, signal: sine(1000))
        rig.controls.transport = TransportRequest()
        rig.run(seconds: 0.3)

        // On the oxide: close to reference level.
        let recorded = rig.tape(track: 0, from: start + 48_000, count: 48_000)
        #expect(abs(decibels(rms(recorded) / (Level.reference * 0.7071))) < 1.5)
        // The other tracks were not armed and stay blank.
        #expect(rms(rig.tape(track: 1, from: start + 48_000, count: 48_000)) == 0)
        #expect(rms(rig.tape(track: 2, from: start + 48_000, count: 48_000)) == 0)

        // Put the tape back where we started and play it.
        rig.core.eject()
        rig.insert(secondsIntoTape: 2)
        mixdown(rig)
        rig.controls.transport = TransportRequest(motion: .play)
        let played = rig.run(seconds: 3).left
        let steady = Array(played[48_000..<(48_000 * 2)])
        #expect(abs(decibels(rms(steady) / (Level.reference * 0.7071))) < 2)
        #expect(abs(frequency(of: steady) - 1000) < 4)
        // Panned hard left: nothing but hiss on the right.
    }

    @Test("RECORD with no track armed just plays, and the tape is untouched")
    func recordSafe() throws {
        let rig = try Rig()
        armTrackOne(rig)
        rig.controls.panel.recordL = .off
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        let start = rig.oxideFrame
        rig.run(seconds: 1, signal: sine(440))
        #expect(rms(rig.tape(track: 0, from: start, count: 40_000)) == 0)
        #expect(rig.telemetry.lamps[0] == TrackLamp.tape.rawValue)
        #expect(!rig.telemetry.isRecording)
    }

    @Test("A cassette with its tabs broken out refuses to record")
    func recordProtect() throws {
        let rig = try Rig()
        rig.core.eject()
        rig.insert(secondsIntoTape: 2, recordProtected: true)
        armTrackOne(rig)
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        let start = rig.oxideFrame
        rig.run(seconds: 1, signal: sine(440))
        #expect(rms(rig.tape(track: 0, from: start, count: 40_000)) == 0)
    }

    @Test("Nothing records on the leader")
    func leader() throws {
        let rig = try Rig(secondsIntoTape: -3)
        armTrackOne(rig)
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        rig.run(seconds: 2, signal: sine(440))
        // Still a second short of the oxide: the file has not been touched.
        #expect(rig.oxideFrame < 0)
        #expect(rms(rig.tape(track: 0, from: 0, count: 48_000)) == 0)
    }

    @Test("Lamps: amber when armed and stopped, green in play, red when recording")
    func lamps() throws {
        let rig = try Rig()
        armTrackOne(rig)
        rig.run(seconds: 0.1)
        #expect(rig.telemetry.lamps[0] == TrackLamp.standby.rawValue)
        #expect(rig.telemetry.lamps[1] == TrackLamp.tape.rawValue)

        rig.controls.transport = TransportRequest(motion: .play)
        rig.run(seconds: 0.2)
        #expect(rig.telemetry.lamps[0] == TrackLamp.tape.rawValue)

        // Foot switch.
        rig.controls.transport.punch = true
        rig.run(seconds: 0.2)
        #expect(rig.telemetry.lamps[0] == TrackLamp.recording.rawValue)
        #expect(rig.telemetry.isRecording)

        rig.controls.transport.punch = false
        rig.run(seconds: 0.2)
        #expect(rig.telemetry.lamps[0] == TrackLamp.tape.rawValue)
    }

    @Test("An armed track monitors its input when stopped, and the tape in play")
    func inputMonitor() throws {
        let rig = try Rig()
        armTrackOne(rig)
        // Listen to track 1 through AUX 3, as the manual's first-track procedure does.
        rig.controls.panel.aux[0] = 0.8
        rig.controls.panel.auxSend = 0.6
        rig.controls.panel.monitor = .aux
        rig.controls.panel.monitorLevel = 0.45
        let stopped = rig.run(seconds: 0.5, signal: sine(1000)).left
        #expect(decibels(rms(stopped[12_000...]) / (Level.reference * 0.7071)) > -3)

        // In play the armed track switches to the (blank) tape: the instrument cuts out.
        rig.controls.transport = TransportRequest(motion: .play)
        let playing = rig.run(seconds: 0.5, signal: sine(1000)).left
        #expect(decibels(rms(playing[12_000...]) / (Level.reference * 0.7071)) < -35)
    }

    @Test("Punching out leaves the erase-head gap; punching in overlaps the old take")
    func punchGap() throws {
        let rig = try Rig()
        armTrackOne(rig)
        // Lay down a bed of 300 Hz.
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        let start = rig.oxideFrame
        rig.run(seconds: 4, signal: sine(300))
        rig.controls.transport = TransportRequest()
        rig.run(seconds: 0.3)

        // Go back, play, and punch 2 kHz in for one second in the middle.
        rig.core.eject()
        rig.insert(secondsIntoTape: 2)
        rig.controls.transport = TransportRequest(motion: .play)
        rig.run(seconds: 1.5, signal: sine(2000))
        let punchIn = rig.oxideFrame
        rig.controls.transport.punch = true
        rig.run(seconds: 1, signal: sine(2000))
        let punchOut = rig.oxideFrame
        rig.controls.transport.punch = false
        rig.run(seconds: 1, signal: sine(2000))

        let gap = Int(CassetteStandard.eraseToRecordGap * CassetteStandard.framesPerMeter)
        let bed = rms(rig.tape(track: 0, from: start + 24_000, count: 12_000))

        // Just after the punch-in the old tone is still under the new one…
        let overlap = rig.tape(track: 0, from: punchIn + 2000, count: gap - 4000)
        // …and once the erased tape arrives, only the new one is left.
        let clean = rig.tape(track: 0, from: punchIn + gap + 2000, count: 12_000)
        #expect(abs(frequency(of: clean) - 2000) < 20)
        #expect(rms(overlap) > rms(clean) * 1.005)

        // After the punch-out: a quarter of a second of nothing, then the bed again.
        let silence = rig.tape(track: 0, from: punchOut + 1500, count: gap - 3000)
        #expect(rms(silence) < bed * 0.01)
        let after = rig.tape(track: 0, from: punchOut + gap + 2000, count: 12_000)
        #expect(abs(decibels(rms(after) / bed)) < 0.5)
        #expect(abs(frequency(of: after) - 300) < 5)
    }

    @Test("Side B is the same oxide read backwards, with the track order reversed")
    func flipped() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "x2026-flip-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let sideA = try TapeMedium(url: url, frameCount: 1000)
            sideA.write(track: 0, frame: 10, value: 0.5)
            sideA.write(track: 1, frame: 11, value: -0.25)
        }
        let sideB = try TapeMedium(url: url, frameCount: 1000, flipped: true)
        #expect(abs(sideB.read(track: 3, frame: 989) - 0.5) < 0.001)
        #expect(abs(sideB.read(track: 2, frame: 988) + 0.25) < 0.001)
        #expect(sideB.read(track: 0, frame: 10) == 0)
    }

    @Test("A bounce lands in time with its source, even with audio-hardware latency compensated")
    func bounceAlignment() throws {
        for latency in [0, 700] {
            let rig = try Rig()
            rig.controls.recordLatency = latency
            // Track 1: a single click, written straight onto the oxide.
            let click = rig.oxideFrame + 48_000
            for offset in 0..<40 {
                rig.medium.write(track: 0, frame: click + offset, value: offset < 20 ? 0.5 : -0.5)
            }
            // Bounce track 1 → track 2: sub mix, REMIX, panned right, track 2 armed.
            rig.controls.panel = Panel()
            rig.controls.panel.noiseReduction = false
            rig.controls.panel.subGain[0] = 0.8
            rig.controls.panel.subPan[0] = 1
            rig.controls.panel.remix = true
            rig.controls.panel.master = 0.75
            rig.controls.panel.recordR = .upper
            rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
            rig.run(seconds: 2)

            let copy = rig.tape(track: 1, from: click - 2000, count: 4000)
            let peak = copy.indices.max { abs(copy[$0]) < abs(copy[$1]) }!
            let landed = click - 2000 + peak
            // Within a millisecond of the original (the playback filters add a little delay).
            #expect(abs(landed - (click + 10)) < 48, "latency \(latency): landed \(landed - click) frames from the source")
        }
    }

    @Test("Live overdubs are written where the performer heard them")
    func overdubAlignment() throws {
        // A note played exactly as the head passes `mark` only reaches the
        // machine `latency` samples later. It must still be written at `mark`.
        let latency = 960
        let rig = try Rig()
        rig.controls.recordLatency = latency
        armTrackOne(rig)
        rig.controls.panel.noiseReduction = false
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        rig.run(seconds: 1)
        let mark = rig.oxideFrame
        var clock = 0
        rig.run(seconds: 1) { _ in
            defer { clock += 1 }
            return (latency..<(latency + 24)).contains(clock) ? 0.5 : 0
        }
        let written = rig.tape(track: 0, from: mark - 500, count: 1500)
        let peak = written.indices.max { abs(written[$0]) < abs(written[$1]) }!
        #expect(abs((mark - 500 + peak) - (mark + 12)) < 30)
    }
}

// MARK: - Sound

@Suite("Sound")
struct SoundTests {
    @Test("Noise reduction decodes what it encodes")
    func noiseReductionRoundTrip() {
        var encoder = NoiseReduction(sampleRate: 48_000)
        var decoder = NoiseReduction(sampleRate: 48_000)
        var worst: Float = 0
        var boosted: Float = 0
        var plain: Float = 0
        for index in 0..<48_000 {
            let t = Double(index) / 48_000
            // Quiet treble riding on a louder low note.
            let x = Float(0.004 * sin(2 * .pi * 6000 * t) + 0.05 * sin(2 * .pi * 220 * t) * sin(.pi * t))
            let y = encoder.encode(x)
            worst = max(worst, abs(decoder.decode(y) - x))
            if index > 24_000 {
                boosted += y * y
                plain += x * x
            }
        }
        #expect(worst < 1e-4)
        #expect(boosted > plain)
    }

    @Test("Quiet treble goes onto the tape up to 10 dB hotter with noise reduction")
    func noiseReductionBoost() {
        var encoder = NoiseReduction(sampleRate: 48_000)
        var input: Float = 0
        var output: Float = 0
        for index in 0..<48_000 {
            let x = Float(0.0005 * sin(2 * Double.pi * 8000 * Double(index) / 48_000))
            let y = encoder.encode(x)
            if index > 24_000 {
                input += x * x
                output += y * y
            }
        }
        let lift = 10 * log10(output / input)
        #expect(lift > 8 && lift < 10.5)
    }

    @Test("The tape hisses, and noise reduction makes it hiss less")
    func hiss() throws {
        func noiseFloor(noiseReduction: Bool) throws -> Float {
            let rig = try Rig()
            rig.controls.panel = Panel()
            rig.controls.panel.noiseReduction = noiseReduction
            rig.controls.panel.subGain[0] = 0.8
            rig.controls.panel.subPan[0] = 0
            rig.controls.panel.remix = true
            rig.controls.panel.master = 0.75
            rig.controls.panel.monitorLevel = 0.45
            rig.controls.transport = TransportRequest(motion: .play)
            let out = rig.run(seconds: 2).left
            return decibels(rms(out[48_000...]) / (Level.reference * 0.7071))
        }
        let without = try noiseFloor(noiseReduction: false)
        let with = try noiseFloor(noiseReduction: true)
        #expect(without < -45 && without > -60)
        #expect(with < without - 4)
    }

    @Test("Hot levels saturate instead of clipping")
    func saturation() throws {
        let rig = try Rig()
        rig.controls.panel = Panel()
        rig.controls.panel.noiseReduction = false
        rig.controls.panel.fader1 = 0.75
        rig.controls.panel.pan1 = 0
        rig.controls.panel.master = 0.75
        rig.controls.panel.recordL = .upper
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        let start = rig.oxideFrame
        // 12 dB over the 0 mark.
        rig.run(seconds: 1, signal: sine(400, amplitude: 1.0))
        let recorded = rig.tape(track: 0, from: start + 12_000, count: 24_000)
        let peak = recorded.map(abs).max() ?? 0
        #expect(peak < 0.9)
        #expect(peak > 0.5)
    }

    @Test("The core runs comfortably faster than real time")
    func performance() throws {
        let rig = try Rig()
        rig.controls.panel = .readyToPlay
        rig.controls.panel.recordL = .upper
        rig.controls.panel.recordR = .upper
        rig.controls.effect.connected = true
        rig.controls.panel.auxSend = 0.6
        rig.controls.panel.aux = Quad(repeating: 0.8)
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        let clock = ContinuousClock()
        let seconds = 10.0
        let elapsed = clock.measure {
            rig.run(seconds: seconds, signal: sine(440))
        }
        let factor = seconds / (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
        print("X-2026 core: \(String(format: "%.1f", factor))× real time, worst case, this build configuration")
        #expect(factor > 3)
    }
}
