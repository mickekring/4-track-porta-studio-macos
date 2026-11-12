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
        let desk: Desk
        private static var eventNumber = 0

        /// Converts a point in scene millimetres to window coordinates, the
        /// same way the desk view fits whatever is in view to the window.
        func windowPoint(_ scene: CGPoint) -> CGPoint {
            let size = window.contentView?.bounds.size ?? window.frame.size
            let view = desk.view
            let unit = min(size.width / view.width, size.height / view.height)
            let x = size.width / 2 + (scene.x - view.midX) * unit
            let y = size.height / 2 + (scene.y - view.midY) * unit
            return CGPoint(x: x, y: size.height - y)
        }

        private static var clickThrough = Set<ObjectIdentifier>()

        /// Makes the view under the point, and everything above it, accept
        /// "first mouse". A window that is not key spends a mouse-down on
        /// becoming key unless the view under it says it wants the click
        /// anyway; saying so lets the test run in the background instead of
        /// taking the foreground from whoever is using the Mac. Test
        /// processes only: it changes how those view classes behave.
        private func allowClickThrough(at location: CGPoint) {
            guard let content = window.contentView else { return }
            let inParent = content.superview?.convert(location, from: nil) ?? location
            var view: NSView? = content.hitTest(inParent) ?? content
            let selector = #selector(NSView.acceptsFirstMouse(for:))
            while let current = view {
                let kind: AnyClass = type(of: current)
                if Self.clickThrough.insert(ObjectIdentifier(kind)).inserted,
                   let method = class_getInstanceMethod(kind, selector) {
                    let yes: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
                    class_replaceMethod(kind, selector, imp_implementationWithBlock(yes), method_getTypeEncoding(method))
                }
                view = current.superview
            }
        }

        /// A click at a spot in the window itself (x from the left, y from
        /// the top), for things that are not part of the scene.
        func clickWindow(x: CGFloat, fromTop y: CGFloat) async {
            let height = window.contentView?.bounds.height ?? window.frame.height
            let location = CGPoint(x: x, y: height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                Self.eventNumber += 1
                if type == .leftMouseDown { allowClickThrough(at: location) }
                if let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: Self.eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .seconds(0.12))
            }
        }

        private func send(_ type: NSEvent.EventType, at scene: CGPoint, clicks: Int = 1) {
            Self.eventNumber += 1
            let location = windowPoint(scene)
            if type == .leftMouseDown { allowClickThrough(at: location) }
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
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

    /// Works the desk with synthetic mouse events — zooming in and out,
    /// then every kind of control, then mixing the demo tape by hand — and
    /// checks the machine felt each one.
    static func runTouch(machine: Machine, desk: Desk) async {
        await wait(1.5)
        guard let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.contains("desk") == true })
            ?? NSApplication.shared.windows.first(where: { $0.isVisible })
        else { return say("FAIL: no window") }
        say("window key=\(window.isKeyWindow) active=\(NSApplication.shared.isActive) size=\(window.contentView?.bounds.size ?? .zero)")
        machine.mechanicalLevel = 0
        machine.panel = .readyToPlay
        desk.focus = nil
        if machine.loaded != nil {
            desk.eject()
            await idle(desk)
        }
        let finger = GhostFinger(window: window, desk: desk)
        let origin = Desk.machineOrigin
        func onMachine(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x, y: origin.y + y) }
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            if !passed { failures += 1 }
            say("\(passed ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        /// Lets a zoom finish before the next click is aimed.
        func settle() async { await wait(0.75) }

        // --- Zooming ---------------------------------------------------------
        // From the desk, a click on the machine zooms in and works nothing.
        let playKey = onMachine(Layout.keyX[TransportKey.play.rawValue], Layout.keyTop + Layout.keySize.height / 2)
        await finger.click(playKey)
        await settle()
        check("on the desk, a click on the X-2026 zooms in on it", desk.focus == .machine, "\(String(describing: desk.focus))")
        check("…and does not press the key that happened to be under it", machine.keysDown.isEmpty)

        // The bar that appears while zoomed in: across to another box, and back.
        // (Positions measured off a capture of the bar in a 1410-point window.)
        if abs((window.contentView?.bounds.width ?? 0) - 1410) < 1 {
            await finger.clickWindow(x: 684, fromTop: 52)
            await settle()
            check("the bar's TAKT-8 button goes straight across to the rhythm box", desk.focus == .rhythmBox, "\(String(describing: desk.focus))")
            await finger.clickWindow(x: 538, fromTop: 52)
            await settle()
            check("the bar's Desk button goes back to the whole desk", desk.focus == nil, "\(String(describing: desk.focus))")
            await finger.click(playKey)
            await settle()
        }

        // --- Controls, up close ------------------------------------------------
        await finger.click(playKey)
        check("up close, click PLAY latches it", machine.keysDown == [.play], "\(machine.keysDown)")
        await finger.click(onMachine(Layout.keyX[TransportKey.stop.rawValue], Layout.keyTop + Layout.keySize.height / 2))
        check("click STOP releases it", machine.keysDown.isEmpty && machine.keyHeld == nil)

        let before = machine.panel.fader1
        let capY = Layout.faderBottom - CGFloat(before) * Layout.faderTravel
        await finger.drag(from: onMachine(Layout.channelX[0], capY), to: onMachine(Layout.channelX[0], capY + 15))
        let down = before - machine.panel.fader1
        check("drag INPUT fader 1 down 15 mm", abs(down - 15 / Double(Layout.faderTravel)) < 0.02, String(format: "moved %.3f of its travel", down))

        let noise = machine.panel.noiseReduction
        await finger.click(onMachine(Layout.switchX, Layout.noiseReductionY + 4))
        check("click the NR switch flips it", machine.panel.noiseReduction != noise)
        await finger.drag(from: onMachine(Layout.switchX, Layout.recordRY - 0), to: onMachine(Layout.switchX, Layout.recordRY + 7))
        check("drag REC TRK R down to 4", machine.panel.recordR == .lower, "\(machine.panel.recordR)")
        // Track 4 is now armed in REMIX with its SUB GAIN up: the loop the
        // manual warns of. The machine should say so; acknowledge it.
        check("arming into the REMIX loop is explained in words", machine.notice?.contains("SUB GAIN 6") == true)
        machine.notice = nil
        await wait(0.8)
        await finger.drag(from: onMachine(Layout.switchX, Layout.recordRY + 4), to: onMachine(Layout.switchX, Layout.recordRY - 0.5))
        check("…and back to off", machine.panel.recordR == .off, "\(machine.panel.recordR)")
        let mixer = machine.panel.metersShowMixer
        await finger.click(onMachine(Layout.meterSwitch.x, Layout.meterSwitch.y))
        check("click TAPE/MIXER flips it", machine.panel.metersShowMixer != mixer)
        await finger.click(onMachine(Layout.counterReset.x, Layout.counterReset.y))
        check("click counter reset", abs(machine.counterValue(at: machine.telemetry.position)) < 0.01)

        let lid = onMachine(Layout.lid.midX, Layout.lid.midY)
        await finger.click(lid)
        await idle(desk)
        check("click the lid opens it", machine.lidOpen)
        await finger.click(onMachine(Layout.lid.midX, Layout.lid.minY + 5))
        await idle(desk)
        check("click the raised lid closes it", !machine.lidOpen)

        // --- Out to the desk and across to the other boxes -----------------------
        // A click on bare desk, in the strip behind the machine, sits back.
        await finger.click(CGPoint(x: origin.x + 30, y: Desk.machineFrame.minY - 3))
        await settle()
        check("a click on the bare desk zooms back out", desk.focus == nil, "\(String(describing: desk.focus))")

        for device in [Desk.Focus.rhythmBox, .effectUnit, .masterRecorder] {
            await finger.click(CGPoint(x: device.frame.midX, y: device.frame.midY))
            await settle()
            check("on the desk, a click on the \(device.name) zooms in on it", desk.focus == device, "\(String(describing: desk.focus))")
            if device == .rhythmBox {
                check("…without starting it", !machine.rhythm.running)
                let start = CGPoint(x: Accessories.rhythmBox.x + 48, y: Accessories.rhythmBox.y + 110)
                await finger.click(start)
                check("up close, click START on the rhythm box", machine.rhythm.running)
                await finger.click(start)
                check("click it again to stop", !machine.rhythm.running)
            }
            if device == .effectUnit {
                let power = machine.effect.connected
                await finger.click(CGPoint(x: Accessories.effectUnit.x + 12, y: Accessories.effectUnit.y + 28))
                check("up close, click the reverb's POWER switch", machine.effect.connected != power)
                let size = machine.effect.size
                let knob = CGPoint(x: Accessories.effectUnit.x + 86, y: Accessories.effectUnit.y + 26)
                await finger.drag(from: knob, to: CGPoint(x: knob.x, y: knob.y - 8))
                check("drag DECAY upwards", machine.effect.size > size + 0.05, String(format: "%.2f → %.2f", size, machine.effect.size))
                machine.effect.connected = false
            }
            desk.focus = nil
            await settle()
        }

        // --- A cassette, from the desk ---------------------------------------------
        guard let demo = machine.library.cassettes.first(where: { $0.title == DemoTape.title }) else {
            say("SKIPPED: no demo cassette on the desk, so nothing to mix")
            return say(failures == 0 ? "PASS: every gesture reached the machine" : "\(failures) gesture check(s) failed")
        }
        // Wherever the owner left the tape, start a few seconds into the song
        // so there is music under the head; it is put back afterwards.
        let leftAt = demo.position
        var cued = demo
        cued.position = demo.stock.leaderLength * CassetteStandard.framesPerMeter + 6 * CassetteStandard.sampleRate
        machine.library.update(cued)
        let place = desk.spot(for: demo)
        await finger.click(CGPoint(x: place.origin.x + 62, y: place.origin.y + 52))
        await wait(0.6)
        await idle(desk)
        check("click the DEMO cassette on the desk loads it", machine.loaded?.id == demo.id, machine.loaded?.title ?? "nothing loaded")

        // --- Mixing it, by hand ------------------------------------------------------
        desk.focus = .machine
        await settle()
        // Track 1 (the rhythm box) alone: the other three at twelve o'clock.
        var panel = Panel.readyToPlay
        panel.subGain = Quad(0.82, 0.5, 0.5, 0.5)
        panel.monitorLevel = 0
        machine.panel = panel
        let recorder = machine.audio.context.masterRecorder
        await finger.click(playKey)
        await wait(1.8)
        /// Loudest LINE OUT left and right over the next beat or two.
        func lineOut() async -> (left: Float, right: Float) {
            var left: Float = 0
            var right: Float = 0
            for _ in 0..<16 {
                await wait(0.06)
                let levels = recorder.levels
                left = max(left, levels.left)
                right = max(right, levels.right)
            }
            return (left, right)
        }
        let centre = await lineOut()
        check("the demo plays out of LINE OUT", centre.left > 0.2, String(format: "L %.2f R %.2f of the 0 mark", centre.left, centre.right))

        let pan = onMachine(Layout.channelX[2], Layout.panY)
        await finger.drag(from: pan, to: CGPoint(x: pan.x, y: pan.y + 62))
        let hardLeft = await lineOut()
        check("drag SUB PAN 3 down: track 1 goes hard left", machine.panel.subPan[0] < 0.02 && hardLeft.left > hardLeft.right * 8,
              String(format: "pan %.2f, L %.2f R %.2f", machine.panel.subPan[0], hardLeft.left, hardLeft.right))
        await finger.drag(from: pan, to: CGPoint(x: pan.x, y: pan.y - 110))
        let hardRight = await lineOut()
        check("drag it up: hard right", machine.panel.subPan[0] > 0.98 && hardRight.right > hardRight.left * 8,
              String(format: "pan %.2f, L %.2f R %.2f", machine.panel.subPan[0], hardRight.left, hardRight.right))

        let gain = onMachine(Layout.channelX[2], Layout.gainY)
        await finger.drag(from: gain, to: CGPoint(x: gain.x, y: gain.y + 17.2))
        await wait(0.5)
        let quiet = await lineOut()
        check("turn SUB GAIN 3 down to twelve o'clock: track 1 is gone", abs(machine.panel.subGain[0] - 0.5) < 0.001 && quiet.right < hardRight.right * 0.05,
              String(format: "gain %.2f, R %.3f", machine.panel.subGain[0], quiet.right))
        await finger.drag(from: gain, to: CGPoint(x: gain.x, y: gain.y - 17))
        let back = await lineOut()
        check("turn it back up toward TRK: it returns", back.right > hardRight.right * 0.5, String(format: "gain %.2f, R %.2f", machine.panel.subGain[0], back.right))

        let masterCap = onMachine(Layout.masterX, Layout.faderBottom - CGFloat(machine.panel.master) * Layout.faderTravel)
        await finger.drag(from: masterCap, to: CGPoint(x: masterCap.x, y: masterCap.y + 40))
        await wait(0.5)
        let faded = await lineOut()
        check("pull MASTER down: the mix fades out", machine.panel.master < 0.01 && faded.right < 0.01, String(format: "master %.2f, R %.3f", machine.panel.master, faded.right))

        await finger.click(onMachine(Layout.keyX[TransportKey.stop.rawValue], Layout.keyTop + Layout.keySize.height / 2))

        // Take the tape out again, from up close, and leave it as it was found.
        await finger.click(lid)
        await idle(desk)
        await finger.click(onMachine(Layout.cassette.x + 50, Layout.cassette.y + 30))
        await idle(desk)
        check("click the cassette in the open well takes it out", machine.loaded == nil)
        await finger.click(onMachine(Layout.lid.midX, Layout.lid.minY + 5))
        await idle(desk)
        if var restored = machine.library.cassette(withID: demo.id) {
            restored.position = leftAt
            machine.library.update(restored)
        }

        say(failures == 0 ? "PASS: every gesture reached the machine" : "\(failures) gesture check(s) failed")
    }

    // MARK: - Mixdown

    static var isMixdownRequested: Bool { CommandLine.arguments.contains("--mixdown-test") }

    /// Plays the demo cassette into the master recorder for a quarter of a
    /// minute and reports on the file that comes out.
    static func runMixdown(machine: Machine, desk: Desk) async {
        await wait(1.0)
        guard let demo = machine.library.cassettes.first(where: { $0.title == DemoTape.title }) else {
            return say("SKIPPED: no demo cassette on the desk yet")
        }
        machine.mechanicalLevel = 0
        if machine.loaded != nil {
            desk.eject()
            await idle(desk)
        }
        let leftAt = demo.position
        desk.insert(demo)
        await idle(desk)
        guard machine.loaded?.id == demo.id else { return say("FAIL: demo cassette did not load") }

        var panel = Panel.readyToPlay
        panel.remix = true
        panel.monitorLevel = 0
        machine.panel = panel
        let folder = URL.documentsDirectory.appending(path: "Mixdowns", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "self-test mix.wav")
        try? FileManager.default.removeItem(at: url)
        let recorder = machine.audio.context.masterRecorder
        do { try recorder.begin(url: url) } catch { return say("FAIL: master recorder would not start: \(error)") }
        await tap(.play, on: machine)
        var loudest: Float = 0
        for _ in 0..<150 {
            await wait(0.1)
            let levels = recorder.levels
            loudest = max(loudest, levels.left, levels.right)
        }
        await tap(.stop, on: machine)
        let finished = recorder.end()
        say(String(format: "mixed 15 s; loudest LINE OUT %.1f dB; file %@", Level.decibels(loudest), finished?.path(percentEncoded: false) ?? "none"))

        // Put the demo back the way it was found.
        desk.eject()
        await idle(desk)
        if var back = machine.library.cassette(withID: demo.id) {
            back.position = leftAt
            machine.library.update(back)
        }
        say("done")
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

        say("round trip now \(machine.audio.roundTripLatency) frames; \(machine.audio.latencyReport)")

        // Compare the two tracks over two seconds in the middle.
        let origin = Int(start - leader) + 48_000
        let count = 96_000
        let reach = 4000
        let original = machine.debugReadTape(track: 0, from: origin, count: count)
        let overdub = machine.debugReadTape(track: 1, from: origin - reach, count: count + 2 * reach)
        guard original.count == count, overdub.count == count + 2 * reach else { return say("FAIL: could not read the tape") }
        func energy(_ samples: [Float]) -> Float { samples.reduce(0) { $0 + $1 * $1 } }
        say(String(format: "track 1 rms %.4f, track 2 rms %.4f", (energy(original) / Float(count)).squareRoot(), (energy(overdub) / Float(overdub.count)).squareRoot()))
        // Drums repeat, so the correlation has several near-equal peaks one
        // tone-period apart. The round trip is known to within a buffer or
        // two, so look for the alignment only within ±5 ms.
        let window = 240
        var scores: [(lag: Int, score: Float)] = []
        for lag in stride(from: -reach, through: reach, by: 1) {
            var sum: Float = 0
            var index = 0
            while index < count {
                sum += original[index] * overdub[index + reach + lag]
                index += 3
            }
            scores.append((lag, sum))
        }
        let best = scores.filter { abs($0.lag) <= window }.max { $0.score < $1.score } ?? (0, 0)
        let overall = scores.max { $0.score < $1.score } ?? (0, 0)
        if overall.lag != best.lag {
            say(String(format: "(a repeat of the pattern also matches at %+d frames, %.2f× as well)", overall.lag, overall.score / max(best.score, 1e-9)))
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
