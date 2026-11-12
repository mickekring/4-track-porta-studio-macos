import AVFoundation
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

/// Amplitude of the `target` Hz component of `samples`.
func component(_ target: Double, in samples: [Float], sampleRate: Double = Rig.sampleRate) -> Float {
    var real = 0.0
    var imaginary = 0.0
    for (index, sample) in samples.enumerated() {
        let phase = 2 * Double.pi * target * Double(index) / sampleRate
        real += Double(sample) * cos(phase)
        imaginary += Double(sample) * sin(phase)
    }
    return Float(2 * (real * real + imaginary * imaginary).squareRoot() / Double(max(1, samples.count)))
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

    @Test("Winding into either end of the tape trips the auto-stop at a real sample rate",
          arguments: [TapeDeck.Motion.fastForward, .rewind])
    func autoStopAfterWinding(motion: TapeDeck.Motion) {
        var deck = TapeDeck()
        deck.configure(sampleRate: 48_000)
        let total = TapeStock.c46.totalLength * CassetteStandard.framesPerMeter
        // Start a few metres from the end the tape is being wound towards.
        deck.load(stock: .c46, position: motion == .fastForward ? total - 4_000_000 : 4_000_000)
        deck.set(motion: motion)
        var samples = 0
        while deck.motion != .stop && samples < 48_000 * 30 {
            deck.advance(pitch: 0)
            samples += 1
        }
        #expect(deck.motion == .stop)
        #expect(deck.autoStopCount == 1)
        #expect(deck.position == (motion == .fastForward ? total : 0))
        #expect(deck.windSpeed == 0)
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
    }

    @Test("A track panned hard left leaves the right side with nothing but hiss")
    func panning() throws {
        let rig = try Rig()
        let start = rig.oxideFrame
        for offset in 0..<96_000 {
            rig.medium.write(track: 0, frame: start + offset, value: Level.reference * Float(sin(2 * Double.pi * 1000 * Double(offset) / 48_000)))
        }
        mixdown(rig)
        rig.controls.transport = TransportRequest(motion: .play)
        let out = rig.run(seconds: 1.5)
        let left = component(1000, in: Array(out.left[24_000...]))
        let right = component(1000, in: Array(out.right[24_000...]))
        #expect(left > Level.reference * 0.6)
        #expect(right < left * 0.01)
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

    @Test("Nothing records on the leader; the take begins where the oxide does")
    func leader() throws {
        let rig = try Rig(secondsIntoTape: -1)
        armTrackOne(rig)
        rig.controls.panel.noiseReduction = false
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        rig.run(seconds: 2.5, signal: sine(440))
        #expect(rig.oxideFrame > 48_000)
        // The second of tone played over the leader is simply gone, and the
        // oxide carries tone from its very first frames on.
        let opening = rig.tape(track: 0, from: 0, count: 2400)
        #expect(rms(opening) > Level.reference * 0.3)
        let later = rig.tape(track: 0, from: 24_000, count: 24_000)
        #expect(abs(decibels(rms(later) / (Level.reference * 0.7071))) < 1.5)
        // Nothing strays onto other tracks or far beyond the head.
        #expect(rms(rig.tape(track: 1, from: 0, count: 96_000)) == 0)
        #expect(rms(rig.tape(track: 0, from: rig.oxideFrame + 24_000, count: 48_000)) == 0)
    }

    @Test("At the far end the tape simply runs out")
    func trailer() throws {
        let rig = try Rig(stock: .c46)
        rig.core.eject()
        let frames = TapeStock.c46.frameCount
        rig.core.insert(
            medium: rig.medium, stock: .c46,
            position: rig.leader + Double(frames) - 48_000, recordProtected: false)
        armTrackOne(rig)
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        rig.run(seconds: 8, signal: sine(440))
        // Recorded up to the last frame of oxide, then auto-stop on the leader.
        #expect(rms(rig.tape(track: 0, from: frames - 24_000, count: 24_000)) > Level.reference * 0.3)
        #expect(rig.telemetry.motion == .stop)
        #expect(rig.telemetry.autoStopCount == 1)
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

        // Just after the punch-in the old 300 Hz is still there under the new
        // tone, knocked down by the record bias to roughly a fifth…
        let overlap = rig.tape(track: 0, from: punchIn + 2000, count: gap - 4000)
        let old = component(300, in: overlap)
        let bedLevel = component(300, in: rig.tape(track: 0, from: start + 24_000, count: gap - 4000))
        #expect(old > bedLevel * 0.1 && old < bedLevel * 0.3, "old take at \(old / bedLevel) of its level")
        #expect(component(2000, in: overlap) > Level.reference * 0.5)
        // …and once the erased tape arrives, only the new one is left.
        let clean = rig.tape(track: 0, from: punchIn + gap + 2000, count: 12_000)
        #expect(abs(frequency(of: clean) - 2000) < 20)
        #expect(component(300, in: clean) < bedLevel * 0.005)

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

    @Test("The rhythm box makes no trip through the audio hardware and is not compensated for one")
    func internalSourcesAreNotShifted() throws {
        let latency = 960
        let rig = try Rig()
        rig.controls.recordLatency = latency
        rig.controls.internalJacks = 0b01
        armTrackOne(rig)
        rig.controls.panel.noiseReduction = false
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        rig.run(seconds: 1)
        let mark = rig.oxideFrame
        var clock = 0
        // A drum hit generated exactly as the head passes `mark` belongs at `mark`.
        rig.run(seconds: 1) { _ in
            defer { clock += 1 }
            return clock < 24 ? 0.5 : 0
        }
        let written = rig.tape(track: 0, from: mark - 2000, count: 4000)
        let peak = written.indices.max { abs(written[$0]) < abs(written[$1]) }!
        #expect(abs((mark - 2000 + peak) - (mark + 12)) < 30, "landed \(mark - 2000 + peak - mark) frames from where it was played")
    }

    @Test("Reverb on a bounce lands with its dry signal, not ahead of it")
    func bouncedReverbIsAligned() throws {
        var landed: [Int] = []
        for latency in [0, 900] {
            let rig = try Rig()
            rig.controls.recordLatency = latency
            let click = rig.oxideFrame + 48_000
            for offset in 0..<24 { rig.medium.write(track: 0, frame: click + offset, value: 0.6) }
            // Track 1 → AUX only → echo → AUX RCV R → track 2. No dry path at all,
            // so whatever lands on track 2 is the effect's own timing.
            rig.controls.panel = Panel()
            rig.controls.panel.noiseReduction = false
            rig.controls.panel.aux[0] = 1
            rig.controls.panel.auxSend = 0.6
            rig.controls.panel.auxReturnR = 0.6
            rig.controls.panel.master = 0.75
            rig.controls.panel.recordR = .upper
            rig.controls.effect = AuxEffect.Settings(connected: true, mode: .echo, size: 0, colour: 0)
            rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
            rig.run(seconds: 2)
            let copy = rig.tape(track: 1, from: click, count: 12_000)
            let loudest = copy.map(abs).max() ?? 0
            #expect(loudest > 0.01)
            landed.append(copy.firstIndex { abs($0) > loudest * 0.5 } ?? -1)
        }
        // The single echo (70 ms) arrives the same distance after the click
        // whether or not the audio hardware's round trip is being compensated.
        #expect(abs(landed[0] - landed[1]) < 24, "echo at \(landed[0]) frames without latency, \(landed[1]) with")
        #expect(abs(landed[0] - 3360) < 200)
    }

    @Test("At 44.1 kHz the tape still runs at 1⅞ ips and pitch is kept")
    func otherSampleRate() throws {
        let rate = 44_100.0
        let url = FileManager.default.temporaryDirectory.appending(path: "x2026-44k-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: url) }
        let stock = TapeStock.c46
        let medium = try TapeMedium(url: url, frameCount: stock.frameCount)
        let core = MachineCore()
        core.prepare(sampleRate: rate)
        let leader = stock.leaderLength * CassetteStandard.framesPerMeter
        let start = leader + 2 * CassetteStandard.sampleRate
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 441)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 441)
        defer {
            left.deallocate()
            right.deallocate()
        }
        var clock = 0
        func run(seconds: Double, controls: ControlFrame, tone: Bool) -> [Float] {
            var out: [Float] = []
            core.controls.post(controls)
            for _ in 0..<Int(seconds * 100) {
                for frame in 0..<441 {
                    core.jacks[frame] = tone ? Level.reference * Float(sin(2 * Double.pi * 1000 * Double(clock + frame) / rate)) : 0
                }
                core.render(frames: 441, left: left, right: right)
                out.append(contentsOf: UnsafeBufferPointer(start: left, count: 441))
                clock += 441
            }
            return out
        }

        core.insert(medium: medium, stock: stock, position: start, recordProtected: false)
        var controls = ControlFrame()
        controls.mechanicalLevel = 0
        controls.panel = Panel()
        controls.panel.fader1 = 0.75
        controls.panel.pan1 = 0
        controls.panel.master = 0.75
        controls.panel.recordL = .upper
        controls.transport = TransportRequest(motion: .play, recordKey: true)
        _ = run(seconds: 3, controls: controls, tone: true)
        // Three seconds of machine time is three seconds of tape, whatever the device rate.
        #expect(abs((core.tapePosition - start) / CassetteStandard.sampleRate - 3) < 0.15)

        core.eject()
        core.insert(medium: medium, stock: stock, position: start, recordProtected: false)
        controls.panel = Panel()
        controls.panel.subGain[0] = 0.8
        controls.panel.subPan[0] = 0
        controls.panel.remix = true
        controls.panel.master = 0.75
        controls.panel.monitorLevel = 0.45
        controls.transport = TransportRequest(motion: .play)
        let played = run(seconds: 2.5, controls: controls, tone: false)
        let steady = Array(played[44_100..<88_200])
        #expect(abs(frequency(of: steady, sampleRate: rate) - 1000) < 4)
        #expect(abs(decibels(rms(steady) / (Level.reference * 0.7071))) < 2)
    }
}

// MARK: - Hosting

@Suite("Audio host")
struct AudioHostTests {
    @Test("When the input stops, the jacks go quiet instead of looping the last scraps")
    func ringGoesQuiet() {
        let ring = InputRing()
        ring.configure(channels: 1, inputRate: 48_000, outputRate: 48_000, targetFill: 256)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        samples.initialize(repeating: 0.5, count: 128)
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 128 * 4, mData: samples)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: InputRing.maximumChannels * 128)
        defer {
            samples.deallocate()
            out.deallocate()
            free(list.unsafeMutablePointer)
        }
        func block(writing: Bool) -> Float {
            if writing { ring.write(list.unsafePointer, frames: 128) }
            ring.read(into: out, stride: 128, frames: 128)
            return (0..<128).map { abs(out[$0]) }.max() ?? 0
        }

        var flowing: Float = 0
        for _ in 0..<20 { flowing = block(writing: true) }
        #expect(flowing == 0.5)

        // The input device goes away: after the reserve has drained, silence.
        var heard: Float = 0
        for index in 0..<200 {
            let level = block(writing: false)
            if index >= 4 { heard = max(heard, level) }
        }
        #expect(heard == 0)

        // It comes back: audio flows again.
        for _ in 0..<20 { flowing = block(writing: true) }
        #expect(flowing == 0.5)
    }

    @Test("The master recorder writes what it was fed, at the right length")
    func masterRecorder() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "x2026-master-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = MasterRecorder()
        recorder.sampleRate = 48_000
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        defer {
            left.deallocate()
            right.deallocate()
        }
        // Nothing is kept before REC is pressed.
        left.initialize(repeating: 0.25, count: 480)
        right.initialize(repeating: -0.25, count: 480)
        recorder.capture(left: left, right: right, frames: 480)
        #expect(!recorder.isRecording)
        #expect(abs(recorder.levels.left - 1) < 0.01)

        try recorder.begin(url: url)
        var clock = 0
        for _ in 0..<150 {
            for frame in 0..<480 {
                left[frame] = Level.reference * Float(sin(2 * Double.pi * 440 * Double(clock + frame) / 48_000))
                right[frame] = 0
            }
            recorder.capture(left: left, right: right, frames: 480)
            clock += 480
            Thread.sleep(forTimeInterval: 0.002)
        }
        #expect(abs(recorder.elapsed - 1.5) < 0.001)
        let finished = try #require(recorder.end())
        #expect(!recorder.isRecording)

        let file = try AVAudioFile(forReading: finished)
        #expect(file.length == 72_000)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.channelCount == 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 72_000))
        try file.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        let recorded = Array(UnsafeBufferPointer(start: channels[0], count: 72_000))
        // The 0 mark is lifted to about -6 dBFS on the way to the file.
        #expect(abs(component(440, in: recorded) - Level.reference * 2) < 0.01)
        #expect(Array(UnsafeBufferPointer(start: channels[1], count: 72_000)).allSatisfy { $0 == 0 })
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

    @Test("An armed track routed back to its own buss howls, stays bounded, and recovers")
    func feedbackIsBounded() throws {
        let rig = try Rig()
        rig.controls.panel = Panel()
        // The loop the manual warns about: track 1 armed, SUB GAIN 3 towards
        // TRK 1, REMIX on, panned to the side that feeds track 1, everything up.
        rig.controls.panel.recordL = .upper
        rig.controls.panel.subGain[0] = 1
        rig.controls.panel.subPan[0] = 0
        rig.controls.panel.remix = true
        rig.controls.panel.master = 1
        rig.controls.panel.eqHighL = 1
        rig.controls.panel.eqLowL = 1
        rig.controls.panel.fader1 = 0.75
        rig.controls.panel.pan1 = 0
        rig.controls.panel.metersShowMixer = true
        rig.controls.panel.monitor = .lineAndSubMix
        rig.controls.panel.monitorLevel = 0.45
        for transport in [TransportRequest(), TransportRequest(motion: .play, recordKey: true), TransportRequest()] {
            rig.controls.transport = transport
            var loudest: Float = 0
            for _ in 0..<15 {
                rig.run(seconds: 0.1, signal: sine(700, amplitude: 0.02))
                // The meter is fed before any limiter, so it shows the loop itself.
                let meter = rig.telemetry.meters[0]
                #expect(meter.isFinite)
                loudest = max(loudest, meter)
            }
            // It howls: far above the -22 dB that was fed in…
            #expect(loudest > 2, "loop only reached \(loudest)")
            // …and stops at the rails: 1.3, doubled at worst by the output
            // coupling, times MASTER flat out, over the 0.25 reference.
            #expect(loudest < 22)
        }
        #expect(rig.telemetry.fuseCount == 0)

        // Break the loop: a reference tone goes through as if nothing had happened.
        rig.controls.panel = Panel()
        rig.controls.panel.fader1 = 0.75
        rig.controls.panel.pan1 = 0
        rig.controls.panel.master = 0.75
        rig.controls.panel.monitor = .lineAndSubMix
        rig.controls.panel.monitorLevel = 0.45
        rig.run(seconds: 1, signal: sine(1000))
        let after = rig.run(seconds: 0.5, signal: sine(1000)).left
        #expect(abs(decibels(component(1000, in: after) / Level.reference)) < 1)
        #expect(rig.telemetry.fuseCount == 0)
    }

    @Test("The reverb survives the sample rate dropping under it")
    func effectSurvivesRateChange() {
        for mode in AuxEffect.Mode.allCases {
            var effect = AuxEffect()
            defer { effect.release() }
            let settings = AuxEffect.Settings(connected: true, mode: mode, size: 1, colour: 0.9)
            effect.prepare(sampleRate: 96_000)
            effect.apply(settings)
            // Run long enough for every cursor to be deep into its buffer.
            for index in 0..<150_000 { _ = effect.process(index % 9000 == 0 ? 0.5 : 0) }
            // Now the device drops to a quarter of the rate: every buffer shrinks.
            effect.prepare(sampleRate: 24_000)
            effect.apply(settings)
            var peak: Float = 0
            for index in 0..<60_000 {
                let wet = effect.process(index == 0 ? 0.5 : 0)
                #expect(wet.left.isFinite && wet.right.isFinite)
                peak = max(peak, abs(wet.left), abs(wet.right))
            }
            #expect(peak > 0.001, "\(mode) is silent after the rate change")
            #expect(peak < 2)
        }
    }

    @Test("Switching the reverb off and on again does not replay an old tail")
    func effectStartsClean() {
        var effect = AuxEffect()
        defer { effect.release() }
        effect.prepare(sampleRate: 48_000)
        var settings = AuxEffect.Settings(connected: true, mode: .reverb, size: 1, colour: 0.5)
        effect.apply(settings)
        for _ in 0..<4800 { _ = effect.process(0.5) }
        settings.connected = false
        effect.apply(settings)
        for _ in 0..<480 { _ = effect.process(0) }
        settings.connected = true
        effect.apply(settings)
        var residue: Float = 0
        for _ in 0..<48_000 { residue = max(residue, abs(effect.process(0).left)) }
        #expect(residue == 0)
    }

    @Test("The core runs comfortably faster than real time")
    func performance() throws {
        let rig = try Rig()
        rig.controls.panel = .readyToPlay
        rig.controls.panel.remix = true
        rig.controls.panel.recordL = .upper
        rig.controls.panel.recordR = .upper
        rig.controls.effect.connected = true
        rig.controls.panel.auxSend = 0.6
        rig.controls.panel.aux = Quad(repeating: 0.8)
        rig.controls.transport = TransportRequest(motion: .play, recordKey: true)
        // Thread CPU time, not wall time: the other tests run alongside this
        // one and would otherwise decide the result.
        func cpuSeconds() -> Double {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
        }
        let seconds = 10.0
        let before = cpuSeconds()
        rig.run(seconds: seconds, signal: sine(440))
        let factor = seconds / (cpuSeconds() - before)
        print("X-2026 core: \(String(format: "%.1f", factor))× real time, worst case, this build configuration")
        // A floor for unoptimised builds; an optimised build manages several times this.
        #expect(factor > 2)
    }
}

