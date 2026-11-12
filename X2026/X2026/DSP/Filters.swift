import Foundation

// Small, allocation-free building blocks for the audio thread.
// Everything here is a plain value type with `mutating` per-sample methods.

/// Second-order IIR section (transposed direct form II), with the usual
/// "Audio EQ Cookbook" coefficient recipes.
nonisolated struct Biquad: Sendable {
    private(set) var b0: Float = 1
    private(set) var b1: Float = 0
    private(set) var b2: Float = 0
    private(set) var a1: Float = 0
    private(set) var a2: Float = 0
    private var z1: Float = 0
    private var z2: Float = 0

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    private mutating func set(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.b0 = Float(b0 / a0)
        self.b1 = Float(b1 / a0)
        self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0)
        self.a2 = Float(a2 / a0)
    }

    private static func omega(_ frequency: Double, _ sampleRate: Double) -> Double {
        2 * .pi * min(frequency, sampleRate * 0.49) / sampleRate
    }

    mutating func setLowpass(frequency: Double, q: Double = 0.7071, sampleRate: Double) {
        let w = Self.omega(frequency, sampleRate)
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    mutating func setHighpass(frequency: Double, q: Double = 0.7071, sampleRate: Double) {
        let w = Self.omega(frequency, sampleRate)
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    mutating func setPeak(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) {
        let w = Self.omega(frequency, sampleRate)
        let a = pow(10, gainDB / 40)
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        set(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
    }

    /// Shelving filters with slope `s` (1 = steepest without overshoot).
    /// A shelf of `-gainDB` is the exact inverse of one of `+gainDB`.
    mutating func setLowShelf(frequency: Double, gainDB: Double, slope s: Double = 1, sampleRate: Double) {
        let w = Self.omega(frequency, sampleRate)
        let a = pow(10, gainDB / 40)
        let c = cos(w)
        let alpha = sin(w) / 2 * ((a + 1 / a) * (1 / s - 1) + 2).squareRoot()
        let k = 2 * a.squareRoot() * alpha
        set(a * ((a + 1) - (a - 1) * c + k),
            2 * a * ((a - 1) - (a + 1) * c),
            a * ((a + 1) - (a - 1) * c - k),
            (a + 1) + (a - 1) * c + k,
            -2 * ((a - 1) + (a + 1) * c),
            (a + 1) + (a - 1) * c - k)
    }

    mutating func setHighShelf(frequency: Double, gainDB: Double, slope s: Double = 1, sampleRate: Double) {
        let w = Self.omega(frequency, sampleRate)
        let a = pow(10, gainDB / 40)
        let c = cos(w)
        let alpha = sin(w) / 2 * ((a + 1 / a) * (1 / s - 1) + 2).squareRoot()
        let k = 2 * a.squareRoot() * alpha
        set(a * ((a + 1) + (a - 1) * c + k),
            -2 * a * ((a - 1) + (a + 1) * c),
            a * ((a + 1) + (a - 1) * c - k),
            (a + 1) - (a - 1) * c + k,
            2 * ((a - 1) - (a + 1) * c),
            (a + 1) - (a - 1) * c - k)
    }
}

/// One-pole lowpass, used for smoothing control values and for gentle tone shaping.
nonisolated struct OnePole: Sendable {
    private(set) var coefficient: Float = 1
    var value: Float = 0

    init() {}

    init(timeConstant: Double, sampleRate: Double, initial: Float = 0) {
        setTimeConstant(timeConstant, sampleRate: sampleRate)
        value = initial
    }

    mutating func setTimeConstant(_ seconds: Double, sampleRate: Double) {
        coefficient = seconds <= 0 ? 1 : Float(1 - exp(-1 / (seconds * sampleRate)))
    }

    mutating func setCutoff(_ frequency: Double, sampleRate: Double) {
        coefficient = Float(1 - exp(-2 * .pi * frequency / sampleRate))
    }

    @inline(__always)
    mutating func process(_ target: Float) -> Float {
        value += coefficient * (target - value)
        return value
    }
}

/// First-order highpass that blocks DC and subsonics.
nonisolated struct DCBlocker: Sendable {
    private var r: Float = 0.999
    private var x1: Float = 0
    private var y1: Float = 0

    mutating func setCutoff(_ frequency: Double, sampleRate: Double) {
        r = Float(exp(-2 * .pi * frequency / sampleRate))
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = x - x1 + r * y1
        x1 = x
        y1 = y
        return y
    }
}

/// Tiny, fast pseudo-random generator for hiss, flutter and dropouts.
nonisolated struct NoiseSource: Sendable {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed == 0 ? 0x9E37_79B9 : seed
    }

    @inline(__always)
    mutating func nextBits() -> UInt32 {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return state
    }

    /// Uniform white noise in -1...1.
    @inline(__always)
    mutating func next() -> Float {
        Float(Int32(bitPattern: nextBits())) * (1.0 / 2_147_483_648.0)
    }
}

nonisolated enum Level {
    @inline(__always)
    static func gain(dB: Float) -> Float { powf(10, dB / 20) }

    @inline(__always)
    static func decibels(_ amplitude: Float) -> Float { 20 * log10f(max(amplitude, 1e-9)) }

    /// Amplitude of a sine that reads 0 on the meters. Tape, meters and the
    /// noise reduction are all lined up to this, like Dolby level on a real deck.
    static let reference: Float = 0.25
}

/// Cheap, smooth saturation curves.
nonisolated enum Saturation {
    /// Close cousin of tanh that costs one division. Monotonic, limits at ±1.
    @inline(__always)
    static func soft(_ x: Float) -> Float {
        let clamped = max(-3, min(3, x))
        let squared = clamped * clamped
        return clamped * (27 + squared) / (27 + 9 * squared)
    }
}
