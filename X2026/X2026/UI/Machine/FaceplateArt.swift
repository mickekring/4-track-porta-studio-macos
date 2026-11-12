import SwiftUI

/// Everything on the top panel that does not move: the moulded chassis and
/// the white screen printing. Drawn at one unit per millimetre.
enum FaceplateArt {
    private enum Scale {
        /// 0 – 5 – 10
        case level
        /// L – R
        case pan
        /// INPUT ← 0 → TRK n
        case dual(track: Int)
        /// − 0 +
        case pitch
    }

    private static let line = Theme.legend.opacity(0.78)

    static func draw(_ context: GraphicsContext) {
        chassis(context)
        rearLegends(context)
        inputSection(context)
        inputTapeSection(context)
        meterWindow(context)
        equaliser(context)
        masterSection(context)
        switchLegends(context)
        deckSide(context)
        transportLegends(context)
        logo(context)
    }

    // MARK: - Helpers

    private static func text(
        _ context: GraphicsContext, _ string: String, _ x: CGFloat, _ y: CGFloat,
        size: CGFloat = 2.15, anchor: UnitPoint = .center, bold: Bool = false, colour: Color = Theme.legend
    ) {
        context.draw(
            Text(string)
                .font(.custom(bold ? "HelveticaNeue-Bold" : "HelveticaNeue-Medium", size: size))
                .foregroundStyle(colour),
            at: CGPoint(x: x, y: y), anchor: anchor)
    }

    private static func stroke(_ context: GraphicsContext, _ points: [CGPoint], width: CGFloat = 0.22) {
        var path = Path()
        path.addLines(points)
        context.stroke(path, with: .color(line), lineWidth: width)
    }

