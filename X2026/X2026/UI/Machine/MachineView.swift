import SwiftUI

/// The static artwork, in a view of its own so that turning a knob never
/// makes SwiftUI redraw the whole panel.
private struct FaceplateView: View {
    @Environment(\.unit) private var unit

    var body: some View {
        Canvas { context, _ in
            var scaled = context
            scaled.scaleBy(x: unit, y: unit)
            FaceplateArt.draw(scaled)
        }
        .frame(width: Layout.size.width * unit, height: Layout.size.height * unit)
        .accessibilityHidden(true)
    }
}

/// The X-2026 seen from above, with its front face (the jacks) folded into
/// view below, the way you see it sitting at the desk.
struct MachineView: View {
    @Bindable var machine: Machine
    /// True while the hand has the well's cassette.
    var cassetteInHand = false
    /// 0 = lid shut, 1 = open.
    var lidOpening: Double = 0
    var onLidTap: () -> Void = {}
    var onCassetteTap: () -> Void = {}

    @Environment(\.unit) private var unit

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                FaceplateView()
                MeterLights(machine: machine)
                channelStrips
                masterSection
                switches
                deckControls
                CassetteWell(
                    machine: machine, cassetteInHand: cassetteInHand, lidOpening: lidOpening,
                    onLidTap: onLidTap, onCassetteTap: onCassetteTap)
                TransportKeys(machine: machine)
            }
            .frame(width: Layout.size.width * unit, height: Layout.size.height * unit, alignment: .topLeading)

            FrontPanel(machine: machine)
        }
    }

    // MARK: - Bindings

    private func value(_ keyPath: WritableKeyPath<Panel, Double>) -> Binding<Double> {
        Binding(
            get: { machine.panel[keyPath: keyPath] },
            set: { machine.panel[keyPath: keyPath] = $0 })
    }

    /// A two-way switch whose upper position means `true`.
    private func upperIsOn(_ keyPath: WritableKeyPath<Panel, Bool>) -> Binding<Int> {
        Binding(
            get: { machine.panel[keyPath: keyPath] ? 0 : 1 },
            set: { machine.panel[keyPath: keyPath] = $0 == 0 })
    }

    private func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * unit, y: y * unit)
    }

    // MARK: - Mixer

    @ViewBuilder
    private var channelStrips: some View {
        let faderY = (Layout.faderTop + Layout.faderBottom) / 2

        // Channels 1–2: AUX, PAN, MIC/LINE, fader.
        Knob(value: value(\.aux1), cap: Theme.knobYellow, diameter: 9.4, label: "AUX 1")
            .position(at(Layout.channelX[0], Layout.auxY))
        Knob(value: value(\.aux2), cap: Theme.knobYellow, diameter: 9.4, label: "AUX 2")
            .position(at(Layout.channelX[1], Layout.auxY))
        Knob(value: value(\.pan1), cap: Theme.knobGreen, diameter: 9.4, detent: 0.5, resetValue: 0.5, label: "PAN 1")
            .position(at(Layout.channelX[0], Layout.panY))
        Knob(value: value(\.pan2), cap: Theme.knobGreen, diameter: 9.4, detent: 0.5, resetValue: 0.5, label: "PAN 2")
            .position(at(Layout.channelX[1], Layout.panY))
        SlideSwitch(position: upperIsOn(\.micGain1), positions: 2, style: .small, label: "GAIN 1", names: ["MIC", "LINE"])
            .position(at(Layout.channelX[0] + 1.6, Layout.gainY))
        SlideSwitch(position: upperIsOn(\.micGain2), positions: 2, style: .small, label: "GAIN 2", names: ["MIC", "LINE"])
            .position(at(Layout.channelX[1] + 1.6, Layout.gainY))
        Fader(value: value(\.fader1), cap: .channel, travel: Layout.faderTravel, resetValue: 0.75, label: "INPUT fader 1")
            .position(at(Layout.channelX[0], faderY))
        Fader(value: value(\.fader2), cap: .channel, travel: Layout.faderTravel, resetValue: 0.75, label: "INPUT fader 2")
            .position(at(Layout.channelX[1], faderY))

        // Channels 3–6: AUX and GAIN choose between line input and tape track.
        ForEach(0..<4, id: \.self) { channel in
            let x = Layout.channelX[channel + 2]
            Knob(
                value: value(\.aux[channel]), cap: Theme.knobYellow, diameter: 9.4, detent: 0.5, resetValue: 0.5,
                label: "AUX \(channel + 3): left for INPUT \(channel + 3), right for TRK \(channel + 1)")
                .position(at(x, Layout.auxY))
            Knob(
                value: value(\.subPan[channel]), cap: Theme.knobGreen, diameter: 9.4, detent: 0.5, resetValue: 0.5,
                label: "SUB PAN \(channel + 3)")
                .position(at(x, Layout.panY))
            Knob(
                value: value(\.subGain[channel]), cap: Theme.knobGrey, diameter: 9.4, detent: 0.5, resetValue: 0.5,
                label: "SUB GAIN \(channel + 3): left for INPUT \(channel + 3), right for TRK \(channel + 1)")
                .position(at(x, Layout.gainY))
        }

        // Stereo-buss equaliser.
        let highY = (Layout.eqHighTop + Layout.eqHighBottom) / 2
        let lowY = (Layout.eqLowTop + Layout.eqLowBottom) / 2
        let eqTravel = Layout.eqHighBottom - Layout.eqHighTop
        Fader(value: value(\.eqHighL), cap: .equaliser, travel: eqTravel, detent: 0.5, resetValue: 0.5, label: "EQ HI left, 10 kHz")
            .position(at(Layout.eqLX, highY))
        Fader(value: value(\.eqHighR), cap: .equaliser, travel: eqTravel, detent: 0.5, resetValue: 0.5, label: "EQ HI right, 10 kHz")
            .position(at(Layout.eqRX, highY))
        Fader(value: value(\.eqLowL), cap: .equaliser, travel: eqTravel, detent: 0.5, resetValue: 0.5, label: "EQ LO left, 100 Hz")
            .position(at(Layout.eqLX, lowY))
        Fader(value: value(\.eqLowR), cap: .equaliser, travel: eqTravel, detent: 0.5, resetValue: 0.5, label: "EQ LO right, 100 Hz")
            .position(at(Layout.eqRX, lowY))

        SlideSwitch(
            position: Binding(
                get: { machine.panel.metersShowMixer ? 1 : 0 },
                set: { machine.panel.metersShowMixer = $0 == 1 }),
            positions: 2, axis: .horizontal, style: .small, label: "Meters", names: ["TAPE", "MIXER"])
            .position(at(Layout.meterSwitch.x, Layout.meterSwitch.y))
    }

    @ViewBuilder
    private var masterSection: some View {
        Knob(value: value(\.auxSend), cap: Theme.knobBlack, diameter: 9, label: "AUX SEND")
            .position(at(Layout.masterX, Layout.auxSendY))
        Knob(value: value(\.auxReturnL), cap: Theme.knobBlack, diameter: 9, label: "AUX RCV L")
            .position(at(Layout.masterX, Layout.returnLY))
        Knob(value: value(\.auxReturnR), cap: Theme.knobBlack, diameter: 9, label: "AUX RCV R")
            .position(at(Layout.masterX, Layout.returnRY))
        Fader(value: value(\.master), cap: .master, travel: Layout.faderTravel, resetValue: 0.75, label: "MASTER")
            .position(at(Layout.masterX, (Layout.faderTop + Layout.faderBottom) / 2))
    }

    @ViewBuilder
    private var switches: some View {
        SlideSwitch(
            position: upperIsOn(\.noiseReduction), positions: 2,
            label: "Noise reduction", names: ["ON", "OFF"])
            .position(at(Layout.switchX, Layout.noiseReductionY))
        SlideSwitch(
            position: Binding(
                get: { machine.panel.monitor.rawValue },
                set: { machine.panel.monitor = MonitorSource(rawValue: $0) ?? .lineAndAux }),
            positions: 3, label: "Monitor", names: ["LINE + AUX", "AUX", "LINE + SUB MIX"])
            .position(at(Layout.switchX, Layout.monitorY))
        SlideSwitch(
            position: upperIsOn(\.remix), positions: 2,
            label: "Sub mix to stereo buss", names: ["REMIX", "NORM"])
            .position(at(Layout.switchX, Layout.remixY))
        SlideSwitch(
            position: Binding(
                get: { machine.panel.recordL.rawValue },
                set: { machine.panel.recordL = RecordSelect(rawValue: $0) ?? .off }),
            positions: 3, stripe: Theme.recordRed, label: "REC TRK from left buss", names: ["Track 1", "Off", "Track 3"])
            .position(at(Layout.switchX, Layout.recordLY))
        SlideSwitch(
            position: Binding(
                get: { machine.panel.recordR.rawValue },
                set: { machine.panel.recordR = RecordSelect(rawValue: $0) ?? .off }),
            positions: 3, stripe: Theme.recordRed, label: "REC TRK from right buss", names: ["Track 2", "Off", "Track 4"])
            .position(at(Layout.switchX, Layout.recordRY))
    }

    // MARK: - Deck

    @ViewBuilder
    private var deckControls: some View {
        Knob(value: value(\.monitorLevel), cap: Theme.knobBlack, diameter: 9, resetValue: 0.45, label: "MONITOR level")
            .position(at(Layout.monitorKnob.x, Layout.monitorKnob.y))
        Knob(value: value(\.pitch), cap: Theme.knobBlack, diameter: 9, detent: 0.5, resetValue: 0.5, label: "PITCH, ±10 %")
            .position(at(Layout.pitchKnob.x, Layout.pitchKnob.y))

        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !machine.isMoving)) { _ in
            TapeCounterView(value: machine.counterValue(at: machine.telemetry.position))
        }
        .id(machine.counterRevision)
        .position(at(Layout.counter.x, Layout.counter.y))

        CounterResetButton { machine.resetCounter() }
            .position(at(Layout.counterReset.x, Layout.counterReset.y))
    }
}

