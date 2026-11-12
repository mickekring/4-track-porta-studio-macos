import SwiftUI

/// Where the two reels of a cassette are right now, in drawing units.
nonisolated struct ReelState: Sendable, Equatable {
    /// Pack radii in millimetres.
    var supplyRadius: CGFloat
    var takeUpRadius: CGFloat
    /// Hub rotation in radians.
    var supplyAngle: Double
    var takeUpAngle: Double

    /// Reel state for a tape of `stock` with `position` frames wound past the head.
    init(stock: TapeStock, position: Double) {
        let geometry = ReelGeometry(stock: stock)
        let meters = position / CassetteStandard.framesPerMeter
        supplyRadius = geometry.supplyRadius(at: meters) * 1000
        takeUpRadius = geometry.takeUpRadius(at: meters) * 1000
        // Both hubs turn anticlockwise as the tape plays, seen from the label side.
        supplyAngle = -2 * .pi * geometry.supplyTurns(at: meters).truncatingRemainder(dividingBy: 1)
        takeUpAngle = -2 * .pi * geometry.takeUpTurns(at: meters).truncatingRemainder(dividingBy: 1)
    }
}

/// Draws a Compact Cassette, label side up, at one unit per millimetre.
enum CassetteArt {
    static let size = CGSize(width: 100.4, height: 63.8)
    static let hubY: CGFloat = 28.5
    static let leftHubX: CGFloat = 28.95
    static let rightHubX: CGFloat = 71.45
    static let window = CGRect(x: 20.2, y: 20.8, width: 60, height: 15.4)

    struct Palette {
        var shell: Color
        /// 1 for solid plastic, less for a see-through shell.
        var shellOpacity: Double
        var label: Color
        var strip: Color
        var stripInk: Color
        var accent: Color
        var writingArea: Color
    }

    static func palette(for design: CassetteDesign) -> Palette {
        switch design {
        case .rost:
            Palette(
                shell: Color(red: 0.17, green: 0.17, blue: 0.18), shellOpacity: 1,
                label: Color(red: 0.91, green: 0.88, blue: 0.80),
                strip: Color(red: 0.72, green: 0.13, blue: 0.10),
                stripInk: Color(red: 0.98, green: 0.96, blue: 0.90),
                accent: Color(red: 0.72, green: 0.13, blue: 0.10),
                writingArea: Color(red: 0.97, green: 0.96, blue: 0.92))
        case .krom:
            Palette(
                shell: Color(red: 0.06, green: 0.06, blue: 0.065), shellOpacity: 1,
                label: Color(red: 0.74, green: 0.75, blue: 0.76),
                strip: Color(red: 0.05, green: 0.05, blue: 0.055),
                stripInk: Color(red: 0.84, green: 0.68, blue: 0.32),
                accent: Color(red: 0.84, green: 0.68, blue: 0.32),
                writingArea: Color(red: 0.95, green: 0.95, blue: 0.95))
        case .studio:
            Palette(
                shell: Color(red: 0.10, green: 0.09, blue: 0.085), shellOpacity: 0.62,
                label: Color(red: 0.08, green: 0.08, blue: 0.085),
                strip: Theme.brandOrange,
                stripInk: Color(red: 0.06, green: 0.06, blue: 0.06),
                accent: Theme.brandOrange,
                writingArea: Color(red: 0.96, green: 0.95, blue: 0.92))
        case .pop:
            Palette(
                shell: Color(red: 0.90, green: 0.88, blue: 0.83), shellOpacity: 1,
                label: Color(red: 0.99, green: 0.99, blue: 0.97),
                strip: Color(red: 0.93, green: 0.18, blue: 0.48),
                stripInk: Color(red: 1.0, green: 0.93, blue: 0.25),
                accent: Color(red: 0.10, green: 0.68, blue: 0.70),
                writingArea: Color(red: 0.99, green: 0.99, blue: 0.97))
        }
    }

    // MARK: - Drawing

