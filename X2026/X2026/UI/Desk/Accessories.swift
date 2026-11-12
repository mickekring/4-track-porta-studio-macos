import AppKit
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

/// Where the other boxes sit on the desk, in scene millimetres.
enum Accessories {
    static let effectUnit = CGPoint(x: 426, y: 32)
    static let effectUnitSize = CGSize(width: 166, height: 50)
    static let rhythmBox = CGPoint(x: 8, y: 152)
    static let rhythmBoxSize = CGSize(width: 96, height: 150)
    static let masterRecorder = CGPoint(x: 500, y: 150)
    static let masterRecorderSize = CGSize(width: 96, height: 112)
    static let footSwitch = CGPoint(x: 518, y: 286)
    static let footSwitchSize = CGSize(width: 58, height: 42)
}

// MARK: - Small parts

/// A square push button with an optional lamp in it.
private struct PushButton: View {
    var title: String
    var lit: Bool = false
    var lamp: Color = Theme.ledRed
    var cap: Color = Color(white: 0.16)
    var ink: Color = Theme.legend
    var size: CGSize
    var action: () -> Void

    @Environment(\.unit) private var unit
    @State private var pressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: unit * 0.9)
                .fill(LinearGradient(
                    colors: [cap.mix(with: .white, by: pressed ? 0.02 : 0.14), cap.mix(with: .black, by: pressed ? 0.3 : 0.1)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: unit * 0.9).strokeBorder(.black.opacity(0.7), lineWidth: max(0.5, unit * 0.15)))
                .shadow(color: .black.opacity(pressed ? 0.2 : 0.6), radius: unit * 0.5, y: unit * (pressed ? 0.1 : 0.6))
            VStack(spacing: unit * 0.7) {
                Circle()
                    .fill(lit ? lamp : lamp.mix(with: .black, by: 0.8))
                    .frame(width: unit * 2, height: unit * 2)
                    .shadow(color: lit ? lamp.opacity(0.9) : .clear, radius: unit * 1.2)
                Text(title)
                    .font(.custom("HelveticaNeue-Bold", size: unit * 1.9))
                    .foregroundStyle(ink)
            }
        }
        .frame(width: size.width * unit, height: size.height * unit)
        .offset(y: pressed ? unit * 0.3 : 0)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        action()
                    }
                }
                .onEnded { _ in pressed = false }
        )
        .accessibilityElement()
        .accessibilityLabel(title.capitalized)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

private func legend(_ text: String, size: CGFloat, unit: CGFloat, colour: Color = Theme.legend, bold: Bool = false) -> some View {
    Text(text)
        .font(.custom(bold ? "HelveticaNeue-Bold" : "HelveticaNeue-Medium", size: size * unit))
        .foregroundStyle(colour)
        .fixedSize()
}

// MARK: - Effects unit

/// A half-rack digital reverb on the AUX loop, as in the manual's mixdown hook-up.
struct EffectUnitView: View {
    @Bindable var machine: Machine

    @Environment(\.unit) private var unit

