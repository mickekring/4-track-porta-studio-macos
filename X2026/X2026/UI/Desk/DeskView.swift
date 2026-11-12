import SwiftUI

/// The whole scene: a wooden desk, the machine in the middle of it, cassettes
/// lying around, and a hand that comes in to change the tape.
struct DeskView: View {
    @Bindable var desk: Desk

    private var machine: Machine { desk.machine }

    var body: some View {
        GeometryReader { proxy in
            SceneFrame(size: proxy.size, lean: desk.leanedIn ? 1 : 0) { unit in
                scene(unit: unit)
            }
            .animation(.smooth(duration: 0.55), value: desk.leanedIn)
        }
        .ignoresSafeArea()
        .sheet(item: $desk.editing) { cassette in
            LabelEditor(cassette: cassette) { edited in
                machine.relabel(edited)
            }
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

/// Fits the scene to the window, and glides between sitting back (the whole
/// desk in view) and leaning in (the machine filling the window).
private struct SceneFrame<Content: View>: View, Animatable {
    var size: CGSize
    /// 0 = sitting back, 1 = leaning in over the machine.
    var lean: Double
    @ViewBuilder var content: (CGFloat) -> Content

    var animatableData: Double {
        get { lean }
        set { lean = newValue }
    }

    private func fit(_ rect: CGRect) -> (unit: CGFloat, origin: CGPoint) {
        let unit = min(size.width / rect.width, size.height / rect.height)
        return (unit, CGPoint(
            x: size.width / 2 - rect.midX * unit,
            y: size.height / 2 - rect.midY * unit))
    }

    var body: some View {
        let far = fit(CGRect(origin: .zero, size: Desk.scene))
        let near = fit(Desk.machineFrame.insetBy(dx: -7, dy: -7))
        let unit = far.unit + (near.unit - far.unit) * lean
        let origin = Ease.mix(far.origin, near.origin, lean)
        ZStack(alignment: .topLeading) {
            WoodDesk(origin: origin)
            content(unit)
                .frame(width: Desk.scene.width * unit, height: Desk.scene.height * unit, alignment: .topLeading)
                .offset(x: origin.x, y: origin.y)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.unit, unit)
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