// MARK: - Machine

@Suite("Machine")
@MainActor
struct MachineTests {
    @Test("Changing the tape does not disturb the counter, and it counts hub turns from there")
    func counterSurvivesTapeChange() throws {
        let machine = Machine.forPreview(loadTape: false)
        let cassette = try #require(machine.library.cassettes.first)
        try machine.insert(cassette)
        let position = machine.telemetry.position
        #expect(abs(position - cassette.position) < 1)
        #expect(abs(machine.counterValue(at: position)) < 0.001)

        // One more turn of the take-up hub is 0.6 on the counter.
        let geometry = ReelGeometry(stock: cassette.stock)
        let meters = position / CassetteStandard.framesPerMeter
        let oneTurnOn = geometry.wound(turns: geometry.takeUpTurns(at: meters) + 1) * CassetteStandard.framesPerMeter
        #expect(abs(machine.counterValue(at: oneTurnOn) - Machine.counterDigitsPerTurn) < 0.001)

        // Take it out: the counter stays put.
        let removed = try #require(machine.removeCassette())
        #expect(abs(removed.position - cassette.position) < 1)
        #expect(abs(machine.counterValue(at: machine.telemetry.position)) < 0.001)
    }

    @Test("Arming a track into the REMIX loop is explained in words, once")
    func feedbackIsExplained() {
        let machine = Machine.forPreview()
        machine.panel = .readyToPlay
        #expect(machine.notice == nil)
        // Track 1 armed, SUB GAIN 3 toward TRK 1, REMIX: the manual's howl.
        machine.panel.recordL = .upper
        #expect(machine.notice?.contains("SUB GAIN 3") == true)
        machine.notice = nil
        machine.panel.recordL = .off
        machine.panel.recordL = .upper
        #expect(machine.notice == nil)
    }