    var body: some View {
        let size = Accessories.effectUnitSize
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: unit * 1.6)
                .fill(LinearGradient(
                    colors: [Color(red: 0.13, green: 0.15, blue: 0.19), Color(red: 0.07, green: 0.08, blue: 0.11)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: unit * 1.6).strokeBorder(.white.opacity(0.10), lineWidth: max(0.5, unit * 0.2)))

            // Maker's stripe and name.
            Rectangle()
                .fill(Color(red: 0.25, green: 0.72, blue: 0.78))
                .frame(width: size.width * unit, height: unit * 0.7)
                .offset(y: unit * 9.4)
            legend("KLANG R-88", size: 4.2, unit: unit, bold: true)
                .offset(x: unit * 5, y: unit * 2.6)
            legend("DIGITAL REVERB · ECHO", size: 1.9, unit: unit, colour: Theme.legendDim)
                .offset(x: unit * 36, y: unit * 4.6)

            // Power: with it off, AUX RCV hears nothing.
            Group {
                Circle()
                    .fill(machine.effect.connected ? Theme.ledGreen : Theme.ledGreen.mix(with: .black, by: 0.82))
                    .frame(width: unit * 2.2, height: unit * 2.2)
                    .shadow(color: machine.effect.connected ? Theme.ledGreen : .clear, radius: unit * 1.5)
                    .position(x: unit * 12, y: unit * 17)
                SlideSwitch(
                    position: Binding(
                        get: { machine.effect.connected ? 0 : 1 },
                        set: { machine.effect.connected = $0 == 0 }),
                    positions: 2, style: .small, label: "Reverb power", names: ["On", "Off"])
                    .position(x: unit * 12, y: unit * 28)
                legend("POWER", size: 1.8, unit: unit).position(x: unit * 12, y: unit * 39)
            }

            Group {
                SlideSwitch(
                    position: Binding(
                        get: { machine.effect.mode.rawValue },
                        set: { machine.effect.mode = AuxEffect.Mode(rawValue: $0) ?? .reverb }),
                    positions: 2, style: .small, label: "Effect", names: ["Reverb", "Echo"])
                    .position(x: unit * 38, y: unit * 28)
                legend("REVERB", size: 1.7, unit: unit).position(x: unit * 47, y: unit * 26.2)
                legend("ECHO", size: 1.7, unit: unit).position(x: unit * 46, y: unit * 30)
                legend("PROGRAM", size: 1.8, unit: unit).position(x: unit * 40, y: unit * 39)
            }

            Group {
                Knob(value: $machine.effect.size, cap: Color(white: 0.72), diameter: 10.5, resetValue: 0.55, label: "Decay / echo time")
                    .position(x: unit * 86, y: unit * 26)
                legend("DECAY / TIME", size: 1.8, unit: unit).position(x: unit * 86, y: unit * 39)
                Knob(value: $machine.effect.colour, cap: Color(white: 0.72), diameter: 10.5, resetValue: 0.5, label: "Colour / repeats")
                    .position(x: unit * 126, y: unit * 26)
                legend("COLOUR / REPEAT", size: 1.8, unit: unit).position(x: unit * 126, y: unit * 39)
            }

            legend("16 BIT", size: 1.7, unit: unit, colour: Color(red: 0.25, green: 0.72, blue: 0.78))
                .position(x: unit * 154, y: unit * 26)
        }
        .frame(width: size.width * unit, height: size.height * unit, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 4 * unit, x: 2 * unit, y: 4 * unit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reverb unit")
    }
}

// MARK: - Rhythm box

/// The preset rhythm box. Plug it into an input jack from that jack's menu.
struct RhythmBoxView: View {
    @Bindable var machine: Machine

    @Environment(\.unit) private var unit

    var body: some View {
        let size = Accessories.rhythmBoxSize
        let body = Color(red: 0.80, green: 0.76, blue: 0.66)
        let ink = Color(red: 0.20, green: 0.17, blue: 0.13)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: unit * 2.5)
                .fill(LinearGradient(
                    colors: [body.mix(with: .white, by: 0.12), body, body.mix(with: .black, by: 0.2)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: unit * 2.5).strokeBorder(.black.opacity(0.35), lineWidth: max(0.5, unit * 0.2)))

            legend("TAKT-8", size: 6.4, unit: unit, colour: ink, bold: true)
                .offset(x: unit * 7, y: unit * 5)
            legend("RHYTHM BOX", size: 2.2, unit: unit, colour: ink.opacity(0.7))
                .offset(x: unit * 8, y: unit * 13.4)
            Rectangle().fill(Theme.brandOrange)
                .frame(width: unit * 82, height: unit * 1.1)
                .offset(x: unit * 7, y: unit * 18.4)

            // Step lamp: blinks on the beat.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !machine.rhythm.running)) { _ in
                let step = machine.audio.context.rhythm.step.load(ordering: .relaxed)
                let onBeat = machine.rhythm.running && step % 4 == 0
                Circle()
                    .fill(onBeat ? Theme.ledRed : Theme.ledRed.mix(with: .black, by: 0.8))
                    .frame(width: unit * 3, height: unit * 3)
                    .shadow(color: onBeat ? Theme.ledRed : .clear, radius: unit * 2)
            }
            .position(x: unit * 80, y: unit * 10)

