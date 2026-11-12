import SwiftUI

/// The whole scene: a wooden desk, the machine in the middle of it, cassettes
/// lying around, and a hand that comes in to change the tape.
struct DeskView: View {
    @Bindable var desk: Desk

    @FocusState private var atTheMachine: Bool

    private var machine: Machine { desk.machine }

    var body: some View {
        GeometryReader { proxy in
            SceneFrame(size: proxy.size, view: desk.view, onDeskTap: { desk.focus = nil }) { unit in
                scene(unit: unit)
            }
            .animation(.smooth(duration: 0.5), value: desk.focus)
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if desk.focus != nil {
                // The overlay starts below the (hidden) title bar, where
                // clicks would move the window instead.
                ZoomBar(desk: desk)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: desk.focus == nil)
        // Pinch out to sit back; pinch in from the desk to lean over the machine.
        .simultaneousGesture(
            MagnifyGesture().onEnded { pinch in
                if pinch.magnification < 0.85 {
                    desk.focus = nil
                } else if pinch.magnification > 1.2, desk.focus == nil {
                    desk.focus = .machine
                }
            }
        )
        // The keyboard works the transport only while the desk itself has
        // focus, so typing on a label never presses RECORD.
        .focusable()
        .focusEffectDisabled()
        .focused($atTheMachine)
        .onAppear { atTheMachine = true }
        .simultaneousGesture(TapGesture().onEnded { atTheMachine = true })
        .onChange(of: desk.editing == nil) { _, closed in
            if closed { atTheMachine = true }
        }
        .onKeyPress(phases: [.down, .up]) { press in
            handle(press) ? .handled : .ignored
        }
        .sheet(item: $desk.editing) { cassette in
            LabelEditor(cassette: cassette) { edited in
                machine.relabel(edited)
            }
        }
        .alert(
            "A word from the machine",
            isPresented: Binding(get: { machine.notice != nil }, set: { if !$0 { machine.notice = nil } })
        ) {
            Button("OK") { machine.notice = nil }
        } message: {
            Text(machine.notice ?? "")
        }
        .confirmationDialog(
            "Throw this cassette away?",
            isPresented: Binding(get: { desk.discarding != nil }, set: { if !$0 { desk.discarding = nil } }),
            presenting: desk.discarding
        ) { cassette in
            Button("Throw Away", role: .destructive) { desk.throwAway(cassette) }
            Button("Keep", role: .cancel) {}
        } message: { cassette in
            Text("Everything recorded on “\(cassette.title.isEmpty ? "the unlabelled tape" : cassette.title)” goes in the bin with it. There is no getting a tape back.")
        }
    }

    /// Keys behave like fingers: the transport key stays down for as long
    /// as the key on the keyboard does.
    private func handle(_ press: KeyPress) -> Bool {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }
        let transport: TransportKey?
        switch press.key {
        case .space: transport = machine.keysDown.isEmpty ? .play : .stop
        case .return: transport = .stop
        case .leftArrow: transport = .rewind
        case .rightArrow: transport = .fastForward
        case "r": transport = .record
        default: transport = nil
        }
        if let transport {
            switch press.phase {
            case .down:
                // Decide once, on the way down, which key the space bar meant.
                if machine.keyHeld == nil { machine.press(transport) }
            case .up:
                if let held = machine.keyHeld { machine.release(held) }
            default:
                break
            }
            return true
        }
        if press.key == .escape {
            // Esc sits back. With nothing to sit back from, leave it alone.
            guard desk.focus != nil else { return false }
            if press.phase == .down { desk.focus = nil }
            return true
        }
        guard press.phase == .down else { return ["p", "0", "z"].contains(press.key) }
        switch press.key {
        case "p":
            machine.stepOnFootSwitch()
        case "0":
            machine.resetCounter()
        case "z":
            desk.focus = desk.focus == nil ? .machine : nil
        default:
            return false
        }
        return true
    }

