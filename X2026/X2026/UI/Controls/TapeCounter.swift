import SwiftUI

/// A three-digit mechanical tape counter.
///
/// It is belt-driven from the take-up hub, so it counts hub revolutions, not
/// seconds: the numbers fly past at the start of a tape and crawl by the end.
/// The wheels carry like an odometer — the tens wheel only turns while the
/// units wheel is rolling from 9 to 0.
struct TapeCounterView: View {
    /// Continuous count; the fractional part shows as a wheel between digits.
    var value: Double

    @Environment(\.unit) private var unit

    /// Size of one digit window in millimetres.
    static let digit = CGSize(width: 4.3, height: 6.2)

    /// Position of each wheel (hundreds, tens, units) in digits, 0..<10.
    static func wheelPositions(for value: Double) -> [Double] {
        let wrapped = value.truncatingRemainder(dividingBy: 1000)
        let count = wrapped < 0 ? wrapped + 1000 : wrapped
        let units = count.truncatingRemainder(dividingBy: 10)
        let tensCarry = max(0, units - 9)
        let tens = (count / 10).rounded(.down).truncatingRemainder(dividingBy: 10) + tensCarry
        let hundredsCarry = max(0, count.truncatingRemainder(dividingBy: 100) - 99)
        let hundreds = (count / 100).rounded(.down).truncatingRemainder(dividingBy: 10) + hundredsCarry
        return [hundreds, tens, units]
    }

    var body: some View {
        let cell = CGSize(width: Self.digit.width * unit, height: Self.digit.height * unit)
        Canvas { context, size in
            let wheels = Self.wheelPositions(for: value)
            for (index, position) in wheels.enumerated() {
                let frame = CGRect(x: CGFloat(index) * cell.width, y: 0, width: cell.width, height: size.height)
                var wheel = context
                wheel.clip(to: Path(frame.insetBy(dx: unit * 0.18, dy: 0)))
                wheel.fill(Path(frame), with: .color(Color(white: 0.045)))

                let whole = position.rounded(.down)
                let fraction = position - whole
                for step in 0...1 {
                    let numeral = (Int(whole) + step) % 10
                    // The wheel face moves upwards as the count rises.
                    let y = frame.midY + (CGFloat(step) - fraction) * cell.height * 0.92
                    wheel.draw(
                        Text("\(numeral)")
                            .font(.custom("DINAlternate-Bold", size: cell.height * 0.82))
                            .foregroundStyle(Color(white: 0.93)),
                        at: CGPoint(x: frame.midX, y: y + cell.height * 0.03), anchor: .center)
                }
            }
            // Curvature of the drums: dark at top and bottom, a soft glint above centre.
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .black.opacity(0.92), location: 0),
                        .init(color: .black.opacity(0.0), location: 0.30),
                        .init(color: .white.opacity(0.07), location: 0.42),
                        .init(color: .black.opacity(0.0), location: 0.62),
                        .init(color: .black.opacity(0.92), location: 1),
                    ]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        .frame(width: cell.width * 3, height: cell.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: unit * 0.5))
        .overlay(
            RoundedRectangle(cornerRadius: unit * 0.5)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: max(0.5, unit * 0.12))
        )
        .accessibilityElement()
        .accessibilityLabel("Tape counter")
        .accessibilityValue(String(format: "%03d", Int(value.rounded(.down)) % 1000))
    }
}

/// The little button that zeroes the counter.
struct CounterResetButton: View {
    var action: () -> Void

    @Environment(\.unit) private var unit
    @State private var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: unit * 0.5)
            .fill(
                LinearGradient(
                    colors: [Color(white: pressed ? 0.07 : 0.17), Color(white: pressed ? 0.05 : 0.09)],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: unit * 0.5)
                    .strokeBorder(.black.opacity(0.8), lineWidth: max(0.5, unit * 0.12))
            )
            .frame(width: unit * 4.6, height: unit * 5.2)
            .offset(y: pressed ? unit * 0.25 : 0)
            .shadow(color: .black.opacity(pressed ? 0.2 : 0.7), radius: unit * 0.4, y: unit * (pressed ? 0.1 : 0.5))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            action()
                        }
                    }
                    .onEnded { _ in pressed = false }
            )
            .accessibilityElement()
            .accessibilityLabel("Reset tape counter")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .help("Reset counter to 000")
    }
}

#Preview("Counter") {
    VStack(spacing: 18) {
        ForEach([0.0, 9.6, 99.5, 123.45, 399.92, 999.97], id: \.self) { value in
            HStack(spacing: 8) {
                TapeCounterView(value: value)
                CounterResetButton {}
                Text(String(format: "%.2f", value)).foregroundStyle(.white).font(.caption)
            }
        }
    }
    .padding(30)
    .background(Theme.body)
    .environment(\.unit, 8)
}