    /// Draws the cassette with its top-left corner at the origin.
    /// The context must already be scaled to millimetres.
    static func draw(_ context: GraphicsContext, cassette: Cassette, reels: ReelState, onSpindles: Bool = false) {
        let colours = palette(for: cassette.design)
        let body = CGRect(origin: .zero, size: size)
        let outline = Path(roundedRect: body, cornerRadius: 2.3)
        let windowPath = Path(roundedRect: window, cornerRadius: 1.6)

        // What you see through the plastic: darkness, two packs of tape, two hubs.
        context.fill(outline, with: .color(Color(white: 0.035)))
        var inside = context
        inside.clip(to: outline)
        drawPack(inside, centre: CGPoint(x: leftHubX, y: hubY), radius: reels.supplyRadius)
        drawPack(inside, centre: CGPoint(x: rightHubX, y: hubY), radius: reels.takeUpRadius)
        drawHub(inside, centre: CGPoint(x: leftHubX, y: hubY), angle: reels.supplyAngle)
        drawHub(inside, centre: CGPoint(x: rightHubX, y: hubY), angle: reels.takeUpAngle)
        if onSpindles {
            drawSpindle(inside, centre: CGPoint(x: leftHubX, y: hubY), angle: reels.supplyAngle)
            drawSpindle(inside, centre: CGPoint(x: rightHubX, y: hubY), angle: reels.takeUpAngle)
        }

        // The shell, with the window cut out of it.
        var shellShape = outline
        shellShape.addPath(windowPath)
        context.fill(
            shellShape,
            with: .linearGradient(
                Gradient(colors: [
                    colours.shell.mix(with: .white, by: 0.07).opacity(colours.shellOpacity),
                    colours.shell.opacity(colours.shellOpacity),
                    colours.shell.mix(with: .black, by: 0.25).opacity(colours.shellOpacity),
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)),
            style: FillStyle(eoFill: true))

        drawHeadSection(context, colours: colours)
        drawLabel(context, cassette: cassette, colours: colours, windowPath: windowPath)

        // Window glazing.
        context.stroke(windowPath, with: .color(.black.opacity(0.55)), lineWidth: 0.5)
        var glass = context
        glass.clip(to: windowPath)
        var glare = Path()
        glare.move(to: CGPoint(x: window.minX + 6, y: window.minY))
        glare.addLine(to: CGPoint(x: window.minX + 17, y: window.minY))
        glare.addLine(to: CGPoint(x: window.minX + 8, y: window.maxY))
        glare.addLine(to: CGPoint(x: window.minX - 3, y: window.maxY))
        glare.closeSubpath()
        glass.fill(glare, with: .color(.white.opacity(0.07)))
        glass.fill(glare.offsetBy(dx: 15, dy: 0).applying(.init(scaleX: 1, y: 1)), with: .color(.white.opacity(0.035)))

        // Screws.
        for point in [
            CGPoint(x: 3.7, y: 3.7), CGPoint(x: size.width - 3.7, y: 3.7),
            CGPoint(x: 3.7, y: size.height - 4.2), CGPoint(x: size.width - 3.7, y: size.height - 4.2),
            CGPoint(x: size.width / 2, y: size.height - 11.2),
        ] {
            drawScrew(context, at: point, shell: colours.shell)
        }

        // Record-protect notch on the spine, once the tab is snapped off.
        if cassette.recordProtected {
            context.fill(Path(CGRect(x: 6.2, y: -0.1, width: 4.2, height: 1.5)), with: .color(Color(white: 0.02)))
        }

        // Moulded edge: light catches the top, shadow gathers at the bottom.
        context.stroke(outline, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.22), .white.opacity(0.02), .black.opacity(0.5)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)), lineWidth: 0.45)
    }

    private static func drawPack(_ context: GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let circle = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        let oxide = Color(red: 0.185, green: 0.120, blue: 0.090)
        context.fill(circle, with: .radialGradient(
            Gradient(colors: [oxide.mix(with: .black, by: 0.35), oxide, oxide.mix(with: .black, by: 0.2)]),
            center: centre, startRadius: 5, endRadius: max(6, radius)))
        // The sheen you get on tightly wound tape.
        context.fill(circle, with: .conicGradient(
            Gradient(colors: [
                .clear, .white.opacity(0.13), .clear, .clear,
                .white.opacity(0.08), .clear, .clear,
            ]),
            center: centre, angle: .degrees(-35)))
        var ring = 7.0
        while ring < radius {
            context.stroke(
                Path(ellipseIn: CGRect(x: centre.x - ring, y: centre.y - ring, width: ring * 2, height: ring * 2)),
                with: .color(.black.opacity(0.10)), lineWidth: 0.18)
            ring += 1.15
        }
        context.stroke(circle, with: .color(.black.opacity(0.5)), lineWidth: 0.25)
    }

    private static func drawHub(_ context: GraphicsContext, centre: CGPoint, angle: Double) {
        var hub = context
        hub.translateBy(x: centre.x, y: centre.y)
        hub.rotate(by: .radians(angle))

        let plastic = Color(red: 0.93, green: 0.92, blue: 0.87)
        var ring = Path(ellipseIn: CGRect(x: -5.45, y: -5.45, width: 10.9, height: 10.9))
        ring.addPath(Path(ellipseIn: CGRect(x: -4.05, y: -4.05, width: 8.1, height: 8.1)))
        hub.fill(Path(ellipseIn: CGRect(x: -4.1, y: -4.1, width: 8.2, height: 8.2)), with: .color(Color(white: 0.02)))
        hub.fill(ring, with: .color(plastic), style: FillStyle(eoFill: true))
        for _ in 0..<6 {
            hub.fill(Path(roundedRect: CGRect(x: -0.68, y: -4.2, width: 1.36, height: 1.55), cornerRadius: 0.25), with: .color(plastic))
            hub.rotate(by: .degrees(60))
        }
        // A moulding mark, so you can see it turn.
        hub.fill(Path(ellipseIn: CGRect(x: -0.35, y: -5.1, width: 0.7, height: 0.7)), with: .color(.black.opacity(0.25)))
        hub.stroke(Path(ellipseIn: CGRect(x: -5.45, y: -5.45, width: 10.9, height: 10.9)), with: .color(.black.opacity(0.45)), lineWidth: 0.2)
    }

    /// The machine's drive spindle, poking up through a hub.
    static func drawSpindle(_ context: GraphicsContext, centre: CGPoint, angle: Double) {
        var spindle = context
        spindle.translateBy(x: centre.x, y: centre.y)
        spindle.rotate(by: .radians(angle))
        let metal = Color(white: 0.34)
        spindle.fill(Path(ellipseIn: CGRect(x: -2.5, y: -2.5, width: 5, height: 5)), with: .radialGradient(
            Gradient(colors: [Color(white: 0.5), metal, Color(white: 0.16)]),
            center: CGPoint(x: -0.6, y: -0.8), startRadius: 0, endRadius: 3))
        for _ in 0..<3 {
            spindle.fill(Path(roundedRect: CGRect(x: -0.5, y: -3.55, width: 1.0, height: 1.5), cornerRadius: 0.2), with: .color(metal))
            spindle.rotate(by: .degrees(120))
        }
        spindle.fill(Path(ellipseIn: CGRect(x: -0.7, y: -0.7, width: 1.4, height: 1.4)), with: .color(Color(white: 0.08)))
    }

    /// The thicker wedge along the open edge, where the heads and capstan go in.
    private static func drawHeadSection(_ context: GraphicsContext, colours: Palette) {
        let h = size.height
        let w = size.width
        var wedge = Path()
        wedge.move(to: CGPoint(x: 15.5, y: h))
        wedge.addLine(to: CGPoint(x: 21.5, y: h - 14.2))
        wedge.addLine(to: CGPoint(x: w - 21.5, y: h - 14.2))
        wedge.addLine(to: CGPoint(x: w - 15.5, y: h))
        wedge.closeSubpath()
        context.fill(wedge, with: .linearGradient(
            Gradient(colors: [
                colours.shell.mix(with: .white, by: 0.13).opacity(colours.shellOpacity),
                colours.shell.mix(with: .black, by: 0.12).opacity(colours.shellOpacity),
            ]),
            startPoint: CGPoint(x: 0, y: h - 14.2), endPoint: CGPoint(x: 0, y: h)))
        context.stroke(wedge, with: .color(.black.opacity(0.45)), lineWidth: 0.3)
        var topEdge = Path()
        topEdge.move(to: CGPoint(x: 21.5, y: h - 14.2))
        topEdge.addLine(to: CGPoint(x: w - 21.5, y: h - 14.2))
        context.stroke(topEdge, with: .color(.white.opacity(0.16)), lineWidth: 0.3)

        // Capstan holes and locating holes.
        for (x, radius) in [(w / 2 - 19.6, 2.5), (w / 2 + 19.6, 2.5), (w / 2 - 28.3, 1.55), (w / 2 + 28.3, 1.55)] {
            let hole = Path(ellipseIn: CGRect(x: x - radius, y: h - 6.6 - radius, width: radius * 2, height: radius * 2))
            context.fill(hole, with: .color(Color(white: 0.015)))
            context.stroke(hole, with: .color(.white.opacity(0.12)), lineWidth: 0.2)
        }
    }

    private static func drawLabel(_ context: GraphicsContext, cassette: Cassette, colours: Palette, windowPath: Path) {
        let labelRect = CGRect(x: 6.8, y: 3.4, width: size.width - 13.6, height: 43.4)
        var label = Path(roundedRect: labelRect, cornerRadius: 1.6)
        label.addPath(Path(roundedRect: window.insetBy(dx: -1.1, dy: -1.1), cornerRadius: 2.2))

        var paper = context
        paper.clip(to: label, style: FillStyle(eoFill: true))
        paper.fill(Path(labelRect), with: .color(colours.label))

        // Writing area with ruled lines.
        let writing = CGRect(x: labelRect.minX + 1.6, y: labelRect.minY + 1.5, width: labelRect.width - 3.2, height: 14.2)
        paper.fill(Path(roundedRect: writing, cornerRadius: 0.8), with: .color(colours.writingArea))
        for y in [writing.minY + 7.2, writing.minY + 12.6] {
            var rule = Path()
            rule.move(to: CGPoint(x: writing.minX + 9, y: y))
            rule.addLine(to: CGPoint(x: writing.maxX - 2, y: y))
            paper.stroke(rule, with: .color(.black.opacity(0.22)), lineWidth: 0.15)
        }

        // Side letter.
        let sideBox = CGRect(x: writing.minX + 1.4, y: writing.minY + 1.6, width: 6, height: 6)
        paper.fill(Path(roundedRect: sideBox, cornerRadius: 0.9), with: .color(colours.accent))
        paper.draw(
            Text(cassette.sideLetter)
                .font(.custom("HelveticaNeue-CondensedBlack", size: 5.2))
                .foregroundStyle(colours.writingArea),
            at: CGPoint(x: sideBox.midX, y: sideBox.midY), anchor: .center)

        // The handwriting.
        if !cassette.title.isEmpty {
            var pen = paper
            pen.translateBy(x: writing.minX + 9.6, y: writing.minY + 0.4)
            pen.rotate(by: .degrees(-1.2))
            let resolved = pen.resolve(
                Text(cassette.title)
                    .font(.custom("BradleyHandITCTT-Bold", size: 5.0))
                    .foregroundStyle(Color(red: 0.10, green: 0.16, blue: 0.42)))
            pen.draw(resolved, in: CGRect(x: 0, y: 0, width: writing.width - 12, height: 13.4))
        }

        // Brand strip under the window.
        let strip = CGRect(x: labelRect.minX, y: window.maxY + 2.2, width: labelRect.width, height: labelRect.maxY - window.maxY - 2.2)
        paper.fill(Path(strip), with: .color(colours.strip))
        if cassette.design == .pop {
            // Petrol-station exuberance.
            for (index, colour) in [colours.accent, colours.stripInk, colours.accent].enumerated() {
                var slash = Path()
                let x = strip.maxX - 34 + CGFloat(index) * 5.2
                slash.move(to: CGPoint(x: x + 4, y: strip.minY))
                slash.addLine(to: CGPoint(x: x + 7.4, y: strip.minY))
                slash.addLine(to: CGPoint(x: x + 3.4, y: strip.maxY))
                slash.addLine(to: CGPoint(x: x, y: strip.maxY))
                slash.closeSubpath()
                paper.fill(slash, with: .color(colour))
            }
        }
        paper.draw(
            Text(cassette.design.brand)
                .font(.custom("AvenirNextCondensed-HeavyItalic", size: 6.4))
                .foregroundStyle(colours.stripInk),
            at: CGPoint(x: strip.minX + 3.2, y: strip.midY - 0.2), anchor: .leading)
        paper.draw(
            Text(cassette.design.grade)
                .font(.custom("HelveticaNeue-CondensedBold", size: 3.6))
                .foregroundStyle(colours.stripInk.opacity(0.9)),
            at: CGPoint(x: strip.minX + 27.5, y: strip.midY - 1.3), anchor: .leading)
        paper.draw(
            Text(cassette.design.blurb)
                .font(.custom("HelveticaNeue-CondensedBold", size: 1.75))
                .foregroundStyle(colours.stripInk.opacity(0.8)),
            at: CGPoint(x: strip.minX + 27.5, y: strip.midY + 2.1), anchor: .leading)
        paper.draw(
            Text("\(cassette.stock.minutes)")
                .font(.custom("HelveticaNeue-CondensedBlack", size: 7.6))
                .foregroundStyle(colours.stripInk),
            at: CGPoint(x: strip.maxX - 3.4, y: strip.midY), anchor: .trailing)

        // Tick marks beside the window, for guessing how much tape is left.
        for tick in 0..<9 {
            let x = window.midX - 12 + CGFloat(tick) * 3
            var mark = Path()
            mark.move(to: CGPoint(x: x, y: window.minY - 1.9))
            mark.addLine(to: CGPoint(x: x, y: window.minY - (tick % 4 == 0 ? 3.6 : 2.8)))
            paper.stroke(mark, with: .color(.black.opacity(0.35)), lineWidth: 0.18)
        }

        context.stroke(Path(roundedRect: labelRect, cornerRadius: 1.6), with: .color(.black.opacity(0.25)), lineWidth: 0.2)
    }

    private static func drawScrew(_ context: GraphicsContext, at point: CGPoint, shell: Color) {
        let radius: CGFloat = 1.25
        let head = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.fill(head, with: .radialGradient(
            Gradient(colors: [Color(white: 0.62), Color(white: 0.30)]),
            center: CGPoint(x: point.x - 0.3, y: point.y - 0.4), startRadius: 0, endRadius: radius * 1.3))
        var slot = Path()
        slot.move(to: CGPoint(x: point.x - 0.75, y: point.y))
        slot.addLine(to: CGPoint(x: point.x + 0.75, y: point.y))
        slot.move(to: CGPoint(x: point.x, y: point.y - 0.75))
        slot.addLine(to: CGPoint(x: point.x, y: point.y + 0.75))
        context.stroke(slot, with: .color(.black.opacity(0.7)), lineWidth: 0.28)
        context.stroke(head, with: .color(.black.opacity(0.6)), lineWidth: 0.18)
    }
}