            // Eight presets.
            ForEach(Array(RhythmBox.patterns.enumerated()), id: \.offset) { index, pattern in
                PushButton(
                    title: pattern.name, lit: machine.rhythm.pattern == index,
                    cap: Color(white: 0.20), size: CGSize(width: 19.5, height: 12.5)
                ) {
                    machine.rhythm.pattern = index
                    machine.core.sounds.push(.switchSmall)
                }
                .position(
                    x: unit * (17.5 + CGFloat(index % 4) * 20.5),
                    y: unit * (31.5 + CGFloat(index / 4) * 15))
            }

            Knob(
                value: Binding(
                    get: { (machine.rhythm.tempo - 60) / 140 },
                    set: { machine.rhythm.tempo = (60 + $0 * 140).rounded() }),
                cap: Color(white: 0.16), diameter: 13, resetValue: (112.0 - 60) / 140, label: "Tempo")
                .position(x: unit * 26, y: unit * 76)
            legend("TEMPO", size: 2.1, unit: unit, colour: ink).position(x: unit * 26, y: unit * 89)
            legend("\(Int(machine.rhythm.tempo))", size: 3.2, unit: unit, colour: ink, bold: true)
                .position(x: unit * 26, y: unit * 64.5)

            Knob(value: $machine.rhythm.volume, cap: Color(white: 0.16), diameter: 13, resetValue: 0.7, label: "Rhythm box volume")
                .position(x: unit * 68, y: unit * 76)
            legend("VOLUME", size: 2.1, unit: unit, colour: ink).position(x: unit * 68, y: unit * 89)

            PushButton(
                title: machine.rhythm.running ? "STOP" : "START", lit: machine.rhythm.running, lamp: Theme.ledGreen,
                cap: Theme.brandOrange.mix(with: .black, by: 0.15), ink: .black,
                size: CGSize(width: 80, height: 22)
            ) {
                machine.rhythm.running.toggle()
                machine.core.sounds.push(.switchLarge)
            }
            .position(x: unit * 48, y: unit * 110)

            legend(pluggedInto, size: 1.9, unit: unit, colour: ink.opacity(0.75))
                .position(x: unit * 48, y: unit * 132)
            JackArt(plugged: jack != nil, size: unit * 8)
                .position(x: unit * 48, y: unit * 141)
        }
        .frame(width: size.width * unit, height: size.height * unit, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 4 * unit, x: 2 * unit, y: 4 * unit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rhythm box")
    }

    private var jack: Int? {
        (0..<JackPatch.count).first { machine.audio.patch[$0] == .rhythmBox }
    }

    private var pluggedInto: String {
        jack.map { "OUTPUT → INPUT \($0 + 1)" } ?? "OUTPUT (not plugged in)"
    }
}

// MARK: - Master recorder

/// The two-track you mix down to. It records LINE OUT in real time.
struct MasterRecorderView: View {
    let machine: Machine

    @Environment(\.unit) private var unit
    @State private var recording = false
    @State private var lastMix: URL?
    @State private var problem: String?

    private var recorder: MasterRecorder { machine.audio.context.masterRecorder }