    @Test("No lecture when there is no loop")
    func noFalseAlarm() {
        let machine = Machine.forPreview()
        var panel = Panel.readyToPlay
        panel.remix = false
        machine.panel = panel
        machine.panel.recordL = .upper
        #expect(machine.notice == nil)
        // REMIX, but that track's SUB GAIN is at twelve o'clock.
        machine.panel.recordL = .off
        machine.panel.subGain[0] = 0.5
        machine.panel.remix = true
        machine.panel.recordL = .upper
        #expect(machine.notice == nil)
        // The other side arms track 2, whose SUB GAIN is up: that is a loop.
        machine.panel.recordR = .upper
        #expect(machine.notice?.contains("Track 2") == true)
    }

    @Test("A panel saved before the machine shipped set up for mixdown is switched to REMIX, once")
    func savedPanelFollowsTheFactory() throws {
        let suite = "x2026.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appending(path: "x2026-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "machine.snapshot.v1"

        // An owner who left it in NORM with MASTER at 4…
        let first = Machine(library: TapeLibrary(root: root), defaults: defaults)
        first.panel.remix = false
        first.panel.master = 0.4
        first.powerOff()
        // …on a build from before saves carried a factory revision.
        let saved = try #require(defaults.data(forKey: key))
        var fields = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        fields.removeValue(forKey: "factoryRevision")
        defaults.set(try JSONSerialization.data(withJSONObject: fields), forKey: key)

        let second = Machine(library: TapeLibrary(root: root), defaults: defaults)
        #expect(second.panel.remix)
        #expect(second.panel.master == 0.4)

        // Having chosen NORM again on this build, it stays chosen.
        second.panel.remix = false
        second.powerOff()
        let third = Machine(library: TapeLibrary(root: root), defaults: defaults)
        #expect(!third.panel.remix)
    }

