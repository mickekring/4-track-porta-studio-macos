import Foundation

/// A single-band sliding compander in the spirit of the B-type noise reduction
/// that cassette multitrackers carried.
///
/// Encoding lifts quiet treble by up to 10 dB before it reaches the tape;
/// decoding pulls it back down on playback, taking the tape hiss with it.
/// Encoder and decoder share one side chain, and the decoder solves the
/// encoder's equation backwards, so a clean round trip is transparent. Put a
/// tape in between — hiss, saturation, treble loss — and it mistracks the way
/// the real thing did. Record with it on and play back with it off for that
/// crisp, squashed top end everybody used on vocals.
nonisolated struct NoiseReduction: Sendable {
    /// Largest treble lift, as a side-chain gain: 1 + 2.16 ≈ +10 dB.
    private static let maximumGain: Float = 2.16
    /// Side-chain level where the lift has fallen by half.
    private static let threshold: Float = Level.reference * 0.03

    private var highpassCoefficient: Float = 0.8
    private var attack: Float = 0.02
    private var release: Float = 0.0005

    private var previousInput: Float = 0
    private var previousHighpass: Float = 0
    private var envelope: Float = 0
    private var gain: Float = NoiseReduction.maximumGain

    init() {}

    init(sampleRate: Double) {
        configure(sampleRate: sampleRate)
    }

    mutating func configure(sampleRate: Double) {
        highpassCoefficient = Float(1 / (1 + 2 * .pi * 1500 / sampleRate))
        attack = Float(1 - exp(-1 / (0.0015 * sampleRate)))
        release = Float(1 - exp(-1 / (0.045 * sampleRate)))
    }

    mutating func reset() {
        previousInput = 0
        previousHighpass = 0
        envelope = 0
        gain = Self.maximumGain
    }

    /// Shared tail of both directions: advance the side chain given the
    /// *unprocessed* sample and the treble component derived from it.
    @inline(__always)
    private mutating func advance(plain: Float, highpass: Float) {
        previousInput = plain
        previousHighpass = highpass
        let level = abs(gain * highpass)
        envelope += (level > envelope ? attack : release) * (level - envelope)
        let ratio = envelope / Self.threshold
        gain = Self.maximumGain / (1 + ratio * ratio)
    }

    /// Plain audio in, tape-ready audio out.
    @inline(__always)
    mutating func encode(_ x: Float) -> Float {
        let history = highpassCoefficient * (previousHighpass - previousInput)
        let highpass = highpassCoefficient * x + history
        let y = x + gain * highpass
        advance(plain: x, highpass: highpass)
        return y
    }

    /// Tape audio in, plain audio out.
    @inline(__always)
    mutating func decode(_ y: Float) -> Float {
        let history = highpassCoefficient * (previousHighpass - previousInput)
        let x = (y - gain * history) / (1 + gain * highpassCoefficient)
        let highpass = highpassCoefficient * x + history
        advance(plain: x, highpass: highpass)
        return x
    }
}
