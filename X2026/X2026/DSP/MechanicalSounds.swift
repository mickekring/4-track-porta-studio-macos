import Foundation

/// The noises the machine makes in the room, as opposed to on the tape.
nonisolated enum MechanicalSound: UInt8, Sendable {
    case keyDown
    case keyRelease
    case stopKey
    case switchLarge
    case switchSmall
    case counterReset
    case lidOpen
    case lidClose
    case cassetteIn
    case cassetteOut
    case autoStop
    case plug
    case footSwitch
}

/// A tiny physical-ish synthesiser for clunks, clicks and motor whine.
///
/// Every impact is a burst of filtered noise (the click of plastic) plus a
/// decaying low tone (the body of the machine ringing). The motors are
/// generated continuously from what the transport is actually doing, so the
/// rewind whine climbs and sags with the real hub speed.
nonisolated struct MechanicalSounds {
    private struct Voice {
        var delay = 0
        var active = false
        var noiseLevel: Float = 0
        var noiseDecay: Float = 0
        var filter = Biquad()
        var toneLevel: Float = 0
        var toneDecay: Float = 0
        var phase: Float = 0
        var phaseStep: Float = 0
        var glide: Float = 1
        var panL: Float = 1
        var panR: Float = 1
    }

    private static let voiceCount = 16
    private var voices: UnsafeMutablePointer<Voice>?
    private var nextVoice = 0
    private var sampleRate = 48_000.0
    private var noise = NoiseSource(seed: 0xB0B1_1E55)

    // Motors
    private var whinePhase: Float = 0
    private var gearPhase: Float = 0
    private var hubPhase: Float = 0
    private var windLevel: Float = 0
    private var windRate: Float = 0
    private var capstanLevel: Float = 0
    private var humPhase: Float = 0
    private var shuffle = Biquad()
    private var rumble = OnePole()

    mutating func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        if voices == nil {
            voices = .allocate(capacity: Self.voiceCount)
            voices?.initialize(repeating: Voice(), count: Self.voiceCount)
        }
        shuffle.setLowpass(frequency: 2600, q: 0.9, sampleRate: sampleRate)
        rumble.setCutoff(180, sampleRate: sampleRate)
    }

    mutating func release() {
        voices?.deallocate()
        voices = nil
    }

    // MARK: - Impacts

    private mutating func strike(
        after milliseconds: Double = 0,
        noise level: Float, band: Double, q: Double = 1.4, ring: Double,
        tone: Float = 0, pitch: Double = 150, sustain: Double = 40, glide: Float = 0.99994,
        pan: Float = 0.65
    ) {
        guard let voices else { return }
        var voice = Voice()
        voice.delay = Int(milliseconds * 0.001 * sampleRate)
        voice.active = true
        voice.noiseLevel = level
        voice.noiseDecay = Float(exp(-1 / (ring * 0.001 * sampleRate)))
        voice.filter.setPeak(frequency: band, q: q, gainDB: 18, sampleRate: sampleRate)
        voice.toneLevel = tone
        voice.toneDecay = Float(exp(-1 / (sustain * 0.001 * sampleRate)))
        voice.phaseStep = Float(2 * Double.pi * pitch / sampleRate)
        voice.glide = glide
        voice.panL = min(1, 1.3 - pan)
        voice.panR = min(1, 0.3 + pan)
        voices[nextVoice] = voice
        nextVoice = (nextVoice + 1) % Self.voiceCount
    }

    mutating func trigger(_ sound: MechanicalSound) {
        switch sound {
        case .keyDown:
            strike(noise: 0.20, band: 1700, q: 1.2, ring: 9, tone: 0.30, pitch: 118, sustain: 55)
            strike(after: 19, noise: 0.13, band: 3300, q: 2.2, ring: 4)
        case .keyRelease:
            strike(noise: 0.24, band: 2300, q: 1.0, ring: 7, tone: 0.20, pitch: 185, sustain: 32)
            strike(after: 9, noise: 0.15, band: 1500, ring: 13, tone: 0.14, pitch: 96, sustain: 52)
        case .stopKey:
            strike(noise: 0.11, band: 1200, ring: 10, tone: 0.20, pitch: 102, sustain: 45)
        case .switchLarge:
            strike(noise: 0.15, band: 2800, q: 2.5, ring: 3.5, tone: 0.10, pitch: 420, sustain: 11, pan: 0.5)
            strike(after: 6, noise: 0.08, band: 3700, q: 2.5, ring: 3, pan: 0.5)
        case .switchSmall:
            strike(noise: 0.30, band: 4600, q: 3, ring: 2.4, tone: 0.03, pitch: 620, sustain: 6, pan: 0.35)
        case .counterReset:
            strike(noise: 0.32, band: 3100, q: 2, ring: 4, tone: 0.04, pitch: 500, sustain: 8, pan: 0.75)
            strike(after: 12, noise: 0.20, band: 2100, q: 1.0, ring: 34, pan: 0.75)
        case .lidOpen:
            strike(noise: 0.10, band: 900, q: 0.8, ring: 26, tone: 0.14, pitch: 255, sustain: 40, pan: 0.8)
        case .lidClose:
            strike(noise: 0.22, band: 1100, q: 0.9, ring: 16, tone: 0.24, pitch: 148, sustain: 70, pan: 0.8)
            strike(after: 23, noise: 0.08, band: 2700, q: 2, ring: 6, pan: 0.8)
        case .cassetteIn:
            strike(noise: 0.17, band: 1750, q: 1.5, ring: 8, tone: 0.20, pitch: 320, sustain: 30, pan: 0.8)
            strike(after: 36, noise: 0.12, band: 2350, q: 1.8, ring: 6, pan: 0.8)
            strike(after: 74, noise: 0.09, band: 1400, ring: 11, tone: 0.16, pitch: 208, sustain: 42, pan: 0.8)
        case .cassetteOut:
            strike(noise: 0.13, band: 2050, q: 1.6, ring: 7, pan: 0.8)
            strike(after: 42, noise: 0.10, band: 1500, ring: 9, tone: 0.10, pitch: 280, sustain: 25, pan: 0.8)
        case .autoStop:
            strike(noise: 0.30, band: 2300, q: 1.0, ring: 8, tone: 0.24, pitch: 170, sustain: 40)
            strike(after: 8, noise: 0.20, band: 1400, ring: 15, tone: 0.20, pitch: 88, sustain: 70)
        case .plug:
            strike(noise: 0.15, band: 2000, q: 2, ring: 5, tone: 0.20, pitch: 240, sustain: 25, pan: 0.3)
            strike(after: 30, noise: 0.10, band: 2900, q: 2, ring: 4, pan: 0.3)
        case .footSwitch:
            strike(noise: 0.20, band: 1300, ring: 10, tone: 0.24, pitch: 160, sustain: 40, pan: 0.3)
            strike(after: 55, noise: 0.10, band: 2500, q: 2, ring: 4, pan: 0.3)
        }
    }

    // MARK: - Rendering

    /// Adds the room noises onto `left` and `right`.
    /// - Parameters:
    ///   - windSpeed: hub speed in revolutions per second, signed.
    ///   - windTop: no-load hub speed, for scaling.
    ///   - capstan: 0…1 capstan drive.
    mutating func render(
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
        windSpeed: Double, windTop: Double, capstan: Double, level: Float
    ) {
        guard let voices, level > 0.0005 else { return }

        // Impacts.
        for index in 0..<Self.voiceCount where voices[index].active {
            var voice = voices[index]
            var frame = 0
            if voice.delay > 0 {
                let wait = min(voice.delay, frames)
                voice.delay -= wait
                frame = wait
            }
            while frame < frames {
                var sample = voice.filter.process(noise.next() * voice.noiseLevel) * 0.12
                sample += sinf(voice.phase) * voice.toneLevel
                voice.phase += voice.phaseStep
                voice.phaseStep *= voice.glide
                voice.noiseLevel *= voice.noiseDecay
                voice.toneLevel *= voice.toneDecay
                left[frame] += sample * voice.panL * level
                right[frame] += sample * voice.panR * level
                frame += 1
            }
            if voice.noiseLevel < 0.0002 && voice.toneLevel < 0.0002 { voice.active = false }
            if voice.phase > 1000 { voice.phase = voice.phase.truncatingRemainder(dividingBy: 2 * .pi) }
            voices[index] = voice
        }

        // Motors.
        let targetWind = Float(min(1.2, abs(windSpeed) / max(0.001, windTop)))
        let targetRate = Float(abs(windSpeed))
        let targetCapstan = Float(capstan)
        guard targetWind > 0.0005 || windLevel > 0.0005 || targetCapstan > 0.0005 || capstanLevel > 0.0005 else { return }

        let twoPi = 2 * Float.pi
        let step = 1 / Float(sampleRate)
        for frame in 0..<frames {
            windLevel += (targetWind - windLevel) * 0.002
            windRate += (targetRate - windRate) * 0.002
            capstanLevel += (targetCapstan - capstanLevel) * 0.002
            let white = noise.next()

            // Wind motor: gear whine that follows hub speed, tape shuffling
            // through the guides, and the hubs rattling in the shell.
            whinePhase += twoPi * windRate * 43 * step
            gearPhase += twoPi * windRate * 17.3 * step
            hubPhase += twoPi * windRate * step
            if whinePhase > twoPi { whinePhase -= twoPi }
            if gearPhase > twoPi { gearPhase -= twoPi }
            if hubPhase > twoPi { hubPhase -= twoPi }
            let rattle = 0.75 + 0.25 * sinf(hubPhase * 2)
            let whine = sinf(whinePhase) * 0.020 + sinf(whinePhase * 2.01) * 0.008 + sinf(gearPhase) * 0.012
            let hiss = shuffle.process(white) * 0.028 * rattle
            var sample = (whine + hiss) * windLevel * windLevel

            // Capstan motor: a quiet hum and a breath of bearing noise.
            humPhase += twoPi * 97 * step
            if humPhase > twoPi { humPhase -= twoPi }
            sample += (sinf(humPhase) * 0.0035 + sinf(humPhase * 3) * 0.0012 + rumble.process(white) * 0.012) * capstanLevel

            left[frame] += sample * 0.75 * level
            right[frame] += sample * level
        }
    }
}
