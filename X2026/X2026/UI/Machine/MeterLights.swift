import SwiftUI

/// The four LED bargraphs and the tri-colour arrow lamps beneath them.
///
/// Drawn over the faceplate at the same millimetre scale. In TAPE mode the
/// columns are tracks 1–4; in MIXER mode they are L, R, (dark) and AUX.
struct MeterLights: View {
    let machine: Machine

    @Environment(\.unit) private var unit

    var body: some View {
        // No timeline here: the machine publishes what the LEDs show only
        // when that changes, and SwiftUI redraws the Canvas only then.
        let segments = machine.meterSegments
        let lamps = machine.lamps
        Canvas { context, _ in
            var scaled = context
            scaled.scaleBy(x: unit, y: unit)
            Self.draw(scaled, segments: segments, lamps: lamps)
        }
        .frame(width: Layout.size.width * unit, height: Layout.size.height * unit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func colour(row: Int) -> Color {
        row <= 2 ? Theme.ledRed : Theme.ledAmber
    }

    /// - Parameters:
    ///   - segments: lit segments per column, counted from the bottom.
    ///   - lamps: colour of the arrow under each column.
    static func draw(_ context: GraphicsContext, segments: [Int], lamps: [TrackLamp]) {
        var glow = context
        glow.addFilter(.blur(radius: 1.6))

        let rows = Layout.meterRowY.count
        for column in 0..<4 {
            for row in 0..<rows {
                let rect = CGRect(
                    x: Layout.meterColumnX[column] - Layout.segment.width / 2,
                    y: Layout.meterRowY[row] - Layout.segment.height / 2,
                    width: Layout.segment.width, height: Layout.segment.height)
                let shape = Path(roundedRect: rect, cornerRadius: 0.5)
                let lit = row >= rows - segments[column]
                let colour = colour(row: row)
                if lit {
                    glow.fill(Path(roundedRect: rect.insetBy(dx: -1.0, dy: -0.8), cornerRadius: 1), with: .color(colour.opacity(0.55)))
                    context.fill(shape, with: .linearGradient(
                        Gradient(colors: [colour.mix(with: .white, by: 0.45), colour]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                } else {
                    context.fill(shape, with: .color(colour.mix(with: .black, by: 0.84)))
                }
                context.stroke(shape, with: .color(.black.opacity(0.55)), lineWidth: 0.15)
            }
        }

        for column in 0..<4 {
            let colour: Color = switch lamps[column] {
            case .tape: Theme.ledGreen
            case .standby: Theme.ledAmber
            case .recording: Theme.ledRed
            }
            let x = Layout.meterColumnX[column]
            let y = Layout.lampY
            var arrow = Path()
            arrow.move(to: CGPoint(x: x, y: y - 2.3))
            arrow.addLine(to: CGPoint(x: x + 2.3, y: y - 0.1))
            arrow.addLine(to: CGPoint(x: x + 1.15, y: y - 0.1))
            arrow.addLine(to: CGPoint(x: x + 1.15, y: y + 2.0))
            arrow.addLine(to: CGPoint(x: x - 1.15, y: y + 2.0))
            arrow.addLine(to: CGPoint(x: x - 1.15, y: y - 0.1))
            arrow.addLine(to: CGPoint(x: x - 2.3, y: y - 0.1))
            arrow.closeSubpath()
            glow.fill(arrow, with: .color(colour.opacity(0.7)))
            context.fill(arrow, with: .color(colour.mix(with: .white, by: 0.3)))
        }
    }
}

/// The five piano keys. They are mechanical: PLAY, REWIND and F FWD latch
/// down until STOP springs them back up, and pressing one releases the others.
struct TransportKeys: View {
    let machine: Machine

    @Environment(\.unit) private var unit

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(TransportKey.allCases, id: \.self) { key in
                KeyCap(isDown: machine.keysDown.contains(key) || machine.keyHeld == key)
                    .frame(width: Layout.keySize.width * unit, height: Layout.keySize.height * unit)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if machine.keyHeld != key { machine.press(key) }
                            }
                            .onEnded { _ in machine.release(key) }
                    )
                    .position(
                        x: Layout.keyX[key.rawValue] * unit,
                        y: (Layout.keyTop + Layout.keySize.height / 2) * unit)
                    .accessibilityElement()
                    .accessibilityLabel(key.title.capitalized)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        machine.press(key)
                        machine.release(key)
                    }
            }
        }
        .frame(width: Layout.size.width * unit, height: Layout.size.height * unit, alignment: .topLeading)
    }
}

/// One key seen from above. Pressed, its front edge has dropped into the
/// tray: it looks shorter and falls into shadow.
private struct KeyCap: View {
    var isDown: Bool

    @Environment(\.unit) private var unit

    var body: some View {
        Canvas { context, size in
            let travel = isDown ? size.height * 0.085 : 0
            let rect = CGRect(x: 0, y: travel * 0.35, width: size.width, height: size.height - travel)
            let shape = Path(roundedRect: rect.insetBy(dx: unit * 0.35, dy: 0), cornerRadius: unit * 0.9)
            let dim = isDown ? 0.55 : 1.0

            context.fill(shape, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(white: 0.185 * dim), location: 0),
                    .init(color: Color(white: 0.135 * dim), location: 0.30),
                    .init(color: Color(white: 0.100 * dim), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))

            // Grip ribs over the front two thirds.
            let ribs = 11
            let first = rect.minY + rect.height * 0.36
            let pitch = (rect.maxY - first - unit * 0.8) / CGFloat(ribs)
            for rib in 0..<ribs {
                let y = first + CGFloat(rib) * pitch
                var groove = Path()
                groove.move(to: CGPoint(x: rect.minX + unit * 1.0, y: y))
                groove.addLine(to: CGPoint(x: rect.maxX - unit * 1.0, y: y))
                context.stroke(groove, with: .color(.black.opacity(0.75)), lineWidth: max(0.5, unit * 0.3))
                context.stroke(
                    groove.offsetBy(dx: 0, dy: max(0.5, unit * 0.3)),
                    with: .color(.white.opacity(isDown ? 0.03 : 0.09)), lineWidth: max(0.5, unit * 0.16))
            }

            // The break where the flat top turns down into the ribbed face.
            var crease = Path()
            crease.move(to: CGPoint(x: rect.minX + unit * 0.6, y: rect.minY + rect.height * 0.30))
            crease.addLine(to: CGPoint(x: rect.maxX - unit * 0.6, y: rect.minY + rect.height * 0.30))
            context.stroke(crease, with: .color(.white.opacity(isDown ? 0.04 : 0.13)), lineWidth: max(0.5, unit * 0.2))

            context.stroke(shape, with: .color(.black.opacity(0.9)), lineWidth: max(0.5, unit * 0.2))
            if isDown {
                // Shadow of the tray lip across the sunken key.
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: size.width, height: rect.minY + unit * 2.2)),
                    with: .linearGradient(
                        Gradient(colors: [.black.opacity(0.85), .clear]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: rect.minY + unit * 2.2)))
            }
        }
        .animation(.snappy(duration: 0.07), value: isDown)
    }
}

#Preview("Meters") {
    Canvas { context, _ in
        var scaled = context
        scaled.scaleBy(x: 8, y: 8)
        scaled.translateBy(x: -60, y: -76)
        FaceplateArt.draw(scaled)
        MeterLights.draw(scaled, segments: [7, 5, 2, 0], lamps: [.recording, .standby, .tape, .tape])
    }
    .frame(width: 60 * 8, height: 90 * 8)
    .background(Theme.body)
}
