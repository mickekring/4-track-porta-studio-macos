import SwiftUI

/// The cassette well: spindles, heads, whatever tape is in there, and the
/// smoked flip-up lid with no latch that reviewers complained about.
struct CassetteWell: View {
    let machine: Machine
    /// True while the hand is holding the cassette that belongs in the well.
    var cassetteInHand: Bool
    /// 0 = lid shut, 1 = lid standing open.
    var lidOpening: Double
    var onLidTap: () -> Void
    var onCassetteTap: () -> Void

    @Environment(\.unit) private var unit

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The moulded recess and the mechanism in it.
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !machine.isMoving)) { _ in
                let report = machine.telemetry
                Canvas { context, _ in
                    var scaled = context
                    scaled.scaleBy(x: unit, y: unit)
                    Self.drawWell(scaled, engaged: CGFloat(report.capstan), spindleReels: emptyReels(report))
                }
            }
            .frame(width: Layout.size.width * unit, height: Layout.size.height * unit)
            .allowsHitTesting(false)

            if let cassette = machine.loaded, !cassetteInHand {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !machine.isMoving)) { _ in
                    CassetteView(
                        cassette: cassette,
                        reels: ReelState(stock: cassette.stock, position: machine.telemetry.position),
                        onSpindles: true)
                }
                .shadow(color: .black.opacity(0.6), radius: unit * 0.8, y: unit * 0.6)
                .offset(x: Layout.cassette.x * unit, y: Layout.cassette.y * unit)
                .onTapGesture { onCassetteTap() }
                .help(lidOpening > 0.5 ? "Take the cassette out" : "")
                .allowsHitTesting(lidOpening > 0.5)
                .accessibilityElement()
                .accessibilityLabel("Cassette in the machine: \(cassette.title.isEmpty ? "unlabelled" : cassette.title)")
            }

            lid
        }
        .frame(width: Layout.size.width * unit, height: Layout.size.height * unit, alignment: .topLeading)
    }

    /// With no cassette the bare spindles still turn if a key is down.
    private func emptyReels(_ report: Telemetry) -> ReelState {
        ReelState(stock: machine.loaded?.stock ?? .c60, position: report.position)
    }

    // MARK: - Lid

    private var lid: some View {
        let rect = Layout.lid
        // Swinging up on its rear hinge, the lid foreshortens to a sliver.
        let angle = lidOpening * 82
        return LidArt()
            .frame(width: rect.width * unit, height: rect.height * unit)
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.35)
            .opacity(1 - lidOpening * 0.25)
            .shadow(color: .black.opacity(0.35 * lidOpening), radius: unit * 3, y: -unit * 2 * lidOpening)
            .contentShape(Rectangle().size(
                width: rect.width * unit,
                height: rect.height * unit * (lidOpening > 0.5 ? 0.16 : 1)))
            .onTapGesture { onLidTap() }
            .offset(x: rect.minX * unit, y: rect.minY * unit)
            .help(lidOpening > 0.5 ? "Close the lid" : "Open the lid")
            .accessibilityElement()
            .accessibilityLabel("Cassette lid")
            .accessibilityValue(lidOpening > 0.5 ? "Open" : "Closed")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onLidTap() }
    }

    // MARK: - Mechanism

    static func drawWell(_ context: GraphicsContext, engaged: CGFloat, spindleReels: ReelState) {
        let well = Path(roundedRect: Layout.well, cornerRadius: 2.5)
        context.fill(well, with: .linearGradient(
            Gradient(colors: [Color(white: 0.02), Color(white: 0.055)]),
            startPoint: CGPoint(x: 0, y: Layout.well.minY), endPoint: CGPoint(x: 0, y: Layout.well.maxY)))
        // Shadow cast into the recess by its upper edge.
        var inner = context
        inner.clip(to: well)
        inner.fill(
            Path(CGRect(x: Layout.well.minX, y: Layout.well.minY, width: Layout.well.width, height: 7)),
            with: .linearGradient(
                Gradient(colors: [.black.opacity(0.9), .clear]),
                startPoint: CGPoint(x: 0, y: Layout.well.minY), endPoint: CGPoint(x: 0, y: Layout.well.minY + 7)))
        context.stroke(well, with: .linearGradient(
            Gradient(colors: [.black, .white.opacity(0.16)]),
            startPoint: CGPoint(x: 0, y: Layout.well.minY), endPoint: CGPoint(x: 0, y: Layout.well.maxY)), lineWidth: 0.4)

        let origin = Layout.cassette
        // Drive spindles.
        for (x, angle) in [(CassetteArt.leftHubX, spindleReels.supplyAngle), (CassetteArt.rightHubX, spindleReels.takeUpAngle)] {
            let centre = CGPoint(x: origin.x + x, y: origin.y + CassetteArt.hubY)
            context.fill(
                Path(ellipseIn: CGRect(x: centre.x - 5.2, y: centre.y - 5.2, width: 10.4, height: 10.4)),
                with: .color(Color(white: 0.085)))
            CassetteArt.drawSpindle(context, centre: centre, angle: angle)
        }
        // Locating pins.
        for offset in [-28.3, 28.3] {
            let centre = CGPoint(x: origin.x + CassetteArt.size.width / 2 + offset, y: origin.y + CassetteArt.size.height - 6.6)
            context.fill(
                Path(ellipseIn: CGRect(x: centre.x - 1.2, y: centre.y - 1.2, width: 2.4, height: 2.4)),
                with: .radialGradient(
                    Gradient(colors: [Color(white: 0.75), Color(white: 0.3)]),
                    center: CGPoint(x: centre.x - 0.3, y: centre.y - 0.3), startRadius: 0, endRadius: 1.4))
        }

        // The head block slides up into the cassette when PLAY goes down.
        let lift = -2.2 * engaged
        let centreX = origin.x + CassetteArt.size.width / 2
        let baseY = origin.y + CassetteArt.size.height + 2.3 + lift

        // Capstan shaft: always in the same place, tape or no tape.
        let capstan = CGPoint(x: centreX + 19.6, y: origin.y + CassetteArt.size.height - 6.6)
        context.fill(
            Path(ellipseIn: CGRect(x: capstan.x - 1.05, y: capstan.y - 1.05, width: 2.1, height: 2.1)),
            with: .radialGradient(
                Gradient(colors: [Color(white: 0.9), Color(white: 0.4)]),
                center: CGPoint(x: capstan.x - 0.3, y: capstan.y - 0.3), startRadius: 0, endRadius: 1.2))

        // Erase head: a small dark ferrite block.
        let erase = CGRect(x: centreX - 17.8, y: baseY - 1.9, width: 5.6, height: 4.2)
        context.fill(Path(roundedRect: erase, cornerRadius: 0.6), with: .color(Color(white: 0.16)))
        context.fill(Path(CGRect(x: erase.midX - 0.2, y: erase.minY, width: 0.4, height: 1.3)), with: .color(Color(white: 0.5)))

        // Record/play head: polished, with its four-track gap.
        let head = CGRect(x: centreX - 4.2, y: baseY - 2.4, width: 8.4, height: 5.2)
        context.fill(Path(roundedRect: head, cornerRadius: 1.2), with: .linearGradient(
            Gradient(colors: [Color(white: 0.86), Color(white: 0.52), Color(white: 0.30)]),
            startPoint: CGPoint(x: head.minX, y: head.minY), endPoint: CGPoint(x: head.maxX, y: head.maxY)))
        context.fill(Path(CGRect(x: head.midX - 0.15, y: head.minY, width: 0.3, height: 1.8)), with: .color(.black.opacity(0.7)))

        // Pinch roller.
        let roller = CGPoint(x: centreX + 19.6, y: baseY + 1.2)
        context.fill(
            Path(ellipseIn: CGRect(x: roller.x - 3.4, y: roller.y - 3.4, width: 6.8, height: 6.8)),
            with: .radialGradient(
                Gradient(colors: [Color(white: 0.2), Color(white: 0.07)]),
                center: roller, startRadius: 0.5, endRadius: 3.6))
        context.fill(
            Path(ellipseIn: CGRect(x: roller.x - 1, y: roller.y - 1, width: 2, height: 2)),
            with: .color(Color(white: 0.45)))
    }
}