    var body: some View {
        let size = Accessories.masterRecorderSize
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: unit * 2)
                .fill(LinearGradient(
                    colors: [Color(white: 0.62), Color(white: 0.46), Color(white: 0.36)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: unit * 2).strokeBorder(.black.opacity(0.45), lineWidth: max(0.5, unit * 0.2)))

            legend("MASTER-2", size: 5.0, unit: unit, colour: Color(white: 0.08), bold: true)
                .offset(x: unit * 6, y: unit * 4.5)
            legend("2-TRACK MASTER RECORDER", size: 1.9, unit: unit, colour: Color(white: 0.15))
                .offset(x: unit * 6.4, y: unit * 11.4)

            // Display: elapsed time and two level meters.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                let levels = recorder.levels
                let elapsed = recording ? recorder.elapsed : 0
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: unit)
                        .fill(Color(red: 0.03, green: 0.05, blue: 0.04))
                    Text(String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                        .font(.custom("DINAlternate-Bold", size: unit * 9))
                        .foregroundStyle(recording ? Theme.ledRed : Color(red: 0.30, green: 0.85, blue: 0.55))
                        .shadow(color: (recording ? Theme.ledRed : Theme.ledGreen).opacity(0.6), radius: unit * 1.2)
                        .position(x: unit * 26, y: unit * 9.5)
                    ForEach(0..<2, id: \.self) { side in
                        let level = Level.decibels(side == 0 ? levels.left : levels.right)
                        HStack(spacing: unit * 0.55) {
                            ForEach(0..<12, id: \.self) { segment in
                                let threshold = Float(segment) * 3 - 27
                                let colour = threshold >= 3 ? Theme.ledRed : (threshold >= -3 ? Theme.ledAmber : Theme.ledGreen)
                                Rectangle()
                                    .fill(level >= threshold ? colour : colour.mix(with: .black, by: 0.85))
                                    .frame(width: unit * 2.1, height: unit * 2.6)
                            }
                        }
                        .position(x: unit * 62, y: unit * (6.6 + CGFloat(side) * 5.6))
                    }
                }
                .frame(width: unit * 84, height: unit * 19)
            }
            .offset(x: unit * 6, y: unit * 17.5)

            PushButton(
                title: "REC", lit: recording, lamp: Theme.ledRed,
                cap: Color(red: 0.55, green: 0.10, blue: 0.08), size: CGSize(width: 38, height: 24)
            ) { start() }
                .position(x: unit * 27, y: unit * 55)
            PushButton(
                title: "STOP", lit: false, lamp: Color(white: 0.5),
                cap: Color(white: 0.15), size: CGSize(width: 38, height: 24)
            ) { stop() }
                .position(x: unit * 69, y: unit * 55)

            legend("LINE IN ← LINE OUT L / R", size: 1.8, unit: unit, colour: Color(white: 0.12))
                .position(x: unit * 48, y: unit * 74)

            if let lastMix {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([lastMix])
                } label: {
                    Label(lastMix.lastPathComponent, systemImage: "waveform")
                        .font(.system(size: unit * 2.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Color(white: 0.08))
                        .frame(width: unit * 82)
                }
                .buttonStyle(.plain)
                .position(x: unit * 48, y: unit * 86)
                .help("Show the last mix in Finder")
                .draggable(lastMix)
            } else {
                legend("Press REC, then PLAY on the X-2026.", size: 2.0, unit: unit, colour: Color(white: 0.14))
                    .position(x: unit * 48, y: unit * 86)
                legend("Fade out with MASTER. Press STOP.", size: 2.0, unit: unit, colour: Color(white: 0.14))
                    .position(x: unit * 48, y: unit * 91)
            }
            if let problem {
                legend(problem, size: 1.8, unit: unit, colour: Theme.recordRed)
                    .position(x: unit * 48, y: unit * 101)
            }
        }
        .frame(width: size.width * unit, height: size.height * unit, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 4 * unit, x: 2 * unit, y: 4 * unit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Master recorder")
    }

    private static var mixFolder: URL {
        URL.documentsDirectory.appending(path: "Mixdowns", directoryHint: .isDirectory)
    }

    private func start() {
        guard !recording else { return }
        machine.core.sounds.push(.keyDown)
        do {
            try FileManager.default.createDirectory(at: Self.mixFolder, withIntermediateDirectories: true)
            let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " "
                + Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: ":", with: ".")
            let title = machine.loaded?.title.isEmpty == false ? machine.loaded!.title : "Mix"
            let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let url = Self.mixFolder.appending(path: "\(safe) \(stamp).wav")
            try recorder.begin(url: url)
            recording = true
            problem = nil
        } catch {
            problem = "Could not start recording."
        }
    }

    private func stop() {
        machine.core.sounds.push(.stopKey)
        guard recording else { return }
        recording = false
        guard let finished = recorder.end() else { return }
        lastMix = finished

        // Offer to put the master somewhere sensible.
        let panel = NSSavePanel()
        panel.title = "Save Your Mix"
        panel.nameFieldStringValue = finished.lastPathComponent
        panel.allowedContentTypes = [.wav]
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: finished, to: destination)
                Task { @MainActor in lastMix = destination }
            } catch {
                Task { @MainActor in problem = "Could not save there; the mix is still in Mixdowns." }
            }
        }
    }
}

// MARK: - Foot switch

/// The punch-in pedal. Step on it while the tape plays to drop into record,
/// and again to drop out.
struct FootSwitchView: View {
    let machine: Machine