    @Test("A machine that does not remember neither reads the owner's saved state nor threads their cassette")
    func factoryFreshReadsNothing() throws {
        let suite = "x2026.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appending(path: "x2026-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // An owner with a cassette in the well, a track armed and a microphone plugged in.
        let owner = Machine(library: TapeLibrary(root: root), defaults: defaults)
        let theirs = owner.library.addBlank(stock: .c46, design: .rost, title: "Theirs")
        try owner.insert(theirs)
        owner.panel.recordL = .upper
        owner.audio.patch[0] = .deviceChannel(0)
        owner.powerOff()
        #expect(Machine(library: TapeLibrary(root: root), defaults: defaults).loaded?.id == theirs.id)

        // Even handed the same library and settings, a test machine starts from the factory.
        let visitor = Machine(library: TapeLibrary(root: root), defaults: defaults, remembers: false)
        #expect(visitor.loaded == nil)
        #expect(visitor.panel == .readyToPlay)
        #expect(visitor.audio.patch == JackPatch())
    }

    @Test("A scratch desk is empty, is not the owner's, and can be cleared away")
    func scratchDesk() throws {
        let machine = Machine.onScratchDesk()
        #expect(machine.library.root != TapeLibrary.ownersRoot)
        #expect(!machine.library.root.path(percentEncoded: false).hasPrefix(TapeLibrary.ownersRoot.path(percentEncoded: false)))
        #expect(machine.library.cassettes.isEmpty)
        #expect(machine.loaded == nil)
        try machine.insert(machine.library.addBlank(stock: .c46, design: .pop, title: "Scratch"))
        machine.discardScratchDesk()
        #expect(!FileManager.default.fileExists(atPath: machine.library.root.path(percentEncoded: false)))

        // Handed a library anywhere else, it deletes nothing.
        let elsewhere = FileManager.default.temporaryDirectory.appending(path: "x2026-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let stranger = Machine(library: TapeLibrary(root: elsewhere), remembers: false)
        stranger.library.addBlank(stock: .c46, design: .pop, title: "Keep me")
        stranger.discardScratchDesk()
        #expect(FileManager.default.fileExists(atPath: elsewhere.path(percentEncoded: false)))
        #expect(TapeLibrary(root: elsewhere).cassettes.count == 1)
    }

    @Test("A second cassette does not go in on top of the first: the caller is told")
    func occupiedWell() throws {
        let machine = Machine.onScratchDesk()
        defer { machine.discardScratchDesk() }
        let first = machine.library.addBlank(stock: .c46, design: .pop, title: "First")
        let second = machine.library.addBlank(stock: .c46, design: .pop, title: "Second")
        try machine.insert(first)
        #expect(throws: Machine.WellOccupied.self) { try machine.insert(second) }
        #expect(machine.loaded?.id == first.id)
    }

    @Test("Transport keys interlock like a mechanical latch bar")
    func keyInterlock() {
        let machine = Machine.forPreview()
        machine.press(.play)
        machine.release(.play)
        #expect(machine.keysDown == [.play])
        // RECORD on top of PLAY punches in.
        machine.press(.record)
        machine.release(.record)
        #expect(machine.keysDown == [.record, .play])
        // Any wind key lets the others spring up.
        machine.press(.rewind)
        machine.release(.rewind)
        #expect(machine.keysDown == [.rewind])
        // RECORD alone takes PLAY down with it.
        machine.press(.record)
        machine.release(.record)
        #expect(machine.keysDown == [.record, .play])
        machine.press(.stop)
        #expect(machine.keysDown.isEmpty)
        #expect(machine.keyHeld == .stop)
        machine.release(.stop)
        #expect(machine.keyHeld == nil)
    }
}

// MARK: - Out of the box

@Suite("Factory panel")
struct FactoryPanelTests {
    /// A rig with 500 Hz on track 1 from the head on, playing.
    private func playingRig(_ panel: Panel) throws -> Rig {
        let rig = try Rig()
        let start = rig.oxideFrame
        for offset in 0..<(48_000 * 12) {
            rig.medium.write(track: 0, frame: start + offset, value: Level.reference * Float(sin(2 * Double.pi * 500 * Double(offset) / 48_000)))
        }
        rig.controls.panel = panel
        rig.controls.transport = TransportRequest(motion: .play)
        rig.run(seconds: 0.6)
        return rig
    }