/// The lid itself: smoked acrylic with a couple of window reflections.
private struct LidArt: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let radius = size.height * 0.055
            let shape = Path(roundedRect: rect, cornerRadius: radius)
            context.fill(shape, with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.10, green: 0.085, blue: 0.075).opacity(0.62),
                    Color(red: 0.05, green: 0.045, blue: 0.04).opacity(0.50),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            var glazing = context
            glazing.clip(to: shape)
            // Daylight from a window somewhere behind your left shoulder.
            for (start, width, strength) in [(0.10, 0.11, 0.075), (0.25, 0.035, 0.05), (0.72, 0.16, 0.035)] {
                var streak = Path()
                let x = size.width * start
                let w = size.width * width
                streak.move(to: CGPoint(x: x + size.height * 0.45, y: 0))
                streak.addLine(to: CGPoint(x: x + w + size.height * 0.45, y: 0))
                streak.addLine(to: CGPoint(x: x + w, y: size.height))
                streak.addLine(to: CGPoint(x: x, y: size.height))
                streak.closeSubpath()
                glazing.fill(streak, with: .color(.white.opacity(strength)))
            }
            // Hinge bar along the back edge.
            glazing.fill(
                Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.055)),
                with: .color(.black.opacity(0.55)))
            // Finger lip at the front.
            glazing.fill(
                Path(CGRect(x: size.width * 0.36, y: size.height * 0.955, width: size.width * 0.28, height: size.height * 0.045)),
                with: .color(.white.opacity(0.08)))

            context.stroke(shape, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.30), .white.opacity(0.06), .black.opacity(0.5)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)), lineWidth: 1)
            context.stroke(
                Path(roundedRect: rect.insetBy(dx: size.width * 0.02, dy: size.height * 0.035), cornerRadius: radius * 0.7),
                with: .color(.white.opacity(0.045)), lineWidth: 1)
        }
    }
}