/// A cassette as a view, drawn at the environment's millimetre scale.
struct CassetteView: View {
    var cassette: Cassette
    var reels: ReelState
    var onSpindles: Bool

    @Environment(\.unit) private var unit

    init(cassette: Cassette, reels: ReelState? = nil, onSpindles: Bool = false) {
        self.cassette = cassette
        self.reels = reels ?? ReelState(stock: cassette.stock, position: cassette.position)
        self.onSpindles = onSpindles
    }

    var body: some View {
        Canvas { context, _ in
            var scaled = context
            scaled.scaleBy(x: unit, y: unit)
            CassetteArt.draw(scaled, cassette: cassette, reels: reels, onSpindles: onSpindles)
        }
        .frame(width: CassetteArt.size.width * unit, height: CassetteArt.size.height * unit)
    }
}

#Preview("Cassettes") {
    let titles = ["Summer demos '89", "Garage — DO NOT ERASE", "", "Mixtape för Anna"]
    VStack(spacing: 14) {
        ForEach(Array(CassetteDesign.allCases.enumerated()), id: \.offset) { index, design in
            let stock = TapeStock.all[index % 3]
            CassetteView(cassette: Cassette(
                title: titles[index], stock: stock, design: design,
                position: stock.totalLength * CassetteStandard.framesPerMeter * [0.02, 0.4, 0.75, 0.97][index],
                flipped: index == 3))
                .shadow(color: .black.opacity(0.5), radius: 6, y: 5)
        }
    }
    .padding(24)
    .background(Color(red: 0.42, green: 0.30, blue: 0.20))
    .environment(\.unit, 4)
}
