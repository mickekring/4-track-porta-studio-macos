import SwiftUI

/// A straight-line fader riding in a slot.
struct Fader: View {
    enum Cap {
        /// Tall grey cap with a red index line, as on the two input channels.
        case channel
        /// Black cap with a white line, as on the master.
        case master
        /// Stubby black cap for the short equaliser sliders.
        case equaliser

        var size: CGSize {
            switch self {
            case .channel: CGSize(width: 9.5, height: 13)
            case .master: CGSize(width: 9.5, height: 11)
            case .equaliser: CGSize(width: 8.5, height: 7)
            }
        }

        var colour: Color {
            switch self {
            case .channel: Theme.faderGrey
            case .master, .equaliser: Color(white: 0.13)
            }
        }

        var line: Color {
            switch self {
            case .channel: Theme.recordRed
            case .master, .equaliser: Theme.legend
            }
        }
    }

    @Binding var value: Double
    var cap: Cap
    /// Distance the cap can move, in millimetres.
    var travel: CGFloat
    var detent: Double? = nil
    var resetValue: Double = 0
    var label: String

    @Environment(\.unit) private var unit
    @State private var dragOrigin: Double?

    var body: some View {
        let capSize = CGSize(width: cap.size.width * unit, height: cap.size.height * unit)
        let run = travel * unit
        let capTop = (1 - value) * run

        ZStack(alignment: .top) {
            // The slot the stem rides in.
            RoundedRectangle(cornerRadius: unit * 0.6)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: unit * 0.6)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: max(0.5, unit * 0.12))
                )
                .frame(width: unit * 2.0, height: run + capSize.height * 0.5)
                .offset(y: capSize.height * 0.25)

            capView(size: capSize)
                .offset(y: capTop)
        }
        .frame(width: capSize.width, height: run + capSize.height, alignment: .top)
        .contentShape(Rectangle())
        .gesture(sliding(run: run, capHeight: capSize.height))
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = resetValue })
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
        .help(label)
    }

    private func capView(size: CGSize) -> some View {
        let ridges = cap == .equaliser ? 4 : 8
        return ZStack {
            RoundedRectangle(cornerRadius: unit * 0.5)
                .fill(.black.opacity(0.6))
                .offset(x: unit * 0.3, y: unit * 0.9)
                .blur(radius: unit * 0.5)

            RoundedRectangle(cornerRadius: unit * 0.5)
                .fill(
                    LinearGradient(
                        colors: [
                            cap.colour.mix(with: .white, by: 0.22),
                            cap.colour,
                            cap.colour.mix(with: .black, by: 0.30),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: unit * 0.5)
                        .strokeBorder(.black.opacity(0.5), lineWidth: max(0.5, unit * 0.1))
                )

            // Finger ridges, in two banks either side of the index line.
            Canvas { context, canvas in
                let inset = canvas.width * 0.12
                let gap = canvas.height / CGFloat(ridges + 3)
                for ridge in 0..<ridges {
                    let side = ridge < ridges / 2 ? 0 : 2
                    let y = gap * CGFloat(ridge + 1 + side)
                    var groove = Path()
                    groove.move(to: CGPoint(x: inset, y: y))
                    groove.addLine(to: CGPoint(x: canvas.width - inset, y: y))
                    context.stroke(groove, with: .color(.black.opacity(0.42)), lineWidth: max(0.5, unit * 0.16))
                    context.stroke(
                        groove.offsetBy(dx: 0, dy: max(0.5, unit * 0.16)),
                        with: .color(.white.opacity(0.10)),
                        lineWidth: max(0.5, unit * 0.1)
                    )
                }
            }

            Rectangle()
                .fill(cap.line)
                .frame(height: max(1, unit * 0.45))
        }
        .frame(width: size.width, height: size.height)
    }

    private func sliding(run: CGFloat, capHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in
                if dragOrigin == nil {
                    let capTop = (1 - value) * run
                    let grabbed = (capTop...(capTop + capHeight)).contains(drag.startLocation.y)
                    // Clicking the slot away from the cap brings the cap to the finger.
                    dragOrigin = grabbed ? value : 1 - (drag.startLocation.y - capHeight / 2) / run
                }
                var moved = min(1, max(0, (dragOrigin ?? value) - drag.translation.height / run))
                if let detent, abs(moved - detent) < 0.02 { moved = detent }
                value = moved
            }
            .onEnded { _ in dragOrigin = nil }
    }
}

#Preview("Faders") {
    @Previewable @State var a = 0.7
    @Previewable @State var b = 0.5
    @Previewable @State var c = 0.8
    HStack(spacing: 30) {
        Fader(value: $a, cap: .channel, travel: 60, label: "Channel 1")
        Fader(value: $b, cap: .equaliser, travel: 22, detent: 0.5, resetValue: 0.5, label: "EQ")
        Fader(value: $c, cap: .master, travel: 60, label: "Master")
    }
    .padding(40)
    .background(Theme.body)
    .environment(\.unit, 5)
}
