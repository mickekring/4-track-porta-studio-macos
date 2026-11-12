import Foundation

/// Everything one track goes through on its way onto and back off the tape:
/// noise-reduction encode, record saturation (treble gives up first), then on
/// the way back head response, hiss, level wobble and noise-reduction decode.
nonisolated struct TapeChannel: Sendable {
    // MARK: Record side

    private var encoder = NoiseReduction()
    private var preEmphasis = Biquad()
    private var deEmphasis = Biquad()
    private var subsonic = DCBlocker()

    /// Oxide runs out of headroom about 8 dB above the reference level.
    private static let ceiling: Float = 0.83

    // MARK: Playback side

    private var decoder = NoiseReduction()
    private var headBump = Biquad()
    private var gapLoss = Biquad()
    private var gapLossTail = OnePole()
    private var hissSource: NoiseSource
    private var hissTilt = OnePole()
    private var hissGain: Float = 0
    private var wobbleSource: NoiseSource
    private var wobble = OnePole()
    private var wobbleScale: Float = 0

    /// How far the playback level wanders (about ±0.25 dB), as tape-to-head
    /// contact is never perfectly steady.
    private static let wobbleDepth: Float = 0.03

    /// Signal-to-hiss ratio of the bare tape, before noise reduction helps.
    static let signalToNoiseDB: Float = 52

    init(seed: UInt32) {
        hissSource = NoiseSource(seed: seed &* 2_654_435_761 &+ 17)
        wobbleSource = NoiseSource(seed: seed &* 40_503 &+ 911)
    }

    mutating func configure(sampleRate: Double) {
        encoder.configure(sampleRate: sampleRate)
        decoder.configure(sampleRate: sampleRate)

        // Treble is driven harder into the oxide and saturates first.
        preEmphasis.setHighShelf(frequency: 4200, gainDB: 9, slope: 0.7, sampleRate: sampleRate)
        deEmphasis.setHighShelf(frequency: 4200, gainDB: -9, slope: 0.7, sampleRate: sampleRate)
        subsonic.setCutoff(18, sampleRate: sampleRate)

        // 40 Hz – 12.5 kHz, with the little low-end bump every tape head has.
        headBump.setHighpass(frequency: 36, q: 0.95, sampleRate: sampleRate)
        gapLoss.setLowpass(frequency: 14_500, q: 0.62, sampleRate: sampleRate)
        gapLossTail.setCutoff(17_000, sampleRate: sampleRate)

        hissTilt.setCutoff(2300, sampleRate: sampleRate)
        wobble.setCutoff(2.5, sampleRate: sampleRate)
        // Scale so the lowpassed noise has unit variance whatever the sample rate.
        wobbleScale = Self.wobbleDepth / (0.5774 * (wobble.coefficient / 2).squareRoot())
        calibrateHiss()
    }

    mutating func reset() {
        encoder.reset()
        decoder.reset()
        preEmphasis.reset()
        deEmphasis.reset()
        headBump.reset()
        gapLoss.reset()
    }

    /// Hiss is flat up to the playback-equalisation corner and climbs above it.
    @inline(__always)
    private mutating func rawHiss() -> Float {
        let white = hissSource.next()
        let low = hissTilt.process(white)
        return white + 2.2 * (white - low)
    }

    private mutating func calibrateHiss() {
        var probe = self
        var energy: Float = 0
        let count = 16_384
        for _ in 0..<count {
            let sample = probe.rawHiss()
            energy += sample * sample
        }
        let rms = (energy / Float(count)).squareRoot()
        let target = Level.reference * 0.7071 * Level.gain(dB: -Self.signalToNoiseDB)
        hissGain = rms > 0 ? target / rms : 0
    }

    // MARK: - Per-sample processing

    /// Mixer bus in, magnetisation out.
    @inline(__always)
    mutating func record(_ input: Float, noiseReduction: Bool) -> Float {
        var x = subsonic.process(input)
        if noiseReduction { x = encoder.encode(x) }
        x = preEmphasis.process(x)
        x = Self.ceiling * Saturation.soft(x / Self.ceiling)
        return deEmphasis.process(x)
    }

    /// Magnetisation in, line-level audio out. `contact` is 0 with the head
    /// lifted off the tape and 1 when it is pressed against it.
    @inline(__always)
    mutating func play(_ magnetisation: Float, contact: Float, noiseReduction: Bool) -> Float {
        let drift = 1 + wobble.process(wobbleSource.next() * wobbleScale)
        var x = magnetisation * drift + rawHiss() * hissGain
        x = headBump.process(x * contact)
        x = gapLossTail.process(gapLoss.process(x))
        if noiseReduction { x = decoder.decode(x) }
        return x
    }
}
