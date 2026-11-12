import SwiftUI

/// A rotary pot. Drag up and down to turn it; hold Shift for a fine touch;
/// double-click to put it back where it came from the factory.
struct Knob: View {
    @Binding var value: Double
    var cap: Color
    /// Cap diameter in millimetres.
    var diameter: CGFloat = 8.5
    /// A position the knob clicks into, like the centre of a pan pot.
    var detent: Double? = nil
    var resetValue: Double = 0
    var label: String

    @Environment(\.unit) private var unit
    @State private var dragOrigin: Double?
    @State private var hovering = false

    /// Pots sweep 300°, from seven o'clock round to five.
    private static let sweep = 300.0

    private var angle: Angle { .degrees(-Self.sweep / 2 + Self.sweep * value) }

    private var pointerColor: Color {
        cap == Theme.knobBlack ? Theme.legend : Color(white: 0.06)
    }

    var body: some View {
        let d = diameter * unit
        ZStack {
            // Shadow thrown on the panel.
            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: d * 1.16, height: d * 1.16)
                .offset(x: d * 0.05, y: d * 0.13)
                .blur(radius: d * 0.07)

            // Knurled skirt.
            Circle()
                .fill(
                    AngularGradient(
                        stops: Self.knurling,
                        center: .center
                    )
                )
                .frame(width: d * 1.14, height: d * 1.14)
                .rotationEffect(angle)

            // Coloured cap, lit from the upper left.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [cap.mix(with: .white, by: 0.28), cap, cap.mix(with: .black, by: 0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: max(0.5, d * 0.02)))
                .frame(width: d * 0.90, height: d * 0.90)

            // Pointer line.
            Capsule()
                .fill(pointerColor)
                .frame(width: max(1, d * 0.075), height: d * 0.40)
                .offset(y: -d * 0.25)
                .rotationEffect(angle)
        }
        .frame(width: d * 1.2, height: d * 1.2)
        .contentShape(Circle())
        .brightness(hovering ? 0.04 : 0)
        .onHover { hovering = $0 }
        .gesture(turning)
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

    private var turning: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { drag in
                let origin = dragOrigin ?? value
                dragOrigin = origin
                let fine = NSEvent.modifierFlags.contains(.shift)
                let travel = (-drag.translation.height + drag.translation.width * 0.35) / (fine ? 900 : 190)
                var turned = min(1, max(0, origin + travel))
                if let detent, abs(turned - detent) < 0.025 { turned = detent }
                value = turned
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// Alternating light and dark slivers that read as a ribbed edge.
    private static let knurling: [Gradient.Stop] = {
        let ribs = 28
        var stops: [Gradient.Stop] = []
        for rib in 0..<ribs {
            let start = Double(rib) / Double(ribs)
            let middle = (Double(rib) + 0.5) / Double(ribs)
            stops.append(.init(color: Color(white: 0.17), location: start))
            stops.append(.init(color: Color(white: 0.05), location: middle))
        }
        stops.append(.init(color: Color(white: 0.17), location: 1))
        return stops
    }()
}

#Preview("Knobs") {
    @Previewable @State var a = 0.5
    @Previewable @State var b = 0.2
    @Previewable @State var c = 0.8
    @Previewable @State var d = 0.5
    HStack(spacing: 20) {
        Knob(value: $a, cap: Theme.knobYellow, detent: 0.5, resetValue: 0.5, label: "Aux")
        Knob(value: $b, cap: Theme.knobGreen, detent: 0.5, resetValue: 0.5, label: "Pan")
        Knob(value: $c, cap: Theme.knobGrey, label: "Gain")
        Knob(value: $d, cap: Theme.knobBlack, diameter: 7.5, label: "Monitor")
    }
    .padding(40)
    .background(Theme.body)
    .environment(\.unit, 6)
}