    @Environment(\.unit) private var unit
    @State private var pressed = false

    var body: some View {
        let size = Accessories.footSwitchSize
        ZStack {
            RoundedRectangle(cornerRadius: unit * 3)
                .fill(LinearGradient(
                    colors: [Color(white: 0.17), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: unit * 3).strokeBorder(.white.opacity(0.10), lineWidth: max(0.5, unit * 0.2)))
            // Ribbed rubber tread.
            RoundedRectangle(cornerRadius: unit * 2)
                .fill(Color(white: pressed ? 0.05 : 0.10))
                .overlay(
                    Canvas { context, canvas in
                        var x = unit * 2
                        while x < canvas.width - unit {
                            context.fill(
                                Path(CGRect(x: x, y: unit * 1.5, width: unit * 0.8, height: canvas.height - unit * 3)),
                                with: .color(.white.opacity(0.07)))
                            x += unit * 2.4
                        }
                    }
                )
                .frame(width: unit * 44, height: unit * 20)
                .offset(y: unit * (pressed ? 2.6 : 2))
            legend("\(Brand.maker.uppercased()) 8051", size: 1.9, unit: unit, colour: Theme.legendDim)
                .offset(y: -unit * 15)
            Circle()
                .fill(machine.punchedIn ? Theme.ledRed : Theme.ledRed.mix(with: .black, by: 0.82))
                .frame(width: unit * 2.4, height: unit * 2.4)
                .shadow(color: machine.punchedIn ? Theme.ledRed : .clear, radius: unit * 1.6)
                .offset(x: unit * 22, y: -unit * 15)
        }
        .frame(width: size.width * unit, height: size.height * unit)
        .shadow(color: .black.opacity(0.5), radius: 3 * unit, x: 1.5 * unit, y: 3 * unit)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        machine.stepOnFootSwitch()
                    }
                }
                .onEnded { _ in pressed = false }
        )
        .help("Foot switch: punch in and out while the tape plays (or press P)")
        .accessibilityElement()
        .accessibilityLabel("Foot switch")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { machine.stepOnFootSwitch() }
    }
}

// MARK: - Cables

/// The leads between the boxes. Drawn in two passes: those that disappear
/// behind the machine, and those that hang off its front edge.
struct CableLayer: View {
    let machine: Machine
    var behind: Bool

    @Environment(\.unit) private var unit

