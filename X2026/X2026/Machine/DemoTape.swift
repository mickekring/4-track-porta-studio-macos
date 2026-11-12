import Foundation
import OSLog

/// The demo cassette that comes in the box.
///
/// Nothing on it is pre-rendered. The first time the app runs, a little
/// four-piece band (all of them oscillators) plays into a second X-2026
/// behind the scenes: drums and bass to tracks 1 and 2, then electric piano
/// and a lead to tracks 3 and 4 on a second pass — two tracks at a time,
/// through the same heads, hiss and noise reduction as anything you record.
nonisolated enum DemoTape {
    static let title = "DEMO — play me"
    static let trackNotes = ["Rhythm box", "Bass", "Electric piano", "Lead, with echo"]

    private static let sampleRate = 48_000.0
    private static let tempo = 104.0
    private static let beat = 60 / tempo
    private static let bar = beat * 4
    private static let bars = 19
    /// Seconds of tape before the count-in, after the leader.
    private static let leadIn = 1.5

    // Am – F – C – G, voiced close together in the middle of the keyboard.
    private static let chords: [[Double]] = [[57, 60, 64], [57, 60, 65], [55, 60, 64], [55, 59, 62]]
    private static let roots: [Double] = [33, 29, 36, 31]

    private struct Note {
        var bar: Int
        var beat: Double
        var length: Double
        var pitch: Double
    }

    private static let phrase: [Note] = [
        Note(bar: 0, beat: 0, length: 1.5, pitch: 76), Note(bar: 0, beat: 1.5, length: 0.5, pitch: 74),
        Note(bar: 0, beat: 2, length: 1, pitch: 72), Note(bar: 0, beat: 3, length: 1, pitch: 69),
        Note(bar: 1, beat: 0, length: 2, pitch: 72), Note(bar: 1, beat: 2, length: 1, pitch: 69),
        Note(bar: 1, beat: 3, length: 1, pitch: 72),
        Note(bar: 2, beat: 0, length: 1, pitch: 76), Note(bar: 2, beat: 1, length: 1.5, pitch: 79),
        Note(bar: 2, beat: 2.5, length: 0.5, pitch: 76), Note(bar: 2, beat: 3, length: 1, pitch: 74),
        Note(bar: 3, beat: 0, length: 3, pitch: 74),
        Note(bar: 4, beat: 0, length: 1, pitch: 81), Note(bar: 4, beat: 1, length: 0.5, pitch: 79),
        Note(bar: 4, beat: 1.5, length: 1.5, pitch: 76), Note(bar: 4, beat: 3, length: 1, pitch: 74),
        Note(bar: 5, beat: 0, length: 1.5, pitch: 72), Note(bar: 5, beat: 1.5, length: 0.5, pitch: 74),
        Note(bar: 5, beat: 2, length: 1, pitch: 72), Note(bar: 5, beat: 3, length: 1, pitch: 69),
        Note(bar: 6, beat: 0, length: 1, pitch: 67), Note(bar: 6, beat: 1, length: 1, pitch: 72),
        Note(bar: 6, beat: 2, length: 2, pitch: 76),
        Note(bar: 7, beat: 0, length: 2, pitch: 74), Note(bar: 7, beat: 2, length: 2, pitch: 71),
    ]

    private static func frequency(_ midi: Double) -> Double {
        440 * pow(2, (midi - 69) / 12)
    }

    /// The chord (0…3) sounding in `bar`, or nil during the two-bar count-in.
    private static func chord(in bar: Int) -> Int? {
        guard bar >= 2 else { return nil }
        return bar >= bars - 1 ? 0 : (bar - 2) % 4
    }

    // MARK: - The band

    private struct Bass {
        var phase = 0.0
        var filter = 0.0

        mutating func sample(at time: Double) -> Float {
            let eighth = beat / 2
            let index = Int(time / eighth)
            let bar = index / 8
            guard let chord = DemoTape.chord(in: bar), bar < bars else { return 0 }
            let step = index % 8
            if bar == bars - 1 {
                // One long note to finish.
                let since = time - Double(bar) * DemoTape.bar
                return voice(root: roots[chord], since: since, decay: 1.6)
            }
            let octave: Double = step == 3 || step == 7 ? 12 : 0
            return voice(root: roots[chord] + octave, since: time - Double(index) * eighth, decay: 0.22)
        }

        private mutating func voice(root: Double, since: Double, decay: Double) -> Float {
            phase += frequency(root) / sampleRate
            if phase > 1 { phase -= 1 }
            let saw = 2 * phase - 1
            // The filter closes as the note dies away, like a plucked string.
            let cutoff = 180 + 900 * exp(-since / 0.09)
            filter += (1 - exp(-2 * Double.pi * cutoff / sampleRate)) * (saw - filter)
            let envelope = min(1, since / 0.004) * exp(-since / decay)
            return Float(filter * envelope * 0.5)
        }
    }

    private struct Piano {
        func sample(at time: Double) -> Float {
            let bar = Int(time / DemoTape.bar)
            guard let chord = DemoTape.chord(in: bar), bar < bars else { return 0 }
            let inBar = time - Double(bar) * DemoTape.bar
            // Struck on one and three; the last chord is left to ring.
            let half = beat * 2
            let since = bar == bars - 1 ? inBar : inBar.truncatingRemainder(dividingBy: half)
            let envelope = min(1, since / 0.003) * exp(-since / 1.0)
            let tremolo = 1 + 0.18 * sin(2 * .pi * 5.2 * time)
            var sum = 0.0
            for pitch in chords[chord] {
                let f = frequency(pitch)
                let tine = sin(2 * .pi * 2 * f * since) * 0.35 * exp(-since / 0.25)
                sum += sin(2 * .pi * f * since + tine)
            }
            return Float(sum * envelope * tremolo * 0.085)
        }
    }

    private struct Lead {
        var phase = 0.0
        var pitch = 0.0
        var echo = [Float](repeating: 0, count: Int(sampleRate * beat * 0.75))
        var cursor = 0

        mutating func sample(at time: Double) -> Float {
            let bar = Int(time / DemoTape.bar)
            // In from bar 7, the phrase twice through (the second time only its first half).
            var dry: Float = 0
            let local = bar - 6
            if local >= 0, local < 12 {
                let phraseBar = local % 8
                let beatInBar = (time - Double(bar) * DemoTape.bar) / beat
                if let note = phrase.first(where: { $0.bar == phraseBar && beatInBar >= $0.beat && beatInBar < $0.beat + $0.length }) {
                    let since = (beatInBar - note.beat) * beat
                    let left = (note.beat + note.length - beatInBar) * beat
                    // Glide into each note and add vibrato once it has settled.
                    pitch += (note.pitch - pitch) * (pitch == 0 ? 1 : 0.0022)
                    let vibrato = 0.006 * sin(2 * .pi * 5.6 * since) * min(1, since / 0.3)
                    phase += frequency(pitch) * (1 + vibrato) / sampleRate
                    if phase > 1 { phase -= 1 }
                    let angle = 2 * Double.pi * phase
                    let tone = sin(angle) + 0.33 * sin(3 * angle) + 0.12 * sin(5 * angle)
                    let envelope = min(1, since / 0.012) * min(1, left / 0.05)
                    dry = Float(tone * envelope * 0.19)
                }
            }
            let repeatSignal = echo[cursor]
            echo[cursor] = dry + repeatSignal * 0.36
            cursor = (cursor + 1) % echo.count
            return dry + repeatSignal * 0.42
        }
    }

    // MARK: - Recording session

    /// Records the demo onto the oxide file at `url` and returns the tape
    /// position (in frames) to leave the cassette at. Takes a few seconds.
    static func record(to url: URL, stock: TapeStock) throws -> Double {
        let core = MachineCore()
        core.prepare(sampleRate: sampleRate)
        let medium = try TapeMedium(url: url, frameCount: stock.frameCount)
        let leader = stock.leaderLength * CassetteStandard.framesPerMeter
        let start = leader + 0.5 * CassetteStandard.sampleRate

        let drums = RhythmBox()
        drums.prepare(sampleRate: sampleRate)
        var bass = Bass()
        let piano = Piano()
        var lead = Lead()

        // Blocks of 10 ms, so the count-in starts exactly on a block boundary
        // and the rhythm box comes in dead on the beat.
        let block = 480
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer {
            left.deallocate()
            right.deallocate()
        }
        let songLength = Double(bars) * bar + 3
        let quiet = leadIn - 0.5

        for pass in 0..<2 {
            core.insert(medium: medium, stock: stock, position: start, recordProtected: false)

            var controls = ControlFrame()
            controls.mechanicalLevel = 0
            controls.panel = Panel()
            controls.panel.fader1 = 0.75
            controls.panel.fader2 = 0.75
            controls.panel.pan1 = 0
            controls.panel.pan2 = 1
            controls.panel.master = 0.75
            controls.panel.recordL = pass == 0 ? .upper : .lower
            controls.panel.recordR = pass == 0 ? .upper : .lower
            controls.transport = TransportRequest(motion: .play, recordKey: true)
            core.controls.post(controls)

            var frame = 0
            let total = Int((quiet + songLength) * sampleRate)
            var drumsRunning = false
            while frame < total {
                let frames = min(block, total - frame)
                let time = Double(frame) / sampleRate - quiet
                // The rhythm box is started by hand on the downbeat and stopped at the end.
                let shouldRun = time >= 0 && time < Double(bars - 1) * bar
                if shouldRun != drumsRunning {
                    drumsRunning = shouldRun
                    drums.settings.post(RhythmBox.Settings(running: shouldRun, tempo: tempo, pattern: 0, volume: 0.82))
                } else if drumsRunning && time >= 10 * bar && time < 10 * bar + 0.02 {
                    drums.settings.post(RhythmBox.Settings(running: true, tempo: tempo, pattern: 1, volume: 0.82))
                }

                let first = core.jacks
                let second = core.jacks + MachineCore.maximumFrames
                for jack in 2..<MachineDSP.jackCount {
                    (core.jacks + jack * MachineCore.maximumFrames).update(repeating: 0, count: frames)
                }
                if pass == 0 {
                    drums.render(into: first, frames: frames)
                    for index in 0..<frames {
                        let now = Double(frame + index) / sampleRate - quiet
                        second[index] = now >= 0 ? bass.sample(at: now) : 0
                    }
                } else {
                    for index in 0..<frames {
                        let now = Double(frame + index) / sampleRate - quiet
                        first[index] = now >= 0 ? piano.sample(at: now) : 0
                        second[index] = now >= 0 ? lead.sample(at: now) : 0
                    }
                }
                core.render(frames: frames, left: left, right: right)
                frame += frames
            }

            controls.transport = TransportRequest()
            core.controls.post(controls)
            core.render(frames: block, left: left, right: right)
            core.eject()
        }
        medium.flush(wait: true)
        return start
    }

    // MARK: - First run

    /// Makes the demo cassette in the background the first time the app runs,
    /// and puts it on the desk when it is done.
    @MainActor
    static func makeIfNeeded(library: TapeLibrary) {
        let key = "demoTape.made.v1"
        guard !UserDefaults.standard.bool(forKey: key), !recording else { return }
        recording = true

        var cassette = Cassette(title: title, stock: .c46, design: .studio)
        cassette.trackNotes = trackNotes
        cassette.recordProtected = true
        let url = library.oxideURL(for: cassette)
        let stock = cassette.stock
        let finished = cassette
        Task.detached(priority: .utility) {
            let log = Logger(subsystem: "se.mickekring.X2026", category: "demo")
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let position = try record(to: url, stock: stock)
                await MainActor.run {
                    var ready = finished
                    ready.position = position
                    library.add(ready)
                    // Only now is it true that the demo has been made.
                    UserDefaults.standard.set(true, forKey: key)
                    recording = false
                }
            } catch {
                log.error("Could not record the demo tape: \(error)")
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                await MainActor.run { recording = false }
            }
        }
    }

    @MainActor private static var recording = false
}