/// The front face of the chassis: six input jacks, PHONES, and PUNCH IN/OUT.
struct FrontPanel: View {
    let machine: Machine

    @Environment(\.unit) private var unit

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                var scaled = context
                scaled.scaleBy(x: unit, y: unit)
                Self.draw(scaled)
            }
            .allowsHitTesting(false)

            ForEach(0..<JackPatch.count, id: \.self) { jack in
                inputJack(jack)
                    .position(x: Layout.channelX[jack] * unit, y: 10.2 * unit)
            }

            JackArt(plugged: true, size: 9.2 * unit)
                .position(x: Layout.phonesX * unit, y: 10.2 * unit)
                .help("PHONES: your Mac's sound output")
                .accessibilityLabel("Headphones jack")

            Menu {
                Toggle("Foot switch plugged in", isOn: Binding(
                    get: { machine.footSwitchConnected },
                    set: { machine.setFootSwitch(connected: $0) }))
            } label: {
                JackArt(plugged: machine.footSwitchConnected, size: 9.2 * unit)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .position(x: Layout.punchX * unit, y: 10.2 * unit)
            .help("PUNCH IN/OUT: foot switch")
        }
        .frame(width: Layout.size.width * unit, height: Layout.frontHeight * unit, alignment: .topLeading)
    }

    private func inputJack(_ jack: Int) -> some View {
        let source = machine.audio.patch[jack]
        return Menu {
            Button("Unplug") { plug(.nothing, into: jack) }
                .disabled(source == .nothing)
            Divider()
            Section(machine.audio.inputDeviceName.isEmpty ? "No input device" : machine.audio.inputDeviceName) {
                ForEach(Array(machine.audio.inputChannelNames.enumerated()), id: \.offset) { index, name in
                    Toggle(name, isOn: Binding(
                        get: { source == .deviceChannel(index) },
                        set: { _ in plug(.deviceChannel(index), into: jack) }))
                }
            }
            Section("On the desk") {
                Toggle("Rhythm box", isOn: Binding(
                    get: { source == .rhythmBox },
                    set: { _ in plug(.rhythmBox, into: jack) }))
            }
        } label: {
            JackArt(plugged: source != .nothing, size: 9.2 * unit)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(jack < 2 ? "MIC/LINE INPUT \(jack + 1)" : "LINE INPUT \(jack + 1)")
        .accessibilityLabel("Input jack \(jack + 1)")
    }

    private func plug(_ source: JackSource, into jack: Int) {
        guard machine.audio.patch[jack] != source else { return }
        machine.audio.patch[jack] = source
        machine.patchChanged()
    }

    static func draw(_ context: GraphicsContext) {
        let width = Layout.size.width
        let height = Layout.frontHeight
        // The face leans away from you, so it catches less light.
        let face = Path(roundedRect: CGRect(x: 1.5, y: -3, width: width - 3, height: height + 3), cornerRadius: 3.5)
        context.fill(face, with: .linearGradient(
            Gradient(colors: [Color(white: 0.04), Color(white: 0.075), Color(white: 0.03)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))

        // Ribbed inset the input jacks are mounted in.
        let inset = CGRect(x: 15.5, y: 4.2, width: 146, height: 12)
        context.fill(Path(roundedRect: inset, cornerRadius: 2), with: .color(Color(white: 0.035)))
        var rib = inset.minY + 1.6
        while rib < inset.maxY - 1 {
            context.stroke(
                Path { $0.move(to: CGPoint(x: inset.minX + 1.5, y: rib)); $0.addLine(to: CGPoint(x: inset.maxX - 1.5, y: rib)) },
                with: .color(.white.opacity(0.045)), lineWidth: 0.3)
            rib += 1.5
        }
        for x in [Layout.phonesX, Layout.punchX] {
            let pad = CGRect(x: x - 6.5, y: 4.2, width: 13, height: 12)
            context.fill(Path(roundedRect: pad, cornerRadius: 2), with: .color(Color(white: 0.035)))
        }
        context.draw(
            Text("PUNCH IN/OUT").font(.custom("HelveticaNeue-Medium", size: 1.7)).foregroundStyle(Theme.legendDim),
            at: CGPoint(x: Layout.punchX + 8.2, y: 10.2), anchor: .leading)

        // Rubber feet peeking out underneath.
        for x in [22.0, width - 22] {
            context.fill(
                Path(roundedRect: CGRect(x: x - 7, y: height - 1.6, width: 14, height: 2.6), cornerRadius: 1),
                with: .color(Color(white: 0.02)))
        }
    }
}

/// A quarter-inch jack socket seen head-on, with or without a plug in it.
struct JackArt: View {
    var plugged: Bool
    var size: CGFloat

    var body: some View {
        Canvas { context, canvas in
            let centre = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let radius = min(canvas.width, canvas.height) / 2
            func disc(_ scale: CGFloat) -> Path {
                Path(ellipseIn: CGRect(
                    x: centre.x - radius * scale, y: centre.y - radius * scale,
                    width: radius * 2 * scale, height: radius * 2 * scale))
            }
            // Nut and bushing.
            context.fill(disc(0.92), with: .radialGradient(
                Gradient(colors: [Color(white: 0.78), Color(white: 0.42), Color(white: 0.22)]),
                center: CGPoint(x: centre.x - radius * 0.25, y: centre.y - radius * 0.3),
                startRadius: 0, endRadius: radius * 1.1))
            context.stroke(disc(0.92), with: .color(.black.opacity(0.7)), lineWidth: 0.6)
            context.fill(disc(0.62), with: .color(Color(white: 0.20)))
            if plugged {
                // The plug's moulded body, coming straight at you.
                context.fill(disc(0.80), with: .radialGradient(
                    Gradient(colors: [Color(white: 0.24), Color(white: 0.07)]),
                    center: CGPoint(x: centre.x - radius * 0.2, y: centre.y - radius * 0.25),
                    startRadius: 0, endRadius: radius))
                context.stroke(disc(0.80), with: .color(.black), lineWidth: 0.6)
                context.fill(disc(0.34), with: .color(Color(white: 0.03)))
            } else {
                context.fill(disc(0.44), with: .color(.black))
                context.stroke(disc(0.44), with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}
