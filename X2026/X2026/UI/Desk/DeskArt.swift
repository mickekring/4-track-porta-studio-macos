import SwiftUI

/// The desk top: oiled pine boards under a lamp.
///
/// The boards are laid out in scene millimetres from `origin`, so they stay
/// put under the machine as the view leans in and out.
struct WoodDesk: View {
    /// Where the scene's top-left corner is in the window.
    var origin: CGPoint = .zero

    @Environment(\.unit) private var unit

    var body: some View {
        Canvas { context, size in
            Self.draw(context, size: size, unit: unit, origin: origin)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private static let boardHeight: CGFloat = 86

    static func draw(_ context: GraphicsContext, size: CGSize, unit: CGFloat, origin: CGPoint) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.46, green: 0.31, blue: 0.19)))

        // Window edges in scene millimetres.
        let left = -origin.x / unit
        let right = (size.width - origin.x) / unit
        let top = -origin.y / unit
        let bottom = (size.height - origin.y) / unit
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }

        let firstBoard = Int(((top + 30) / boardHeight).rounded(.down)) - 1
        let lastBoard = Int(((bottom + 30) / boardHeight).rounded(.up))
        for board in firstBoard...lastBoard {
            // Every board came from a different tree, but always the same one.
            var random = NoiseSource(seed: UInt32(truncatingIfNeeded: board &* 7919 &+ 104_729))
            let boardTop = CGFloat(board) * boardHeight - 30
            let rect = CGRect(
                x: 0, y: origin.y + boardTop * unit, width: size.width, height: boardHeight * unit)
            let tint = Double(random.next()) * 0.045
            context.fill(Path(rect), with: .color(
                Color(red: 0.46 + tint, green: 0.31 + tint * 0.8, blue: 0.19 + tint * 0.5)))

            var clipped = context
            clipped.clip(to: Path(rect))

            // Grain: long lazy lines that wander and occasionally swell.
            let lines = 34
            for line in 0..<lines {
                let y0 = boardTop + (CGFloat(line) + 0.5 + CGFloat(random.next()) * 0.6) / CGFloat(lines) * boardHeight
                let amplitude = 0.5 + CGFloat(abs(random.next())) * 2.4
                let wavelength = 120 + CGFloat(abs(random.next())) * 260
                let phase = CGFloat(random.next()) * 6.28
                let dark = abs(random.next()) > 0.72
                var grain = Path()
                var x = (left / 14).rounded(.down) * 14
                grain.move(to: point(x, y0 + amplitude * sin(x / wavelength * 6.28 + phase)))
                while x < right + 14 {
                    x += 14
                    grain.addLine(to: point(x, y0 + amplitude * sin(x / wavelength * 6.28 + phase)))
                }
                clipped.stroke(
                    grain,
                    with: .color(Color(red: 0.22, green: 0.12, blue: 0.05).opacity(dark ? 0.22 : 0.09)),
                    lineWidth: (dark ? 0.55 : 0.35) * unit)
            }

            // The odd knot.
            let knotChance = abs(random.next())
            let knotX = -200 + 1000 * CGFloat(abs(random.next()))
            let knotY = boardTop + boardHeight * CGFloat(0.3 + 0.4 * abs(random.next()))
            if knotChance > 0.45 {
                let centre = point(knotX, knotY)
                for ring in 0..<5 {
                    let radius = (2.2 + CGFloat(ring) * 1.9) * unit
                    clipped.stroke(
                        Path(ellipseIn: CGRect(x: centre.x - radius * 1.9, y: centre.y - radius, width: radius * 3.8, height: radius * 2)),
                        with: .color(Color(red: 0.20, green: 0.10, blue: 0.04).opacity(0.32 - Double(ring) * 0.05)),
                        lineWidth: 0.5 * unit)
                }
                clipped.fill(
                    Path(ellipseIn: CGRect(x: centre.x - 3.6 * unit, y: centre.y - 1.9 * unit, width: 7.2 * unit, height: 3.8 * unit)),
                    with: .color(Color(red: 0.19, green: 0.10, blue: 0.045).opacity(0.75)))
            }

            // The joint between boards.
            context.fill(
                Path(CGRect(x: 0, y: rect.maxY - 0.5 * unit, width: size.width, height: 0.55 * unit)),
                with: .color(.black.opacity(0.42)))
            context.fill(
                Path(CGRect(x: 0, y: rect.maxY + 0.05 * unit, width: size.width, height: 0.4 * unit)),
                with: .color(.white.opacity(0.07)))
        }

        // Lamplight pooling in the middle, falling off to the corners.
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.42)]),
                center: CGPoint(x: size.width * 0.44, y: size.height * 0.36),
                startRadius: 0, endRadius: max(size.width, size.height) * 0.78))
    }
}