    var body: some View {
        let patch = machine.audio.patch
        let footSwitch = machine.footSwitchConnected
        Canvas { context, _ in
            var scaled = context
            scaled.scaleBy(x: unit, y: unit)
            if behind {
                Self.drawRear(scaled)
            } else {
                Self.drawFront(scaled, patch: patch, footSwitch: footSwitch)
            }
        }
        .frame(width: Desk.scene.width * unit, height: Desk.scene.height * unit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func cable(_ context: GraphicsContext, _ path: Path, colour: Color = Color(white: 0.06), width: CGFloat = 1.7) {
        var shadow = context
        shadow.addFilter(.blur(radius: 1.2))
        shadow.stroke(path.offsetBy(dx: 0.8, dy: 1.6), with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round))
        context.stroke(
            path.offsetBy(dx: -0.25, dy: -0.3), with: .color(.white.opacity(0.13)),
            style: StrokeStyle(lineWidth: width * 0.22, lineCap: .round))
    }

    private static func drawRear(_ context: GraphicsContext) {
        let origin = Desk.machineOrigin
        let rear = origin.y + 3

        // AUX SEND → reverb in; reverb out L/R → AUX RCV.
        let unit = Accessories.effectUnit
        for (index, x) in ([Layout.auxSendJackX] + Layout.auxReturnJackX).enumerated() {
            var lead = Path()
            let start = CGPoint(x: origin.x + x, y: rear)
            let end = CGPoint(x: unit.x + 16 + CGFloat(index) * 9, y: unit.y + Accessories.effectUnitSize.height - 3)
            lead.move(to: start)
            lead.addCurve(
                to: end,
                control1: CGPoint(x: start.x + 6, y: start.y - 34 - CGFloat(index) * 5),
                control2: CGPoint(x: end.x - 40, y: end.y + 30 + CGFloat(index) * 4))
            cable(context, lead, colour: index == 0 ? Color(white: 0.07) : Color(red: 0.32, green: 0.06, blue: 0.05), width: 1.4)
        }

        // LINE OUT L/R → master recorder.
        let recorder = Accessories.masterRecorder
        for (index, x) in Layout.lineOutX.enumerated() {
            var lead = Path()
            let start = CGPoint(x: origin.x + x, y: rear)
            let end = CGPoint(x: recorder.x + 40 + CGFloat(index) * 9, y: recorder.y + 4)
            lead.move(to: start)
            lead.addCurve(
                to: CGPoint(x: origin.x + Layout.size.width + 4, y: origin.y - 12 + CGFloat(index) * 3),
                control1: CGPoint(x: start.x + 10, y: start.y - 30),
                control2: CGPoint(x: origin.x + Layout.size.width - 80, y: origin.y - 20 + CGFloat(index) * 3))
            lead.addCurve(
                to: end,
                control1: CGPoint(x: origin.x + Layout.size.width + 50, y: origin.y - 6),
                control2: CGPoint(x: end.x + 2, y: end.y - 26))
            cable(context, lead, colour: index == 0 ? Color(white: 0.75) : Color(red: 0.55, green: 0.08, blue: 0.06), width: 1.3)
        }

        // The wall-wart lead.
        var power = Path()
        power.move(to: CGPoint(x: origin.x + 324, y: rear))
        power.addCurve(
            to: CGPoint(x: origin.x + 300, y: -10),
            control1: CGPoint(x: origin.x + 330, y: rear - 50),
            control2: CGPoint(x: origin.x + 290, y: 40))
        cable(context, power, width: 1.5)
    }

    private static func drawFront(_ context: GraphicsContext, patch: JackPatch, footSwitch: Bool) {
        let origin = Desk.machineOrigin
        let jackY = origin.y + Layout.size.height + 10.2
        let floor = Desk.scene.height + 20

        for jack in 0..<JackPatch.count {
            let start = CGPoint(x: origin.x + Layout.channelX[jack], y: jackY + 3)
            var lead = Path()
            lead.move(to: start)
            switch patch[jack] {
            case .nothing:
                continue
            case .deviceChannel:
                // Off the front of the desk, to wherever your instrument is.
                lead.addCurve(
                    to: CGPoint(x: start.x - 16 + CGFloat(jack) * 5, y: floor),
                    control1: CGPoint(x: start.x + 2, y: start.y + 12),
                    control2: CGPoint(x: start.x - 20 + CGFloat(jack) * 5, y: floor - 12))
                cable(context, lead, width: 1.9)
            case .rhythmBox:
                let box = Accessories.rhythmBox
                let end = CGPoint(x: box.x + 48, y: box.y + Accessories.rhythmBoxSize.height - 5)
                lead.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x - 4, y: start.y + 26),
                    control2: CGPoint(x: end.x + 18, y: end.y + 44))
                cable(context, lead, colour: Color(red: 0.62, green: 0.42, blue: 0.10), width: 1.8)
            }
        }

        // Headphones: a curly lead wandering off towards you.
        var phones = Path()
        let phoneStart = CGPoint(x: origin.x + Layout.phonesX, y: jackY + 3)
        phones.move(to: phoneStart)
        var point = phoneStart
        var swing: CGFloat = 1
        while point.y < floor {
            let next = CGPoint(x: point.x + 1.2, y: point.y + 2.4)
            phones.addQuadCurve(to: next, control: CGPoint(x: point.x + 3.2 * swing + 0.6, y: point.y + 1.2))
            point = next
            swing = -swing
        }
        cable(context, phones, width: 1.1)

        if footSwitch {
            var lead = Path()
            let start = CGPoint(x: origin.x + Layout.punchX, y: jackY + 3)
            let pedal = Accessories.footSwitch
            let end = CGPoint(x: pedal.x + 6, y: pedal.y + 8)
            lead.move(to: start)
            lead.addCurve(
                to: end,
                control1: CGPoint(x: start.x + 6, y: start.y + 26),
                control2: CGPoint(x: end.x - 60, y: end.y + 40))
            cable(context, lead, width: 1.5)
        }
    }
}
