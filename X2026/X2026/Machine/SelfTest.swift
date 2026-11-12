#if DEBUG
import AppKit
import Foundation

/// A debug-only walkthrough that works the real machine the way a person
/// would — hand, keys, tape and all — and prints what it observes.
///
/// Run the built app with `--self-test` to use it. It works on a scratch
/// cassette it creates and throws away, and keeps the monitor turned down.
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--self-test") }

    /// Prints, and also appends to `self-test.log` in the app's temporary
    /// folder for runs started through LaunchServices, which have no stdout.
    private static func say(_ message: String) {
        let line = "[self-test] \(message)"
        print(line)
        fflush(stdout)
        let url = FileManager.default.temporaryDirectory.appending(path: "self-test.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
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

    // MARK: - Ghost finger

    /// Delivers mouse events straight to the app's own window, so the
    /// gestures can be exercised without touching the real pointer.
    @MainActor
    private struct GhostFinger {
        let window: NSWindow
        private static var eventNumber = 0

        /// Converts a point in scene millimetres to window coordinates,
        /// the same way the desk view lays the scene out when sitting back.
        func windowPoint(_ scene: CGPoint) -> CGPoint {
            let size = window.contentView?.bounds.size ?? window.frame.size
            let unit = min(size.width / Desk.scene.width, size.height / Desk.scene.height)
            let x = size.width / 2 + (scene.x - Desk.scene.width / 2) * unit
            let y = size.height / 2 + (scene.y - Desk.scene.height / 2) * unit
            return CGPoint(x: x, y: size.height - y)
        }

        private func send(_ type: NSEvent.EventType, at scene: CGPoint, clicks: Int = 1) {
            Self.eventNumber += 1
            guard let event = NSEvent.mouseEvent(
                with: type, location: windowPoint(scene), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: Self.eventNumber, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
            else { return }
            window.sendEvent(event)
        }

        func click(_ scene: CGPoint, hold: Double = 0.12) async {
            send(.leftMouseDown, at: scene)
            try? await Task.sleep(for: .seconds(hold))
            send(.leftMouseUp, at: scene)
            try? await Task.sleep(for: .seconds(0.15))
        }

        func drag(from start: CGPoint, to end: CGPoint) async {
            send(.leftMouseDown, at: start)
            for step in 1...14 {
                try? await Task.sleep(for: .milliseconds(16))
                send(.leftMouseDragged, at: Ease.mix(start, end, Double(step) / 14))
            }
            try? await Task.sleep(for: .milliseconds(30))
            send(.leftMouseUp, at: end)
            try? await Task.sleep(for: .seconds(0.15))
        }
    }

    static var isTouchRequested: Bool { CommandLine.arguments.contains("--touch-test") }

    /// Works the controls with synthetic mouse events and checks the machine felt it.
    static func runTouch(machine: Machine, desk: Desk) async {
        await wait(1.5)
        guard let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.contains("desk") == true })
            ?? NSApplication.shared.windows.first(where: { $0.isVisible })
        else { return say("FAIL: no window") }
        // Mouse-downs are only delivered to views in the key window of the
        // active app; anything else is taken as the click that activates it.
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        await wait(0.6)
        say("window key=\(window.isKeyWindow) active=\(NSApplication.shared.isActive) size=\(window.contentView?.bounds.size ?? .zero)")
        machine.mechanicalLevel = 0
        machine.panel = .readyToPlay
        if machine.loaded != nil {
            desk.eject()
            await idle(desk)
        }
        let finger = GhostFinger(window: window)
        let origin = Desk.machineOrigin
        func onMachine(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x, y: origin.y + y) }
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            if !passed { failures += 1 }
            say("\(passed ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        // Transport keys.
        let keyY = Layout.keyTop + Layout.keySize.height / 2
        await finger.click(onMachine(Layout.keyX[TransportKey.play.rawValue], keyY))
        check("click PLAY latches it", machine.keysDown == [.play], "\(machine.keysDown)")
        await finger.click(onMachine(Layout.keyX[TransportKey.stop.rawValue], keyY))
        check("click STOP releases it", machine.keysDown.isEmpty && machine.keyHeld == nil)

        // A fader: drag the cap 15 mm down, then 10 mm back up.
        let before = machine.panel.fader1
        let capY = Layout.faderBottom - CGFloat(before) * Layout.faderTravel
        await finger.drag(from: onMachine(Layout.channelX[0], capY), to: onMachine(Layout.channelX[0], capY + 15))
        let down = before - machine.panel.fader1
        check("drag INPUT fader 1 down 15 mm", abs(down - 15 / Double(Layout.faderTravel)) < 0.02, String(format: "moved %.3f of its travel", down))
        await finger.drag(from: onMachine(Layout.channelX[0], capY + 15), to: onMachine(Layout.channelX[0], capY + 5))
        let up = machine.panel.fader1 - (before - down)
        check("drag it 10 mm back up", abs(up - 10 / Double(Layout.faderTravel)) < 0.02, String(format: "moved %.3f of its travel", up))
        // Click in the slot above the cap: the cap comes to the finger.
        await finger.click(onMachine(Layout.masterX, Layout.faderTop + 2))
        check("click the MASTER slot near the top", machine.panel.master > 0.9, String(format: "%.2f", machine.panel.master))

        // A knob: drag upwards to turn clockwise.
        let pan = machine.panel.pan1
        await finger.drag(from: onMachine(Layout.channelX[0], Layout.panY), to: onMachine(Layout.channelX[0], Layout.panY - 20))
        check("drag PAN 1 upwards turns it clockwise", machine.panel.pan1 > pan + 0.05, String(format: "%.2f → %.2f", pan, machine.panel.pan1))

        // A centre-zero knob: drag downwards from centre towards INPUT.
        let gain = machine.panel.subGain[1]
        await finger.drag(from: onMachine(Layout.channelX[3], Layout.gainY), to: onMachine(Layout.channelX[3], Layout.gainY + 24))
        check("drag SUB GAIN 4 downwards turns it anticlockwise", machine.panel.subGain[1] < gain - 0.05, String(format: "%.2f → %.2f", gain, machine.panel.subGain[1]))

        // Slide switches.
        let noise = machine.panel.noiseReduction
        await finger.click(onMachine(Layout.switchX, Layout.noiseReductionY + 4))
        check("click the NR switch flips it", machine.panel.noiseReduction != noise)
        await finger.click(onMachine(Layout.switchX, Layout.recordLY - 7))
        check("click above REC TRK L arms track 1", machine.panel.recordL == .upper, "\(machine.panel.recordL)")
        await finger.drag(from: onMachine(Layout.switchX, Layout.recordLY - 4), to: onMachine(Layout.switchX, Layout.recordLY + 6))
        check("drag REC TRK L down to 3", machine.panel.recordL == .lower, "\(machine.panel.recordL)")
        let mixer = machine.panel.metersShowMixer
        await finger.click(onMachine(Layout.meterSwitch.x, Layout.meterSwitch.y))
        check("click TAPE/MIXER flips it", machine.panel.metersShowMixer != mixer)
        let mic = machine.panel.micGain1
        await finger.click(onMachine(Layout.channelX[0] + 1.6, Layout.gainY))
        check("click MIC/LINE 1 flips it", machine.panel.micGain1 != mic)

        // Counter reset.
        await finger.click(onMachine(Layout.counterReset.x, Layout.counterReset.y))
        check("click counter reset", abs(machine.counterValue(at: machine.telemetry.position)) < 0.01)

        // The lid.
        let lid = onMachine(Layout.lid.midX, Layout.lid.midY)
        await finger.click(lid)
        await idle(desk)
        check("click the lid opens it", machine.lidOpen)
        await finger.click(onMachine(Layout.lid.midX, Layout.lid.minY + 5))
        await idle(desk)
        check("click the raised lid closes it", !machine.lidOpen)

        // A cassette on the desk: one click and the hand puts it in.
        if let cassette = desk.cassettesOnDesk.last {
            let place = desk.spot(for: cassette)
            await finger.click(CGPoint(x: place.origin.x + 62, y: place.origin.y + 52))
            await wait(0.6)
            await idle(desk)
            check("click a cassette on the desk loads it", machine.loaded?.id == cassette.id, machine.loaded?.title ?? "nothing loaded")
            // And out again: open the lid, click the cassette.
            await finger.click(lid)
            await idle(desk)
            await finger.click(onMachine(Layout.cassette.x + 50, Layout.cassette.y + 30))
            await idle(desk)
            check("click the cassette in the open well takes it out", machine.loaded == nil)
            await finger.click(onMachine(Layout.lid.midX, Layout.lid.minY + 5))
            await idle(desk)
        }

        // The foot switch and rhythm box are plain views too.
        await finger.click(CGPoint(x: Accessories.rhythmBox.x + 48, y: Accessories.rhythmBox.y + 110))
        check("click START on the rhythm box", machine.rhythm.running)
        await finger.click(CGPoint(x: Accessories.rhythmBox.x + 48, y: Accessories.rhythmBox.y + 110))
        check("click it again to stop", !machine.rhythm.running)

        say(failures == 0 ? "PASS: every gesture reached the machine" : "\(failures) gesture check(s) failed")
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