/// A shrink-wrapped brick of blank cassettes. Click it to unwrap one.
struct BlankTapeBox: View {
    var onUnwrap: (TapeStock, CassetteDesign) -> Void

    @Environment(\.unit) private var unit

    static let size = CGSize(width: 62, height: 70)

    var body: some View {
        Menu {
            ForEach(CassetteDesign.allCases, id: \.self) { design in
                Section("\(design.brand) \(design.grade)") {
                    ForEach(TapeStock.all) { stock in
                        Button("\(stock.name) — \(Int(stock.playingTime / 60)) minutes of four-track") {
                            onUnwrap(stock, design)
                        }
                    }
                }
            }
        } label: {
            Canvas { context, _ in
                var scaled = context
                scaled.scaleBy(x: unit, y: unit)
                Self.draw(scaled)
            }
            .frame(width: Self.size.width * unit, height: Self.size.height * unit)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .shadow(color: .black.opacity(0.5), radius: 3 * unit, x: 1.5 * unit, y: 3 * unit)
        .help("Unwrap a new blank cassette")
        .accessibilityLabel("Blank cassettes")
    }

    static func draw(_ context: GraphicsContext) {
        let rect = CGRect(origin: .zero, size: size)
        let card = Color(red: 0.80, green: 0.66, blue: 0.45)
        let box = Path(roundedRect: rect, cornerRadius: 1.5)
        context.fill(box, with: .linearGradient(
            Gradient(colors: [card.mix(with: .white, by: 0.12), card, card.mix(with: .black, by: 0.22)]),
            startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))

        // The spines of the cassettes inside, showing through the cut-out.
        let cutout = CGRect(x: 6, y: 20, width: 50, height: 30)
        context.fill(Path(roundedRect: cutout, cornerRadius: 1), with: .color(Color(white: 0.05)))
        let spines: [Color] = [
            Theme.brandOrange, Color(red: 0.72, green: 0.13, blue: 0.10), Color(white: 0.80),
            Color(red: 0.84, green: 0.68, blue: 0.32), Color(red: 0.10, green: 0.68, blue: 0.70),
        ]
        for (index, colour) in spines.enumerated() {
            let spine = CGRect(x: cutout.minX + 1.4, y: cutout.minY + 1.5 + CGFloat(index) * 5.5, width: cutout.width - 2.8, height: 4.6)
            context.fill(Path(roundedRect: spine, cornerRadius: 0.5), with: .color(Color(white: 0.13)))
            context.fill(Path(CGRect(x: spine.minX + 2, y: spine.minY + 1.1, width: 19, height: 2.4)), with: .color(colour))
            context.fill(Path(CGRect(x: spine.maxX - 13, y: spine.minY + 1.5, width: 10, height: 1.6)), with: .color(.white.opacity(0.35)))
        }

        let ink = Color(red: 0.23, green: 0.15, blue: 0.08)
        context.draw(
            Text("BLANK TAPES").font(.custom("HelveticaNeue-CondensedBlack", size: 7.2)).foregroundStyle(ink),
            at: CGPoint(x: size.width / 2, y: 10.5), anchor: .center)
        context.draw(
            Text("TEAR HERE ✂︎ – – – – – –").font(.custom("HelveticaNeue-Medium", size: 2.4)).foregroundStyle(ink.opacity(0.7)),
            at: CGPoint(x: size.width / 2, y: 56), anchor: .center)
        context.draw(
            Text("C-46 · C-60 · C-90").font(.custom("HelveticaNeue-Bold", size: 3.4)).foregroundStyle(ink),
            at: CGPoint(x: size.width / 2, y: 62.5), anchor: .center)

        // Shrink wrap catching the light.
        var gloss = Path()
        gloss.move(to: CGPoint(x: 8, y: 0))
        gloss.addLine(to: CGPoint(x: 20, y: 0))
        gloss.addLine(to: CGPoint(x: 2, y: size.height))
        gloss.addLine(to: CGPoint(x: 0, y: size.height))
        gloss.addLine(to: CGPoint(x: 0, y: 30))
        gloss.closeSubpath()
        var wrapped = context
        wrapped.clip(to: box)
        wrapped.fill(gloss, with: .color(.white.opacity(0.16)))
        wrapped.fill(gloss.offsetBy(dx: 34, dy: 0), with: .color(.white.opacity(0.07)))
        context.stroke(box, with: .color(.black.opacity(0.4)), lineWidth: 0.3)
    }
}
