import SwiftUI

/// Who made this thing. We are not that other company; ours is named after
/// the Swedish word for hiss.
enum Brand {
    static let maker = "Brustex"
    static let model = "X-2026"
    static let descriptor = "MULTITRACKER"
    static let noiseReduction = "BRUSFRI NR"
    static let tagline = "Brus is Swedish for hiss. We put it back in."
}

extension EnvironmentValues {
    /// Points per millimetre. The whole machine is laid out in real
    /// millimetres and scaled to the window through this one number.
    @Entry var unit: CGFloat = 4
}

/// Colours and type lifted from a well-kept late-eighties portastudio.
enum Theme {
    // Plastics
    static let body = Color(red: 0.086, green: 0.086, blue: 0.090)
    static let bodyHighlight = Color(red: 0.155, green: 0.155, blue: 0.160)
    static let bodyShadow = Color(red: 0.035, green: 0.035, blue: 0.038)
    static let recess = Color(red: 0.040, green: 0.040, blue: 0.043)
    static let keyTop = Color(red: 0.120, green: 0.120, blue: 0.125)

    // Screen printing
    static let legend = Color(red: 0.86, green: 0.86, blue: 0.83)
    static let legendDim = Color(red: 0.62, green: 0.62, blue: 0.60)
    static let brandOrange = Color(red: 0.96, green: 0.42, blue: 0.13)
    static let recordRed = Color(red: 0.90, green: 0.22, blue: 0.14)

    // Knob caps
    static let knobYellow = Color(red: 0.85, green: 0.76, blue: 0.42)
    static let knobGreen = Color(red: 0.30, green: 0.48, blue: 0.37)
    static let knobGrey = Color(red: 0.52, green: 0.51, blue: 0.47)
    static let knobBlack = Color(red: 0.11, green: 0.11, blue: 0.115)
    static let faderGrey = Color(red: 0.70, green: 0.70, blue: 0.68)

    // Lights
    static let ledRed = Color(red: 1.00, green: 0.20, blue: 0.12)
    static let ledAmber = Color(red: 1.00, green: 0.66, blue: 0.10)
    static let ledGreen = Color(red: 0.35, green: 0.95, blue: 0.30)
    static let ledOff = Color(red: 0.13, green: 0.07, blue: 0.06)

    /// The condensed sans every Japanese panel of the era was printed in.
    static func legendFont(_ millimetres: CGFloat, unit: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: millimetres * unit, weight: weight).width(.condensed)
    }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
}

/// Easing curves for things with mass.
enum Ease {
    static func inOut(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    static func out(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return 1 - (1 - x) * (1 - x)
    }

    static func `in`(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x
    }

    /// Progress of `t` through the window `from...to`, clamped to 0...1.
    static func window(_ t: Double, _ from: Double, _ to: Double) -> Double {
        guard to > from else { return t >= to ? 1 : 0 }
        return min(1, max(0, (t - from) / (to - from)))
    }

    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
