import Foundation
import Synchronization

/// A preset rhythm box of the kind every bedroom studio had next to the
/// four-track: a handful of patterns, a tempo knob, and analogue-ish drums.
/// It is the "drum machine to track 1" from page 12 of the manual.
///
/// Lives on the audio thread; its front panel talks to it through a mailbox.
nonisolated final class RhythmBox: @unchecked Sendable {
    struct Settings: Sendable, Equatable, Codable {
        var running = false
        /// Beats per minute.
        var tempo = 112.0
        var pattern = 0
        /// Output level, 0…1.
        var volume = 0.7
    }

    struct Pattern: Sendable {
        var name: String
        var kick: UInt16
        var snare: UInt16
        var hat: UInt16
        var openHat: UInt16
        var bell: UInt16
        var shuffle = false
    }

    /// Sixteen steps, most significant bit first, so the patterns read left to right.
    static let patterns: [Pattern] = [
        Pattern(name: "ROCK 1", kick: 0b1000_0000_1010_0000, snare: 0b0000_1000_0000_1000, hat: 0b1010_1010_1010_1010, openHat: 0, bell: 0),
        Pattern(name: "ROCK 2", kick: 0b1000_0010_1000_0100, snare: 0b0000_1000_0000_1000, hat: 0b1111_1111_1111_1101, openHat: 0b0000_0000_0000_0010, bell: 0),
        Pattern(name: "DISCO", kick: 0b1000_1000_1000_1000, snare: 0b0000_1000_0000_1000, hat: 0b0000_0000_0000_0000, openHat: 0b0010_0010_0010_0010, bell: 0),
        Pattern(name: "POP", kick: 0b1000_0001_0010_0000, snare: 0b0000_1000_0000_1000, hat: 0b1010_1010_1010_1010, openHat: 0, bell: 0b0000_0000_0000_0010),
        Pattern(name: "BALLAD", kick: 0b1000_0000_0010_0000, snare: 0b0000_0000_1000_0000, hat: 0b1000_1000_1000_1000, openHat: 0, bell: 0),
        Pattern(name: "SHUFFLE", kick: 0b1000_0010_1000_0010, snare: 0b0000_1000_0000_1000, hat: 0b1010_1010_1010_1010, openHat: 0, bell: 0, shuffle: true),
        Pattern(name: "BOSSA", kick: 0b1001_0010_1001_0010, snare: 0, hat: 0b1010_1010_1010_1010, openHat: 0, bell: 0b1001_0010_0010_0100),
        Pattern(name: "MARCH", kick: 0b1000_1000_1000_1000, snare: 0b1011_1010_1011_1011, hat: 0, openHat: 0, bell: 0),
    ]

    let settings = Mailbox(Settings())
    /// Step last played (0…15), for the blinking lamp.
    let step = Atomic<Int>(0)

    private var current = Settings()
    private var sampleRate = 48_000.0
    private var untilNextStep = 0.0
    private var position = 15
    private var wasRunning = false
    private var noise = NoiseSource(seed: 0xD2_0B_0C5)

    // Kick
    private var kickPhase: Float = 0
    private var kickLevel: Float = 0
    private var kickSweep: Float = 0
    // Snare
    private var snarePhase: Float = 0
    private var snareTone: Float = 0
    private var snareNoise: Float = 0
    private var snareFilter = Biquad()
    // Hats
    private var hatLevel: Float = 0
    private var hatDecay: Float = 0.99
    private var hatFilter = Biquad()
    private var hatMetal: (Float, Float, Float) = (0, 0, 0)
    // Bell
    private var bellLevel: Float = 0
    private var bellPhase: (Float, Float) = (0, 0)
    private var bellFilter = Biquad()

    private var kickDecay: Float = 0.999
    private var sweepDecay: Float = 0.99
    private var snareToneDecay: Float = 0.99
    private var snareNoiseDecay: Float = 0.99
    private var closedDecay: Float = 0.99
    private var openDecay: Float = 0.999
    private var bellDecay: Float = 0.99
    private var gain = Ramp()

    /// Call while no audio is flowing.
    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        func decay(_ milliseconds: Double) -> Float { Float(exp(-1 / (milliseconds * 0.001 * sampleRate))) }
        kickDecay = decay(150)
        sweepDecay = decay(22)
        snareToneDecay = decay(55)
        snareNoiseDecay = decay(85)
        closedDecay = decay(22)
        openDecay = decay(170)
        bellDecay = decay(95)
        snareFilter.setHighpass(frequency: 1400, q: 0.8, sampleRate: sampleRate)
        hatFilter.setHighpass(frequency: 7200, q: 1.1, sampleRate: sampleRate)
        bellFilter.setPeak(frequency: 2600, q: 2.5, gainDB: 9, sampleRate: sampleRate)
    }

    private func strike(_ pattern: Pattern, step: Int) {
        let bit: UInt16 = 0x8000 >> UInt16(step)
        if pattern.kick & bit != 0 {
            kickLevel = 1
            kickSweep = 1
            kickPhase = 0
        }
        if pattern.snare & bit != 0 {
            snareTone = 0.55
            snareNoise = 0.8
        }
        if pattern.hat & bit != 0 {
            hatLevel = 0.42
            hatDecay = closedDecay
        }
        if pattern.openHat & bit != 0 {
            hatLevel = 0.45
            hatDecay = openDecay
        }
        if pattern.bell & bit != 0 {
            bellLevel = 0.5
        }
    }

    /// Audio thread: `frames` of mono line-level output.
    func render(into output: UnsafeMutablePointer<Float>, frames: Int) {
        if let fresh = settings.read() { current = fresh }
        let pattern = Self.patterns[min(Self.patterns.count - 1, max(0, current.pattern))]
        let stepLength = sampleRate * 60 / max(40, min(240, current.tempo)) / 4
        gain.aim(Float(current.volume * current.volume) * 0.55, frames: frames)

        if current.running && !wasRunning {
            position = 15
            untilNextStep = 0
        }
        wasRunning = current.running

        let twoPi = 2 * Float.pi
        let rate = Float(sampleRate)
        for frame in 0..<frames {
            if current.running {
                untilNextStep -= 1
                if untilNextStep <= 0 {
                    position = (position + 1) & 15
                    strike(pattern, step: position)
                    step.store(position, ordering: .relaxed)
                    // Shuffle leans every other sixteenth back into a triplet feel.
                    let swing = pattern.shuffle ? (position & 1 == 0 ? 1.33 : 0.67) : 1.0
                    untilNextStep += stepLength * swing
                }
            }

            var sample: Float = 0

            if kickLevel > 0.0005 {
                kickPhase += twoPi * (46 + 125 * kickSweep) / rate
                if kickPhase > twoPi { kickPhase -= twoPi }
                sample += sinf(kickPhase) * kickLevel + kickSweep * kickSweep * 0.25 * noise.next()
                kickLevel *= kickDecay
                kickSweep *= sweepDecay
            }

            if snareNoise > 0.0005 {
                snarePhase += twoPi * 188 / rate
                if snarePhase > twoPi { snarePhase -= twoPi }
                sample += sinf(snarePhase) * snareTone + snareFilter.process(noise.next()) * snareNoise * 0.5
                snareTone *= snareToneDecay
                snareNoise *= snareNoiseDecay
            }

            if hatLevel > 0.0005 {
                // Six-oscillator metal reduced to three squares and some noise.
                hatMetal.0 += 5400 / rate
                hatMetal.1 += 7230 / rate
                hatMetal.2 += 8615 / rate
                if hatMetal.0 > 1 { hatMetal.0 -= 1 }
                if hatMetal.1 > 1 { hatMetal.1 -= 1 }
                if hatMetal.2 > 1 { hatMetal.2 -= 1 }
                let metal = (hatMetal.0 < 0.5 ? 1 : -1) + (hatMetal.1 < 0.5 ? 1 : -1) + (hatMetal.2 < 0.5 ? 1 : -1) as Float
                sample += hatFilter.process(metal * 0.22 + noise.next() * 0.6) * hatLevel
                hatLevel *= hatDecay
            }

            if bellLevel > 0.0005 {
                bellPhase.0 += 540 / rate
                bellPhase.1 += 800 / rate
                if bellPhase.0 > 1 { bellPhase.0 -= 1 }
                if bellPhase.1 > 1 { bellPhase.1 -= 1 }
                let squares = (bellPhase.0 < 0.5 ? 1 : -1) + (bellPhase.1 < 0.5 ? 1 : -1) as Float
                sample += bellFilter.process(squares * 0.16) * bellLevel
                bellLevel *= bellDecay
            }

            output[frame] = sample * gain.next()
        }
    }
}
