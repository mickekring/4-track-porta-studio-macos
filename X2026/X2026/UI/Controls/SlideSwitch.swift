import SwiftUI

/// A slide switch with two or three click-stops.
/// Position 0 is the top (or the left, for a horizontal switch).
struct SlideSwitch: View {
    enum Style {
        /// The chunky ribbed switches in the master section.
        case large
        /// The little toggles for MIC/LINE and TAPE/MIXER.
        case small
    }

    @Binding var position: Int
    var positions: Int
    var axis: Axis = .vertical
    var style: Style = .large
    var stripe: Color = Theme.legend
    var label: String
    var names: [String] = []

    @Environment(\.unit) private var unit
    @State private var pressedAt: Int?

    /// Cap size across and along the direction of travel, in millimetres.
    private var capSize: (across: CGFloat, along: CGFloat) {
        style == .large ? (11, 11.5) : (3.6, 4.2)
    }

    /// Millimetres between click-stops.
    private var pitch: CGFloat { style == .large ? 4.2 : 2.6 }

    private var length: CGFloat { capSize.along + pitch * CGFloat(positions - 1) }

    var body: some View {
        let across = capSize.across * unit
        let along = length * unit
        let offset = pitch * unit * CGFloat(position)
        let vertical = axis == .vertical

        ZStack(alignment: vertical ? .top : .leading) {
            RoundedRectangle(cornerRadius: unit * (style == .large ? 0.9 : 0.5))
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: unit * (style == .large ? 0.9 : 0.5))
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: max(0.5, unit * 0.12))
                )

            cap
                .frame(
                    width: vertical ? across : capSize.along * unit,
                    height: vertical ? capSize.along * unit : across
                )
                .offset(x: vertical ? 0 : offset, y: vertical ? offset : 0)
                .animation(.snappy(duration: 0.09), value: position)
        }
        .frame(width: vertical ? across : along, height: vertical ? along : across)
        .contentShape(Rectangle())
        .gesture(throwing(pitch: pitch * unit, capAlong: capSize.along * unit))
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(names.indices.contains(position) ? names[position] : "\(position + 1)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: position = max(0, position - 1)
            case .decrement: position = min(positions - 1, position + 1)
            @unknown default: break
            }
        }
        .help(names.indices.contains(position) ? "\(label): \(names[position])" : label)
    }

    private var cap: some View {
        let large = style == .large
        let base = large ? Color(white: 0.175) : Color(white: 0.62)
        let vertical = axis == .vertical
        return ZStack {
            RoundedRectangle(cornerRadius: unit * (large ? 0.8 : 0.4))
                .fill(
                    LinearGradient(
                        colors: [base.mix(with: .white, by: 0.14), base, base.mix(with: .black, by: 0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: unit * (large ? 0.8 : 0.4))
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(large ? 0.22 : 0.3), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom),
                            lineWidth: max(0.5, unit * 0.16))
                )
                .shadow(color: .black.opacity(0.8), radius: unit * 0.5, y: unit * 0.5)

            if large {
                // Thumb ribs running across the cap, and the painted stripe.
                Canvas { context, canvas in
                    let ribs = 9
                    for rib in 0..<ribs {
                        let t = (CGFloat(rib) + 0.5) / CGFloat(ribs)
                        var groove = Path()
                        if vertical {
                            groove.move(to: CGPoint(x: canvas.width * 0.08, y: canvas.height * t))
                            groove.addLine(to: CGPoint(x: canvas.width * 0.92, y: canvas.height * t))
                        } else {
                            groove.move(to: CGPoint(x: canvas.width * t, y: canvas.height * 0.08))
                            groove.addLine(to: CGPoint(x: canvas.width * t, y: canvas.height * 0.92))
                        }
                        context.stroke(groove, with: .color(.black.opacity(0.65)), lineWidth: max(0.5, unit * 0.22))
                    }
                }
                RoundedRectangle(cornerRadius: unit * 0.2)
                    .fill(stripe)
                    .frame(
                        width: vertical ? capSize.across * unit * 0.46 : unit * 1.35,
                        height: vertical ? unit * 1.35 : capSize.across * unit * 0.46
                    )
            }
        }
    }

    private func throwing(pitch: CGFloat, capAlong: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in
                if pressedAt == nil { pressedAt = position }
                let moved = axis == .vertical ? drag.translation.height : drag.translation.width
                guard abs(moved) > 2 else { return }
                let along = axis == .vertical ? drag.location.y : drag.location.x
                let nearest = Int(((along - capAlong / 2) / pitch).rounded())
                let clamped = min(positions - 1, max(0, nearest))
                if clamped != position { position = clamped }
            }
            .onEnded { drag in
                defer { pressedAt = nil }
                let moved = axis == .vertical ? drag.translation.height : drag.translation.width
                guard abs(moved) <= 2 else { return }
                // A plain click nudges the switch one stop towards the pointer,
                // or simply flips a two-way switch.
                let along = axis == .vertical ? drag.location.y : drag.location.x
                let nearest = min(positions - 1, max(0, Int(((along - capAlong / 2) / pitch).rounded())))
                if nearest != position {
                    position += nearest > position ? 1 : -1
                } else if positions == 2 {
                    position = 1 - position
                }
            }
    }
}

#Preview("Switches") {
    @Previewable @State var a = 0
    @Previewable @State var b = 1
    @Previewable @State var c = 0
    @Previewable @State var d = 1
    HStack(spacing: 30) {
        SlideSwitch(position: $a, positions: 2, label: "Noise reduction", names: ["On", "Off"])
        SlideSwitch(position: $b, positions: 3, stripe: Theme.recordRed, label: "Record track", names: ["1", "Safe", "3"])
        SlideSwitch(position: $c, positions: 2, style: .small, label: "Gain", names: ["Mic", "Line"])
        SlideSwitch(position: $d, positions: 2, axis: .horizontal, style: .small, label: "Meters", names: ["Tape", "Mixer"])
    }
    .padding(40)
    .background(Theme.body)
    .environment(\.unit, 6)
}