    /// How much of the 500 Hz reaches each ear over the next third of a second.
    private func heard(_ rig: Rig) -> (left: Float, right: Float) {
        rig.run(seconds: 0.2)
        let out = rig.run(seconds: 0.35)
        return (component(500, in: out.left), component(500, in: out.right))
    }

    @Test("Out of the box, PLAY is all it takes, and every mixing control acts on the tape")
    func mixable() throws {
        let rig = try playingRig(.readyToPlay)
        let loud = Level.reference * 0.3
        // Track 1 starts a little left of centre.
        let start = heard(rig)
        #expect(start.left > loud && start.left > start.right)

        // Position: SUB PAN 3.
        rig.controls.panel.subPan[0] = 1
        let right = heard(rig)
        #expect(right.right > loud && right.left < right.right * 0.02)
        rig.controls.panel.subPan[0] = 0
        let left = heard(rig)
        #expect(left.left > loud && left.right < left.left * 0.02)

        // Volume: SUB GAIN 3. Twelve o'clock is off; clockwise is the tape.
        rig.controls.panel.subGain[0] = 0.5
        #expect(heard(rig).left < loud * 0.02)
        rig.controls.panel.subGain[0] = 0.65
        let low = heard(rig).left
        rig.controls.panel.subGain[0] = 1
        let high = heard(rig).left
        #expect(low > loud * 0.05 && high > low * 4)
        // Anticlockwise is the line input, not the tape.
        rig.controls.panel.subGain[0] = 0
        #expect(heard(rig).left < loud * 0.02)
        rig.controls.panel.subGain[0] = 0.82

        // Tone and overall level: EQ and MASTER.
        let flat = heard(rig).left
        rig.controls.panel.eqLowL = 0
        #expect(heard(rig).left < flat * 0.8)
        rig.controls.panel.eqLowL = 0.5
        rig.controls.panel.master = 0
        #expect(heard(rig).left < loud * 0.02)
        rig.controls.panel.master = 0.75

        // The long faders belong to the input jacks and leave the tape alone.
        let before = heard(rig).left
        rig.controls.panel.fader1 = 0
        rig.controls.panel.fader2 = 0
        #expect(abs(heard(rig).left / before - 1) < 0.1)

        // And LINE OUT, where the master recorder listens, carries the mix.
        rig.controls.panel.metersShowMixer = true
        rig.run(seconds: 0.5)
        #expect(rig.telemetry.meters[0] > 0.3)
    }