    private func scene(unit: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Things on the desk around the machine.
            EffectUnitView(machine: machine)
                .offset(x: Accessories.effectUnit.x * unit, y: Accessories.effectUnit.y * unit)
            RhythmBoxView(machine: machine)
                .offset(x: Accessories.rhythmBox.x * unit, y: Accessories.rhythmBox.y * unit)
            MasterRecorderView(machine: machine)
                .offset(x: Accessories.masterRecorder.x * unit, y: Accessories.masterRecorder.y * unit)
            if machine.footSwitchConnected {
                FootSwitchView(machine: machine)
                    .offset(x: Accessories.footSwitch.x * unit, y: Accessories.footSwitch.y * unit)
                    .transition(.opacity)
            }

            BlankTapeBox { stock, design in desk.unwrapBlank(stock: stock, design: design) }
                .rotationEffect(.degrees(-4))
                .offset(x: 10 * unit, y: 26 * unit)

            CableLayer(machine: machine, behind: true)

            ForEach(desk.cassettesOnDesk) { cassette in
                cassetteOnDesk(cassette, unit: unit)
            }

            MachineView(
                machine: machine,
                cassetteInHand: false,
                lidOpening: desk.lidOpening,
                onLidTap: { desk.toggleLid() },
                onCassetteTap: { desk.eject() })
                .shadow(color: .black.opacity(0.55), radius: 9 * unit, x: 3 * unit, y: 8 * unit)
                .offset(x: Desk.machineOrigin.x * unit, y: Desk.machineOrigin.y * unit)
                .contextMenu { machineMenu }

            CableLayer(machine: machine, behind: false)

            // Any box you are not leaning over is a target: one click and it
            // fills the window. Its own controls stay out of reach until then.
            ForEach(Desk.Focus.allCases) { device in
                if desk.focus != device {
                    ZoomTarget(name: device.name) { desk.focus = device }
                        .frame(width: device.frame.width * unit, height: device.frame.height * unit)
                        .offset(x: device.frame.minX * unit, y: device.frame.minY * unit)
                        .contextMenu {
                            if device == .machine { machineMenu }
                        }
                }
            }

            // The hand, in layers, with whatever it is carrying in between.
            if let pose = desk.hand {
                HandLayer(pose: pose, part: .shadow)
                HandLayer(pose: pose, part: .fingers)
            }
            if let carried = desk.carried {
                let anchor = UnitPoint(
                    x: HandArt.cassetteGrip.x / CassetteArt.size.width,
                    y: HandArt.cassetteGrip.y / CassetteArt.size.height)
                CassetteView(cassette: carried.cassette)
                    .rotationEffect(carried.angle, anchor: anchor)
                    .scaleEffect(1 + 0.07 * carried.lift, anchor: anchor)
                    .shadow(
                        color: .black.opacity(0.5 - 0.15 * carried.lift),
                        radius: (1.5 + 7 * carried.lift) * unit,
                        x: 5 * carried.lift * unit, y: (1.5 + 11 * carried.lift) * unit)
                    .offset(
                        x: (carried.grip.x - HandArt.cassetteGrip.x) * unit,
                        y: (carried.grip.y - HandArt.cassetteGrip.y) * unit)
                    .allowsHitTesting(false)
            }
            if let pose = desk.hand {
                HandLayer(pose: pose, part: .back)
            }
        }
    }

    private func cassetteOnDesk(_ cassette: Cassette, unit: CGFloat) -> some View {
        let place = desk.spot(for: cassette)
        let anchor = UnitPoint(
            x: HandArt.cassetteGrip.x / CassetteArt.size.width,
            y: HandArt.cassetteGrip.y / CassetteArt.size.height)
        let lifted = desk.hovered == cassette.id && !desk.busy
        return CassetteView(cassette: cassette)
            .rotationEffect(place.angle, anchor: anchor)
            .scaleEffect(lifted ? 1.035 : 1, anchor: anchor)
            .shadow(
                color: .black.opacity(lifted ? 0.4 : 0.5),
                radius: (lifted ? 4.5 : 1.6) * unit, x: (lifted ? 2 : 0.6) * unit, y: (lifted ? 5 : 1.4) * unit)
            .offset(x: place.origin.x * unit, y: place.origin.y * unit)
            .zIndex(lifted ? 1 : 0)
            .animation(.snappy(duration: 0.16), value: lifted)
            .onHover { inside in
                if inside {
                    desk.hovered = cassette.id
                } else if desk.hovered == cassette.id {
                    desk.hovered = nil
                }
            }
            .onTapGesture(count: 2) { desk.editing = cassette }
            .onTapGesture { desk.insert(cassette) }
            .contextMenu {
                Button("Put in the Machine") { desk.insert(cassette) }
                Button("Write on the Label…") { desk.editing = cassette }
                Button("Turn Over to Side \(cassette.flipped ? "A" : "B")") { desk.turnOver(cassette) }
                Divider()
                if cassette.recordProtected {
                    Button("Tape Over the Record-Protect Holes") { desk.setRecordProtect(false, on: cassette) }
                } else {
                    Button("Snap Off the Record-Protect Tabs") { desk.setRecordProtect(true, on: cassette) }
                }
                Divider()
                Button("Throw Away…", role: .destructive) { desk.discarding = cassette }
            }
            .help(cassette.title.isEmpty ? "Unlabelled \(cassette.stock.name), side \(cassette.sideLetter)" : "\(cassette.title) — side \(cassette.sideLetter)")
            .accessibilityElement()
            .accessibilityLabel("Cassette: \(cassette.title.isEmpty ? "unlabelled" : cassette.title), \(cassette.stock.name), side \(cassette.sideLetter)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { desk.insert(cassette) }
    }

    @ViewBuilder
    private var machineMenu: some View {
        if let cassette = machine.loaded {
            Button("Take the Cassette Out") { desk.eject() }
            Button("Turn the Cassette Over to Side \(cassette.flipped ? "A" : "B")") { desk.turnOverLoaded() }
            Button("Write on the Label…") { desk.editing = cassette }
            Divider()
        }
        Button(desk.lidOpening > 0.5 ? "Close the Lid" : "Open the Lid") { desk.toggleLid() }
        Button("Reset Counter") { machine.resetCounter() }
    }
}