    private static func knobScale(_ context: GraphicsContext, at centre: CGPoint, kind: Scale) {
        let radius: CGFloat = 7.5
        for index in 0...10 {
            let angle = Angle.degrees(-150 + Double(index) * 30).radians
            let point = CGPoint(x: centre.x + radius * sin(angle), y: centre.y - radius * cos(angle))
            let major = index % 5 == 0
            let dot = major ? 0.36 : 0.24
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)),
                with: .color(line))
        }
        switch kind {
        case .level:
            text(context, "0", centre.x - 6.3, centre.y + 8.6, size: 1.8)
            text(context, "5", centre.x, centre.y - 9.5, size: 1.8)
            text(context, "10", centre.x + 6.5, centre.y + 8.6, size: 1.8)
        case .pan:
            text(context, "L", centre.x - 6.3, centre.y + 8.6, size: 1.8)
            text(context, "R", centre.x + 6.3, centre.y + 8.6, size: 1.8)
        case .dual(let track):
            text(context, "0", centre.x, centre.y - 9.5, size: 1.8)
            text(context, "INPUT", centre.x - 7.4, centre.y + 9.0, size: 1.55)
            text(context, "TRK \(track)", centre.x + 7.4, centre.y + 9.0, size: 1.55)
        case .pitch:
            text(context, "0", centre.x, centre.y - 9.5, size: 1.8)
            text(context, "–", centre.x - 6.0, centre.y + 8.4, size: 2.2)
            text(context, "+", centre.x + 6.0, centre.y + 8.4, size: 2.2)
        }
    }

    private static func faderScale(_ context: GraphicsContext, x: CGFloat) {
        for mark in 0...10 {
            let y = Layout.faderBottom - CGFloat(mark) / 10 * Layout.faderTravel
            text(context, "\(mark)", x - 7.6, y, size: 1.9, anchor: .trailing)
            stroke(context, [CGPoint(x: x + 6.4, y: y), CGPoint(x: x + 9.6, y: y)])
        }
        // The fine graduations around the nominal 7-to-8 working position.
        for fine in 1...4 {
            let y = Layout.faderBottom - (7 + CGFloat(fine) / 5) / 10 * Layout.faderTravel
            stroke(context, [CGPoint(x: x + 6.4, y: y), CGPoint(x: x + 8.6, y: y)], width: 0.16)
        }
    }

    // MARK: - Chassis

    private static func chassis(_ context: GraphicsContext) {
        let bounds = CGRect(origin: .zero, size: Layout.size)
        let body = Path(roundedRect: bounds, cornerRadius: 5)
        context.fill(body, with: .linearGradient(
            Gradient(colors: [Theme.bodyHighlight, Theme.body, Theme.body.mix(with: .black, by: 0.25)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: Layout.size.height)))

        // Rear lip carrying the socket legends.
        let lip = Path(roundedRect: CGRect(x: 0, y: 0, width: Layout.size.width, height: 11), cornerRadius: 5)
        context.fill(lip, with: .linearGradient(
            Gradient(colors: [Color(white: 0.20), Color(white: 0.115)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: 11)))
        context.stroke(
            Path { $0.move(to: CGPoint(x: 3, y: 11.2)); $0.addLine(to: CGPoint(x: Layout.size.width - 3, y: 11.2)) },
            with: .color(.black.opacity(0.7)), lineWidth: 0.5)

        // The mixer sits on a slightly raised platform.
        let platform = Path(roundedRect: CGRect(x: 4, y: 13, width: 219.5, height: 164.5), cornerRadius: 3.5)
        context.fill(platform.offsetBy(dx: 0.5, dy: 1.1), with: .color(.black.opacity(0.55)))
        context.fill(platform, with: .linearGradient(
            Gradient(colors: [Color(white: 0.128), Color(white: 0.098)]),
            startPoint: CGPoint(x: 0, y: 13), endPoint: CGPoint(x: 0, y: 177)))
        context.stroke(platform, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.16), .white.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: 13), endPoint: CGPoint(x: 0, y: 60)), lineWidth: 0.3)

        // The switch bank is its own strip, a step above again.
        let bank = Path(roundedRect: CGRect(x: 203.6, y: 16.5, width: 18.2, height: 158), cornerRadius: 2.2)
        context.fill(bank, with: .color(Color(white: 0.075)))
        context.stroke(bank, with: .color(.white.opacity(0.07)), lineWidth: 0.25)

        // Front bumper.
        let bumper = Path(roundedRect: CGRect(x: 0, y: 181, width: Layout.size.width, height: 14), cornerRadius: 5)
        context.fill(bumper, with: .linearGradient(
            Gradient(colors: [Color(white: 0.145), Color(white: 0.085), Color(white: 0.05)]),
            startPoint: CGPoint(x: 0, y: 181), endPoint: CGPoint(x: 0, y: 195)))
        context.stroke(
            Path { $0.move(to: CGPoint(x: 4, y: 181.3)); $0.addLine(to: CGPoint(x: Layout.size.width - 4, y: 181.3)) },
            with: .color(.white.opacity(0.10)), lineWidth: 0.3)

        // Recess the transport keys sit in.
        let tray = Path(roundedRect: Layout.keyTray, cornerRadius: 2.4)
        context.fill(tray, with: .color(Color(white: 0.02)))
        context.stroke(tray, with: .linearGradient(
            Gradient(colors: [.black, .white.opacity(0.14)]),
            startPoint: CGPoint(x: 0, y: Layout.keyTray.minY), endPoint: CGPoint(x: 0, y: Layout.keyTray.maxY)),
            lineWidth: 0.4)

        // Moulded edge of the whole case.
        context.stroke(body, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.22), .white.opacity(0.03), .black.opacity(0.6)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: Layout.size.height)), lineWidth: 0.5)
    }

    private static func rearLegends(_ context: GraphicsContext) {
        func group(_ title: String, labels: [(String, CGFloat)]) {
            guard let first = labels.first, let last = labels.last else { return }
            for (label, x) in labels { text(context, label, x, 3.6, size: 1.7) }
            if labels.count > 1 {
                for index in 0..<(labels.count - 1) {
                    let a = labels[index].1 + CGFloat(labels[index].0.count) * 0.55 + 0.8
                    let b = labels[index + 1].1 - CGFloat(labels[index + 1].0.count) * 0.55 - 0.8
                    if b > a { stroke(context, [CGPoint(x: a, y: 3.6), CGPoint(x: b, y: 3.6)], width: 0.18) }
                }
            }
            text(context, title, (first.1 + last.1) / 2, 7.9, size: 1.7)
        }
        group("TAPE OUT", labels: [("1", Layout.tapeOutX[0]), ("2", Layout.tapeOutX[1]), ("3", Layout.tapeOutX[2]), ("4/SYNC", Layout.tapeOutX[3])])
        group("LINE OUT", labels: [("L", Layout.lineOutX[0]), ("R", Layout.lineOutX[1])])
        group("AUX", labels: [("SEND", Layout.auxSendJackX), ("RCV-L", Layout.auxReturnJackX[0]), ("RCV-R", Layout.auxReturnJackX[1])])
        group("MON OUT", labels: [("L", Layout.monitorOutX[0]), ("R", Layout.monitorOutX[1])])
        group("POWER", labels: [("OFF", 280), ("ON", 291)])
        text(context, "DC IN 11V–15V", 324, 7.9, size: 1.7)
        text(context, "+ –◉– –", 324, 3.6, size: 1.7)
    }

    // MARK: - Mixer

    private static func inputSection(_ context: GraphicsContext) {
        text(context, "INPUT", 15.4, 16.3, size: 2.5, anchor: .leading, bold: true)
        stroke(context, [CGPoint(x: 14.6, y: 14.2), CGPoint(x: 14.6, y: 176)])
        stroke(context, [CGPoint(x: 38.6, y: 19), CGPoint(x: 38.6, y: 176)])
        stroke(context, [CGPoint(x: 63.3, y: 14.2), CGPoint(x: 63.3, y: 176)])
        stroke(context, [CGPoint(x: 14.6, y: 14.2), CGPoint(x: 63.3, y: 14.2)])

        text(context, "AUX", 9.3, Layout.auxY, size: 2.15)
        text(context, "PAN", 9.3, Layout.panY, size: 2.15)
        text(context, "GAIN", 9.3, Layout.gainY, size: 2.15)

        for channel in 0..<2 {
            let x = Layout.channelX[channel]
            text(context, "\(channel + 1)", x - 9.6, 20.3, size: 2.5, bold: true)
            knobScale(context, at: CGPoint(x: x, y: Layout.auxY), kind: .level)
            knobScale(context, at: CGPoint(x: x, y: Layout.panY), kind: .pan)
            text(context, "MIC", x - 2.6, Layout.gainY - 3.7, size: 1.85, anchor: .trailing)
            text(context, "LINE", x - 2.6, Layout.gainY + 3.9, size: 1.85, anchor: .trailing)
            faderScale(context, x: x)
            text(context, "\(channel + 1)", x, Layout.numberY, size: 5.4)
        }
    }

    private static func inputTapeSection(_ context: GraphicsContext) {
        text(context, "INPUT/TAPE", 65.3, 16.3, size: 2.5, anchor: .leading, bold: true)
        // Outline around the twelve knobs, and the bay below with meters and EQ.
        context.stroke(
            Path(roundedRect: CGRect(x: 64.6, y: 18.4, width: 99.4, height: 62.4), cornerRadius: 2.4),
            with: .color(line), lineWidth: 0.22)
        context.stroke(
            Path(roundedRect: CGRect(x: 67.6, y: 81.9, width: 96.4, height: 78.4), cornerRadius: 2.6),
            with: .color(line), lineWidth: 0.22)

        for channel in 0..<4 {
            let x = Layout.channelX[channel + 2]
            text(context, "\(channel + 3)", x - 9.7, 21.4, size: 2.5, bold: true)
            knobScale(context, at: CGPoint(x: x, y: Layout.auxY), kind: .dual(track: channel + 1))
            knobScale(context, at: CGPoint(x: x, y: Layout.panY), kind: .pan)
            knobScale(context, at: CGPoint(x: x, y: Layout.gainY), kind: .dual(track: channel + 1))
            text(context, "\(channel + 3)", x - 0.4, Layout.numberY, size: 5.4)
            if channel > 0 {
                let divider = (x + Layout.channelX[channel + 1]) / 2
                stroke(context, [CGPoint(x: divider, y: 18.4), CGPoint(x: divider, y: 38.2)])
                stroke(context, [CGPoint(x: divider, y: 41.6), CGPoint(x: divider, y: 80.8)])
                stroke(context, [CGPoint(x: divider, y: 162.6), CGPoint(x: divider, y: 176)])
            }
        }
        stroke(context, [CGPoint(x: 164, y: 162.6), CGPoint(x: 164, y: 176)])
        text(context, "SUB MIX", 113.6, 39.9, size: 1.75)
        stroke(context, [CGPoint(x: 66, y: 39.9), CGPoint(x: 107.5, y: 39.9)], width: 0.16)
        stroke(context, [CGPoint(x: 119.7, y: 39.9), CGPoint(x: 162.6, y: 39.9)], width: 0.16)
    }

    private static func meterWindow(_ context: GraphicsContext) {
        let window = Path(roundedRect: Layout.meter, cornerRadius: 1.2)
        context.fill(window, with: .color(Color(white: 0.17)))
        context.stroke(window, with: .linearGradient(
            Gradient(colors: [.black.opacity(0.9), .white.opacity(0.18)]),
            startPoint: CGPoint(x: 0, y: Layout.meter.minY), endPoint: CGPoint(x: 0, y: Layout.meter.maxY)),
            lineWidth: 0.35)

        let left = Layout.meter.minX + 2.7
        let right = Layout.meter.maxX - 2.7
        let ink = Color(white: 0.9)
        for (row, mark) in Layout.meterMarks.enumerated() {
            text(context, mark, left, Layout.meterRowY[row], size: 1.9, colour: ink)
            text(context, mark, right, Layout.meterRowY[row], size: 1.9, colour: ink)
        }
        let top = Layout.meter.minY + 3.3
        let bottom = Layout.meter.maxY - 2.4
        text(context, "+", left, top, size: 2.2, colour: ink)
        text(context, "+", right, top, size: 2.2, colour: ink)
        text(context, "–", left, bottom, size: 2.2, colour: ink)
        text(context, "–", right, bottom, size: 2.2, colour: ink)
        text(context, "L", Layout.meterColumnX[0], top, size: 1.9, colour: ink)
        text(context, "R", Layout.meterColumnX[1], top, size: 1.9, colour: ink)
        text(context, "AUX", Layout.meterColumnX[3] - 0.4, top, size: 1.75, colour: ink)
        for column in 0..<4 {
            text(context, "\(column + 1)", Layout.meterColumnX[column], bottom, size: 1.9, colour: ink)
        }

        text(context, "TAPE", Layout.meterSwitch.x - 5.2, Layout.meterSwitch.y - 5.0, size: 1.85)
        text(context, "MIXER", Layout.meterSwitch.x + 5.4, Layout.meterSwitch.y - 5.0, size: 1.85)
        stroke(context, [CGPoint(x: Layout.meterSwitch.x - 8.4, y: Layout.meterSwitch.y - 3.4), CGPoint(x: Layout.meterSwitch.x - 2, y: Layout.meterSwitch.y - 3.4)], width: 0.18)
        stroke(context, [CGPoint(x: Layout.meterSwitch.x + 1.6, y: Layout.meterSwitch.y - 3.4), CGPoint(x: Layout.meterSwitch.x + 9.3, y: Layout.meterSwitch.y - 3.4)], width: 0.18)
    }

    private static func equaliser(_ context: GraphicsContext) {
        for (top, bottom, name) in [
            (Layout.eqHighTop, Layout.eqHighBottom, "EQ HI"),
            (Layout.eqLowTop, Layout.eqLowBottom, "EQ LO"),
        ] {
            let middle = (top + bottom) / 2
            text(context, "+10", Layout.eqLX - 5.6, top, size: 1.9, anchor: .trailing)
            text(context, name, Layout.eqLX - 5.6, middle, size: 1.9, anchor: .trailing)
            text(context, "–10", Layout.eqLX - 5.6, bottom, size: 1.9, anchor: .trailing)
            text(context, "+10", Layout.eqRX + 5.6, top, size: 1.9, anchor: .leading)
            text(context, name, Layout.eqRX + 5.6, middle, size: 1.9, anchor: .leading)
            text(context, "–10", Layout.eqRX + 5.6, bottom, size: 1.9, anchor: .leading)
        }
        text(context, "L", Layout.eqLX - 6.4, 156.6, size: 2.0)
        text(context, "R", Layout.eqRX + 6.4, 156.6, size: 2.0)
        stroke(context, [CGPoint(x: Layout.eqLX - 4.8, y: 156.6), CGPoint(x: Layout.eqRX + 4.8, y: 156.6)], width: 0.18)
    }

    private static func masterSection(_ context: GraphicsContext) {
        let x = Layout.masterX
        text(context, "AUX", x - 10.6, 18.6, size: 1.9, anchor: .leading)
        text(context, "SEND", x - 10.6, 21.1, size: 1.9, anchor: .leading)
        knobScale(context, at: CGPoint(x: x, y: Layout.auxSendY), kind: .level)
        knobScale(context, at: CGPoint(x: x, y: Layout.returnLY), kind: .level)
        knobScale(context, at: CGPoint(x: x, y: Layout.returnRY), kind: .level)
        text(context, "L", x - 10.2, Layout.returnLY, size: 1.9)
        text(context, "AUX", x - 10.2, 58.2, size: 1.75)
        text(context, "RCV", x - 10.2, 60.7, size: 1.75)
        text(context, "R", x - 10.2, Layout.returnRY, size: 1.9)
        faderScale(context, x: x)
        text(context, "MASTER", x, 161.4, size: 2.15)
    }

    private static func switchLegends(_ context: GraphicsContext) {
        let edge: CGFloat = 202.2
        func tick(_ y: CGFloat) {
            stroke(context, [CGPoint(x: edge + 0.3, y: y), CGPoint(x: edge + 1.6, y: y)], width: 0.18)
        }

        // Noise reduction.
        let nr = Layout.noiseReductionY
        drawQuietMark(context, at: CGPoint(x: edge - 6.6, y: nr - 6.0), height: 2.0)
        text(context, "NR", edge - 0.4, nr - 6.0, size: 2.0, anchor: .trailing)
        text(context, "ON", edge - 0.4, nr - 3.0, size: 1.9, anchor: .trailing)
        text(context, "OFF", edge - 0.4, nr + 3.4, size: 1.9, anchor: .trailing)
        tick(nr - 3.0)
        tick(nr + 3.4)

        // Monitor selector.
        let monitor = Layout.monitorY
        text(context, "LINE +", edge - 0.4, monitor - 6.9, size: 1.75, anchor: .trailing)
        text(context, "AUX", edge - 0.4, monitor - 4.6, size: 1.75, anchor: .trailing)
        text(context, "AUX", edge - 0.4, monitor, size: 1.75, anchor: .trailing)
        text(context, "LINE +", edge - 0.4, monitor + 4.5, size: 1.75, anchor: .trailing)
        text(context, "SUB MIX", edge - 0.4, monitor + 6.8, size: 1.75, anchor: .trailing)
        tick(monitor - 5.6)
        tick(monitor)
        tick(monitor + 5.6)

        // REMIX / NORM.
        let remix = Layout.remixY
        text(context, "REMIX", edge - 0.4, remix - 3.0, size: 1.85, anchor: .trailing)
        text(context, "NORM", edge - 0.4, remix + 3.4, size: 1.85, anchor: .trailing)
        tick(remix - 3.0)
        tick(remix + 3.4)

        // Record track selectors.
        for (y, upper, lower, side) in [(Layout.recordLY, "1", "3", "L"), (Layout.recordRY, "2", "4", "R")] {
            text(context, upper, edge - 0.6, y - 4.4, size: 2.0, anchor: .trailing)
            text(context, "•", edge - 0.6, y, size: 2.0, anchor: .trailing)
            text(context, lower, edge - 0.6, y + 4.4, size: 2.0, anchor: .trailing)
            tick(y - 4.4)
            tick(y + 4.4)
            text(context, side, 226.2, y, size: 2.1)
        }
        text(context, "REC", edge - 5.6, (Layout.recordLY + Layout.recordRY) / 2 - 1.2, size: 1.85)
        text(context, "TRK", edge - 5.6, (Layout.recordLY + Layout.recordRY) / 2 + 1.3, size: 1.85)

        // The bracket tying the monitor selector to its level knob.
        stroke(context, [
            CGPoint(x: 222.6, y: monitor), CGPoint(x: 227.6, y: monitor),
            CGPoint(x: 227.6, y: 19.6), CGPoint(x: 231.2, y: 19.6),
        ])
    }

    /// Our own noise-reduction mark: three bars of hiss dying away.
    private static func drawQuietMark(_ context: GraphicsContext, at centre: CGPoint, height: CGFloat) {
        let bar = height * 0.3
        for (index, scale) in [1.0, 0.62, 0.3].enumerated() {
            let x = centre.x - bar * 1.9 + CGFloat(index) * bar * 1.4
            let tall = height * scale
            context.fill(
                Path(CGRect(x: x, y: centre.y + height / 2 - tall, width: bar, height: tall)),
                with: .color(Theme.legend))
        }
    }

    // MARK: - Deck side

    private static func deckSide(_ context: GraphicsContext) {
        text(context, "MONITOR", Layout.monitorKnob.x, 19.6, size: 2.0)
        knobScale(context, at: Layout.monitorKnob, kind: .level)
        text(context, "PITCH", Layout.pitchKnob.x, 19.6, size: 2.0)
        knobScale(context, at: Layout.pitchKnob, kind: .pitch)

        // Counter bezel.
        let bezel = CGRect(x: Layout.counter.x - 9.2, y: Layout.counter.y - 4.6, width: 31.6, height: 9.2)
        context.fill(Path(roundedRect: bezel, cornerRadius: 1.2), with: .color(Color(white: 0.03)))
        context.stroke(Path(roundedRect: bezel, cornerRadius: 1.2), with: .linearGradient(
            Gradient(colors: [.black, .white.opacity(0.16)]),
            startPoint: CGPoint(x: 0, y: bezel.minY), endPoint: CGPoint(x: 0, y: bezel.maxY)), lineWidth: 0.35)

        // Noise-reduction badge.
        let badge = CGRect(x: Layout.badge.x - 12.2, y: Layout.badge.y - 1.7, width: 24.4, height: 3.4)
        context.stroke(Path(badge), with: .color(line), lineWidth: 0.2)
        drawQuietMark(context, at: CGPoint(x: badge.minX + 2.6, y: badge.midY), height: 1.9)
        text(context, Brand.noiseReduction, badge.minX + 5.0, badge.midY + 0.05, size: 1.75, anchor: .leading)

        text(context, "PHONES", 229.4, 177.4, size: 1.9)
    }

    private static func transportLegends(_ context: GraphicsContext) {
        let labelY: CGFloat = 159.6
        let symbolY: CGFloat = 163.8
        for key in TransportKey.allCases {
            let x = Layout.keyX[key.rawValue]
            text(context, key.title, x, labelY, size: 2.0)
            var symbol = Path()
            func triangle(_ origin: CGFloat, pointingRight: Bool) {
                let direction: CGFloat = pointingRight ? 1 : -1
                symbol.move(to: CGPoint(x: origin - direction * 0.9, y: symbolY - 1.05))
                symbol.addLine(to: CGPoint(x: origin + direction * 0.9, y: symbolY))
                symbol.addLine(to: CGPoint(x: origin - direction * 0.9, y: symbolY + 1.05))
                symbol.closeSubpath()
            }
            switch key {
            case .record:
                symbol.addEllipse(in: CGRect(x: x - 1.1, y: symbolY - 1.1, width: 2.2, height: 2.2))
            case .play:
                triangle(x, pointingRight: true)
            case .rewind:
                triangle(x - 0.9, pointingRight: false)
                triangle(x + 0.9, pointingRight: false)
            case .fastForward:
                triangle(x - 0.9, pointingRight: true)
                triangle(x + 0.9, pointingRight: true)
            case .stop:
                symbol.addRect(CGRect(x: x - 0.95, y: symbolY - 0.95, width: 1.9, height: 1.9))
            }
            context.fill(symbol, with: .color(key == .record ? Theme.recordRed : Theme.legend))
        }
    }

    private static func logo(_ context: GraphicsContext) {
        context.draw(
            Text(Brand.maker)
                .font(.custom("AvenirNext-HeavyItalic", size: 10.4))
                .foregroundStyle(Theme.brandOrange),
            at: CGPoint(x: 321.0, y: 143.3), anchor: .trailing)
        context.draw(
            Text(Brand.descriptor)
                .font(.custom("HelveticaNeue-Light", size: 4.5))
                .tracking(0.35)
                .foregroundStyle(Theme.legend),
            at: CGPoint(x: 320.8, y: 151.4), anchor: .trailing)
        context.draw(
            Text(Brand.model)
                .font(.custom("HelveticaNeue-UltraLight", size: 16.6))
                .tracking(-0.5)
                .foregroundStyle(Theme.legend),
            at: CGPoint(x: 322.6, y: 146.6), anchor: .leading)
    }
}

#Preview("Faceplate") {
    Canvas { context, _ in
        var scaled = context
        scaled.scaleBy(x: 3.4, y: 3.4)
        FaceplateArt.draw(scaled)
    }
    .frame(width: Layout.size.width * 3.4, height: Layout.size.height * 3.4)
    .padding(20)
    .background(Color(red: 0.42, green: 0.30, blue: 0.20))
}