    @Test("In NORM the tracks still mix in the headphones, past EQ and MASTER")
    func mixableInNorm() throws {
        var panel = Panel.readyToPlay
        panel.remix = false
        let rig = try playingRig(panel)
        let loud = Level.reference * 0.3
        rig.controls.panel.subPan[0] = 1
        let right = heard(rig)
        #expect(right.right > loud && right.left < right.right * 0.02)
        rig.controls.panel.subGain[0] = 0.5
        #expect(heard(rig).right < loud * 0.02)
        rig.controls.panel.subGain[0] = 0.82
        // The sub mix reaches the headphones directly here: MASTER does not touch it…
        rig.controls.panel.master = 0
        #expect(heard(rig).right > loud)
        // …and nothing reaches LINE OUT.
        rig.controls.panel.master = 0.75
        rig.controls.panel.metersShowMixer = true
        rig.run(seconds: 0.5)
        #expect(rig.telemetry.meters[1] < 0.01)
    }
}

// MARK: - Demo tape

@Suite("Demo tape")
struct DemoTapeTests {
    @Test("The demo records four tracks of music at sensible levels, and its count-in is drums alone")
    func demo() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "x2026-demo-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: url) }
        let stock = TapeStock.c46
        let start = try DemoTape.record(to: url, stock: stock)
        let tape = try TapeMedium(url: url, frameCount: stock.frameCount)
        let leader = stock.leaderLength * CassetteStandard.framesPerMeter
        let origin = Int(start - leader)