/// Fits a part of the scene to the window, and glides from one part to
/// another: the whole desk, or one box on it.
private struct SceneFrame<Content: View>: View, Animatable {
    var size: CGSize
    /// The rectangle of the scene, in millimetres, that should fill the window.
    var view: CGRect
    var onDeskTap: () -> Void
    @ViewBuilder var content: (CGFloat) -> Content

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(view.minX, view.minY), AnimatablePair(view.width, view.height)) }
        set {
            view = CGRect(
                x: newValue.first.first, y: newValue.first.second,
                width: newValue.second.first, height: newValue.second.second)
        }
    }

    var body: some View {
        let unit = min(size.width / max(1, view.width), size.height / max(1, view.height))
        let origin = CGPoint(x: size.width / 2 - view.midX * unit, y: size.height / 2 - view.midY * unit)
        ZStack(alignment: .topLeading) {
            WoodDesk(origin: origin)
                // A click on bare desk sits you back.
                .contentShape(Rectangle())
                .onTapGesture(perform: onDeskTap)
            content(unit)
                .frame(width: Desk.scene.width * unit, height: Desk.scene.height * unit, alignment: .topLeading)
                .offset(x: origin.x, y: origin.y)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.unit, unit)
    }
}

/// An invisible sheet over a box on the desk: hover shows it can be
/// approached, a click leans in over it.
private struct ZoomTarget: View {
    var name: String
    var action: () -> Void

    @Environment(\.unit) private var unit
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: unit * 3)
            .strokeBorder(.white.opacity(hovering ? 0.55 : 0), lineWidth: max(1.5, unit * 0.5))
            .background(RoundedRectangle(cornerRadius: unit * 3).fill(.white.opacity(hovering ? 0.05 : 0)))
            .overlay(alignment: .top) {
                if hovering {
                    Label("Zoom in on the \(name)", systemImage: "plus.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(.top, 8)
                        .fixedSize()
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .pointerStyle(.link)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityElement()
            .accessibilityLabel("Zoom in on the \(name)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

/// The strip at the top of the window while leaning in: back to the desk, or
/// straight across to another box.
private struct ZoomBar: View {
    @Bindable var desk: Desk

    var body: some View {
        HStack(spacing: 4) {
            chip("Desk", symbol: "chevron.backward", selected: false) { desk.focus = nil }
                .help("Back to the whole desk (Esc)")
            Divider()
                .frame(height: 14)
                .overlay(Color.white.opacity(0.25))
                .padding(.horizontal, 3)
            ForEach(Desk.Focus.allCases) { device in
                chip(device.name, symbol: nil, selected: desk.focus == device) { desk.focus = device }
            }
        }
        .padding(4)
        .background(.black.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
    }

    private func chip(_ title: String, symbol: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? Theme.brandOrange : Color.white.opacity(0.001), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// A pen and the cassette's label: title on the front, track sheet on the inlay.
struct LabelEditor: View {
    @State var cassette: Cassette
    var onDone: (Cassette) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            CassetteView(cassette: cassette)
                .environment(\.unit, 4.2)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
                .padding(.top, 6)

            TextField("Write something on the label", text: $cassette.title)
                .textFieldStyle(.roundedBorder)
                .font(.custom("BradleyHandITCTT-Bold", size: 20))
                .frame(width: 400)
                .onSubmit(finish)

            VStack(alignment: .leading, spacing: 6) {
                Text("TRACK SHEET")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(0..<4, id: \.self) { track in
                    HStack(spacing: 8) {
                        Text("\(track + 1)")
                            .font(.system(.body, design: .rounded).weight(.bold))
                            .frame(width: 18)
                        TextField(
                            ["Drum machine?", "Bass?", "Guitars?", "Vocals?"][track],
                            text: $cassette.trackNotes[track])
                            .textFieldStyle(.roundedBorder)
                            .font(.custom("BradleyHandITCTT-Bold", size: 15))
                    }
                }
            }
            .frame(width: 400)

            HStack {
                Text("\(cassette.design.brand) \(cassette.design.grade) \(cassette.stock.name) · \(Int(cassette.stock.playingTime / 60)) min at 1⅞ ips · side \(cassette.sideLetter)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(width: 400)
        }
        .padding(24)
    }

    private func finish() {
        onDone(cassette)
        dismiss()
    }
}
