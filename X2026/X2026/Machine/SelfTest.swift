#if DEBUG
import Foundation

/// A debug-only walkthrough that works the real machine the way a person
/// would — hand, keys, tape and all — and prints what it observes.
///
/// Run the built app with `--self-test` to use it. It works on a scratch
/// cassette it creates and throws away, and keeps the monitor turned down.
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--self-test") }

    private static func say(_ message: String) {
        print("[self-test] \(message)")
        fflush(stdout)
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func idle(_ desk: Desk) async {
        while desk.busy { await wait(0.05) }
    }

    private static func tap(_ key: TransportKey, on machine: Machine) async {
        machine.press(key)
        await wait(0.1)
        machine.release(key)
    }

    private static func describe(_ machine: Machine) -> String {
        let report = machine.telemetry
        let meters = (0..<4).map { String(format: "%5.1f", Level.decibels(report.meters[$0])) }.joined(separator: " ")
        let lamps = (0..<4).map { ["G", "A", "R"][Int(report.lamps[$0])] }.joined()
        return String(
            format: "motion=%@ counter=%07.2f pos=%.2fs meters[dB]=%@ lamps=%@ rec=%@",
            "\(report.motion)", machine.counterValue(at: report.position),
            (report.position - (machine.loaded?.stock.leaderLength ?? 0) * CassetteStandard.framesPerMeter) / CassetteStandard.sampleRate,
            meters, lamps, report.isRecording ? "yes" : "no")
    }

    // MARK: - Loopback

    static var isLoopbackRequested: Bool { CommandLine.arguments.contains("--loopback-test") }

    /// Call before the machine is powered on: routes its audio out of and
    /// back into a virtual loopback device, if one is installed.
    static func prepareLoopback(machine: Machine) -> Bool {
        guard let device = AudioHardware.device(named: "BlackHole") else {
            say("SKIPPED: no loopback device (BlackHole) found")
            return false
        }
        machine.audio.forcedOutputDevice = device
        machine.audio.forcedInputDevice = device
        return true
    }

    /// Measures how well an overdub lines up with what it was played to.
    ///
    /// Track 1 gets the rhythm box. Then track 1 is played out of the Mac,
    /// looped straight back in, and recorded onto track 2 — exactly what
    /// happens when you overdub, minus the musician. With the round trip
    /// compensated the two tracks should sit on top of each other.
    static func runLoopback(machine: Machine, desk: Desk) async {
        say("loopback: output=\(machine.audio.outputDeviceName)")
        machine.mechanicalLevel = 0
        var scratch = machine.library.addBlank(stock: .c46, design: .pop, title: "Loopback test")
        let leader = scratch.stock.leaderLength * CassetteStandard.framesPerMeter
        let start = leader + 3 * CassetteStandard.sampleRate
        scratch.position = start
        machine.library.update(scratch)
        defer {
            if machine.loaded != nil { machine.removeCassette() }
            if let scratch = machine.library.cassette(withID: scratch.id) { machine.library.discard(scratch) }
        }
        do { try machine.insert(scratch) } catch { return say("FAIL: \(error)") }

        // Pass 1: rhythm box → INPUT 1 → track 1.
        var panel = Panel()
        panel.noiseReduction = false
        panel.fader1 = 0.75
        panel.pan1 = 0
        panel.master = 0.75
        panel.recordL = .upper
        machine.panel = panel
        machine.audio.patch = JackPatch()
        machine.audio.patch[0] = .rhythmBox
        machine.rhythm = RhythmBox.Settings(running: true, tempo: 132, pattern: 7, volume: 0.9)
        await wait(0.4)
        await tap(.record, on: machine)
        await wait(4)
        await tap(.stop, on: machine)
        machine.rhythm.running = false
        await wait(0.3)

        // Ask for the Mac's input (this is where macOS may ask permission).
        machine.audio.patch[0] = .nothing
        machine.audio.patch[1] = .deviceChannel(0)
        var waited = 0.0
        while machine.audio.roundTripLatency == 0 && waited < 25 {
            await wait(0.25)
            waited += 0.25
        }
        guard machine.audio.roundTripLatency > 0 else {
            return say("SKIPPED: audio input is not available (permission not granted?)")
        }
        say("input up after \(waited) s; reported round trip \(machine.audio.roundTripLatency) frames = \(String(format: "%.2f", Double(machine.audio.roundTripLatency) / machine.audio.sampleRate * 1000)) ms")
        await wait(1.0)

        // Pass 2: track 1 → AUX → PHONES → loopback → INPUT 2 → track 2.
        machine.removeCassette()
        scratch = machine.library.cassette(withID: scratch.id) ?? scratch
        scratch.position = start
        machine.library.update(scratch)
        do { try machine.insert(scratch) } catch { return say("FAIL: \(error)") }
        panel = Panel()
        panel.noiseReduction = false
        panel.fader2 = 0.75
        panel.pan2 = 1
        panel.master = 0.75
        panel.recordR = .upper
        panel.aux[0] = 0.8
        panel.auxSend = 0.6
        panel.monitor = .aux
        panel.monitorLevel = 0.45
        machine.panel = panel
        await wait(0.4)
        await tap(.record, on: machine)
        await wait(4)
        await tap(.stop, on: machine)
        await wait(0.3)

        // Compare the two tracks over two seconds in the middle.
        let origin = Int(start - leader) + 48_000
        let count = 96_000
        let reach = 4000
        let original = machine.debugReadTape(track: 0, from: origin, count: count)
        let overdub = machine.debugReadTape(track: 1, from: origin - reach, count: count + 2 * reach)
        guard original.count == count, overdub.count == count + 2 * reach else { return say("FAIL: could not read the tape") }
        func energy(_ samples: [Float]) -> Float { samples.reduce(0) { $0 + $1 * $1 } }
        say(String(format: "track 1 rms %.4f, track 2 rms %.4f", (energy(original) / Float(count)).squareRoot(), (energy(overdub) / Float(overdub.count)).squareRoot()))
        var best = (lag: 0, score: -Float.infinity)
        for lag in stride(from: -reach, through: reach, by: 1) {
            var sum: Float = 0
            var index = 0
            while index < count {
                sum += original[index] * overdub[index + reach + lag]
                index += 3
            }
            if sum > best.score { best = (lag, sum) }
        }
        let milliseconds = Double(best.lag) / CassetteStandard.sampleRate * 1000
        say(String(format: "overdub sits %+d tape frames (%+.2f ms) from the track it was played to", best.lag, milliseconds))
        say(abs(milliseconds) < 1.5 ? "PASS: overdubs line up" : "CHECK: more than 1.5 ms out; Head alignment in Settings can trim this")
    }

    static func run(machine: Machine, desk: Desk) async {
        say("starting; audio running=\(machine.audio.isRunning) rate=\(machine.audio.sampleRate) output=\(machine.audio.outputDeviceName)")
        let savedPanel = machine.panel
        let savedPatch = machine.audio.patch
        let savedLevel = machine.mechanicalLevel
        await wait(1.0)

        // A scratch cassette, a few seconds in so we are past the leader.
        if machine.loaded != nil {
            desk.eject()
            await idle(desk)
        }
        var scratch = machine.library.addBlank(stock: .c46, design: .pop, title: "Self-test")
        scratch.position = (scratch.stock.leaderLength * CassetteStandard.framesPerMeter) + 3 * CassetteStandard.sampleRate
        machine.library.update(scratch)

        say("hand: inserting cassette")
        let started = ContinuousClock.now
        desk.insert(scratch)
        await idle(desk)
        say("inserted in \(ContinuousClock.now - started); loaded=\(machine.loaded?.title ?? "nil") lidOpen=\(machine.lidOpen)")
        guard machine.loaded != nil else {
            say("FAIL: no cassette loaded")
            return
        }

        // First track, by the book: rhythm box into INPUT 1, panned left to
        // track 1, listening on AUX 3. Monitor right down so the Mac stays quiet.
        var panel = Panel()
        panel.fader1 = 0.75
        panel.pan1 = 0
        panel.master = 0.75
        panel.recordL = .upper
        panel.monitor = .aux
        panel.aux[0] = 0.8
        panel.auxSend = 0.5
        panel.monitorLevel = 0
        machine.panel = panel
        machine.mechanicalLevel = 0
        machine.audio.patch[0] = .rhythmBox
        machine.rhythm.volume = 0.8
        machine.rhythm.pattern = 0
        machine.rhythm.running = true
        machine.resetCounter()
        await wait(0.5)
        say("armed: \(describe(machine))")

        await tap(.record, on: machine)
        await wait(4.0)
        say("recording 4 s: \(describe(machine))")
        let afterRecording = machine.telemetry.position
        await tap(.stop, on: machine)
        machine.rhythm.running = false
        await wait(0.4)
        say("stopped: \(describe(machine))")

        // Rewind to where we started. No locator: watch the counter.
        await tap(.rewind, on: machine)
        while machine.counterValue(at: machine.telemetry.position) > 0.6 { await wait(0.01) }
        await tap(.stop, on: machine)
        await wait(0.4)
        say("rewound to zero: \(describe(machine))")

        // Play it back through the sub mix.
        panel = Panel()
        panel.subGain[0] = 0.8
        panel.remix = true
        panel.master = 0.75
        panel.monitor = .lineAndSubMix
        panel.monitorLevel = 0
        machine.panel = panel
        await tap(.play, on: machine)
        var loudest: Float = -120
        for _ in 0..<60 {
            await wait(0.05)
            loudest = max(loudest, Level.decibels(machine.telemetry.meters[0]))
        }
        say("played 3 s: \(describe(machine)); loudest on track 1 = \(String(format: "%.1f", loudest)) dB")
        say(loudest > -12 ? "PASS: the rhythm box came back off the tape" : "FAIL: track 1 is silent on playback")
        await tap(.stop, on: machine)

        // Fast forward to the end of the tape and time it.
        await tap(.fastForward, on: machine)
        let windStart = ContinuousClock.now
        let from = machine.telemetry.position
        while !machine.keysDown.isEmpty { await wait(0.05) }
        let total = (machine.loaded?.totalFrames ?? 0)
        say("fast-forwarded \(String(format: "%.0f", (total - from) / total * 100)) % of a C-46 in \(ContinuousClock.now - windStart); auto-stop released the keys: \(describe(machine))")
        _ = afterRecording

        say("hand: taking the cassette out")
        desk.eject()
        await idle(desk)
        say("ejected; loaded=\(machine.loaded?.title ?? "nil"); tape left at \(String(format: "%.1f", (machine.library.cassette(withID: scratch.id)?.position ?? 0) / CassetteStandard.sampleRate)) s")

        // Put everything back as it was and bin the scratch tape.
        if let scratch = machine.library.cassette(withID: scratch.id) {
            machine.library.discard(scratch)
        }
        machine.panel = savedPanel
        machine.audio.patch = savedPatch
        machine.mechanicalLevel = savedLevel
        say("done")
    }
}
#endif