        // Twenty seconds in, everybody is playing.
        let middle = origin + 48_000 * 21
        for track in 0..<4 {
            let window = (middle..<(middle + 48_000 * 4)).map { tape.read(track: track, frame: $0) }
            let level = decibels(rms(window) / (Level.reference * 0.7071))
            #expect(level > -24 && level < 6, "track \(track + 1) sits at \(level) dB")
        }
        // During the count-in only the rhythm box is on tape.
        let countIn = origin + 48_000 * 2
        let early = (0..<4).map { track in
            rms((countIn..<(countIn + 48_000)).map { tape.read(track: track, frame: $0) })
        }
        #expect(early[0] > 0.01)
        #expect(early[2] < 0.001 && early[3] < 0.001)
        // Nothing past the end of the song.
        let after = origin + 48_000 * 52
        #expect(rms((after..<(after + 48_000)).map { tape.read(track: 0, frame: $0) }) == 0)
    }
}

// MARK: - Mechanical sounds

@Suite("Mechanical sounds")
struct MechanicalSoundTests {
    private func render(seconds: Double, windSpeed: Double = 0, capstan: Double = 0, _ prepare: (inout MechanicalSounds) -> Void) -> (peak: Float, rms: Float) {
        var sounds = MechanicalSounds()
        sounds.prepare(sampleRate: 48_000)
        defer { sounds.release() }
        prepare(&sounds)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        defer {
            left.deallocate()
            right.deallocate()
        }
        var peak: Float = 0
        var energy: Float = 0
        var count = 0
        for _ in 0..<Int(seconds * 100) {
            left.update(repeating: 0, count: 480)
            right.update(repeating: 0, count: 480)
            sounds.render(left: left, right: right, frames: 480, windSpeed: windSpeed, windTop: 8, capstan: capstan, level: 1)
            for frame in 0..<480 {
                peak = max(peak, abs(left[frame]), abs(right[frame]))
                energy += right[frame] * right[frame]
                count += 1
            }
        }
        return (peak, (energy / Float(count)).squareRoot())
    }

    @Test("Every clunk is audible and none of them is a jump scare",
          arguments: [MechanicalSound.keyDown, .keyRelease, .stopKey, .switchLarge, .switchSmall, .counterReset,
                      .lidOpen, .lidClose, .cassetteIn, .cassetteOut, .autoStop, .plug, .footSwitch])
    func impacts(sound: MechanicalSound) {
        let result = render(seconds: 0.5) { $0.trigger(sound) }
        print("mechanical \(sound): peak \(String(format: "%.3f", result.peak))")
        #expect(result.peak > 0.02, "\(sound) is inaudible")
        #expect(result.peak < 0.4, "\(sound) is too loud")
    }

    @Test("The motors murmur rather than roar")
    func motors() {
        let winding = render(seconds: 2, windSpeed: 8) { _ in }
        let playing = render(seconds: 2, capstan: 1) { _ in }
        let idle = render(seconds: 1) { _ in }
        print("mechanical wind rms \(winding.rms) peak \(winding.peak); play rms \(playing.rms); idle \(idle.peak)")
        #expect(winding.rms > 0.003 && winding.peak < 0.25)
        #expect(playing.rms > 0.0003 && playing.rms < winding.rms)
        #expect(idle.peak == 0)
    }
}
