import Foundation

/// The little effects box patched between AUX SEND and AUX RCV: a budget
/// late-eighties digital reverb with an echo setting. Mono in, stereo out,
/// 100 % wet, as the manual tells you to set it.
///
/// Reverb is the classic bank of eight damped comb filters into four allpass
/// diffusers per side.
nonisolated struct AuxEffect {
    enum Mode: Int, Sendable, Codable, CaseIterable {
        case reverb
        case echo
    }

    struct Settings: Sendable, Equatable, Codable {
        /// Cables plugged in. Without them AUX RCV hears nothing.
        var connected = false
        var mode = Mode.reverb
        /// Reverb decay, or echo time.
        var size = 0.55
        /// Reverb brightness, or echo repeats.
        var colour = 0.5
    }

    private struct Line {
        var buffer: UnsafeMutablePointer<Float>
        var length: Int
        var index = 0
        var memory: Float = 0
    }

    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTunings = [556, 441, 341, 225]
    private static let stereoSpread = 23
    private static let combCount = 8
    private static let allpassCount = 4

    private var combs: UnsafeMutablePointer<Line>?
    private var allpasses: UnsafeMutablePointer<Line>?
    private var echo: UnsafeMutablePointer<Float>?
    private var echoLength = 0
    private var echoIndex = 0
    private var preDelay: UnsafeMutablePointer<Float>?
    private var preDelayLength = 0
    private var preDelayIndex = 0

    private var sampleRate = 48_000.0
    private var lowCut = DCBlocker()
    private var topL = OnePole()
    private var topR = OnePole()
    private var echoTone = OnePole()

    private var feedback: Float = 0.84
    private var damping: Float = 0.3
    private var echoDelay = 12_000.0
    private var echoDelaySmoothed = 12_000.0
    private var echoFeedback: Float = 0.4
    private var mode = Mode.reverb
    private var connected = false

    /// Allocates the delay memory. Never call on the audio thread.
    mutating func prepare(sampleRate: Double) {
        release()
        self.sampleRate = sampleRate
        let scale = sampleRate / 44_100

        let combs = UnsafeMutablePointer<Line>.allocate(capacity: Self.combCount * 2)
        let allpasses = UnsafeMutablePointer<Line>.allocate(capacity: Self.allpassCount * 2)
        func makeLine(_ samples: Int) -> Line {
            let length = max(8, Int((Double(samples) * scale).rounded()))
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: length)
            buffer.initialize(repeating: 0, count: length)
            return Line(buffer: buffer, length: length)
        }
        for side in 0..<2 {
            for (index, tuning) in Self.combTunings.enumerated() {
                (combs + side * Self.combCount + index).initialize(to: makeLine(tuning + side * Self.stereoSpread))
            }
            for (index, tuning) in Self.allpassTunings.enumerated() {
                (allpasses + side * Self.allpassCount + index).initialize(to: makeLine(tuning + side * Self.stereoSpread))
            }
        }
        self.combs = combs
        self.allpasses = allpasses

        echoLength = Int(sampleRate * 1.2)
        echo = .allocate(capacity: echoLength)
        echo?.initialize(repeating: 0, count: echoLength)
        preDelayLength = Int(sampleRate * 0.018)
        preDelay = .allocate(capacity: preDelayLength)
        preDelay?.initialize(repeating: 0, count: preDelayLength)

        lowCut.setCutoff(140, sampleRate: sampleRate)
        topL.setCutoff(9000, sampleRate: sampleRate)
        topR.setCutoff(9000, sampleRate: sampleRate)
        echoTone.setCutoff(3200, sampleRate: sampleRate)
    }

    mutating func release() {
        if let combs {
            for index in 0..<(Self.combCount * 2) { combs[index].buffer.deallocate() }
            combs.deallocate()
        }
        if let allpasses {
            for index in 0..<(Self.allpassCount * 2) { allpasses[index].buffer.deallocate() }
            allpasses.deallocate()
        }
        echo?.deallocate()
        preDelay?.deallocate()
        combs = nil
        allpasses = nil
        echo = nil
        preDelay = nil
    }

    /// Empties every delay line. Allocation-free.
    mutating func clear() {
        if let combs {
            for index in 0..<(Self.combCount * 2) {
                combs[index].buffer.update(repeating: 0, count: combs[index].length)
                combs[index].memory = 0
            }
        }
        if let allpasses {
            for index in 0..<(Self.allpassCount * 2) {
                allpasses[index].buffer.update(repeating: 0, count: allpasses[index].length)
            }
        }
        echo?.update(repeating: 0, count: echoLength)
        preDelay?.update(repeating: 0, count: preDelayLength)
        lowCut = DCBlocker()
        lowCut.setCutoff(140, sampleRate: sampleRate)
        topL.value = 0
        topR.value = 0
        echoTone.value = 0
    }

    /// Takes new knob positions. Cheap enough for the top of every block.
    mutating func apply(_ settings: Settings) {
        connected = settings.connected
        mode = settings.mode
        let size = Float(min(1, max(0, settings.size)))
        let colour = Float(min(1, max(0, settings.colour)))
        feedback = 0.70 + 0.28 * size
        damping = 0.75 - 0.65 * colour
        echoDelay = sampleRate * (0.07 + 0.63 * Double(size))
        echoFeedback = 0.82 * colour
    }

    /// One sample of AUX SEND in, a stereo return out.
    @inline(__always)
    mutating func process(_ send: Float) -> (left: Float, right: Float) {
        guard connected, let combs, let allpasses, let echo, let preDelay else { return (0, 0) }
        let input = lowCut.process(send)

        switch mode {
        case .reverb:
            let delayed = preDelay[preDelayIndex]
            preDelay[preDelayIndex] = input
            preDelayIndex += 1
            if preDelayIndex >= preDelayLength { preDelayIndex = 0 }

            let feed = delayed * 0.03
            var left: Float = 0
            var right: Float = 0
            for index in 0..<Self.combCount {
                left += Self.comb(combs + index, feed, feedback, damping)
                right += Self.comb(combs + Self.combCount + index, feed, feedback, damping)
            }
            for index in 0..<Self.allpassCount {
                left = Self.allpass(allpasses + index, left)
                right = Self.allpass(allpasses + Self.allpassCount + index, right)
            }
            return (topL.process(left * 2.4), topR.process(right * 2.4))

        case .echo:
            // Glide to a new delay time like a tape echo changing speed.
            echoDelaySmoothed += (echoDelay - echoDelaySmoothed) * 0.0004
            var readAt = Double(echoIndex) - echoDelaySmoothed
            if readAt < 0 { readAt += Double(echoLength) }
            let whole = Int(readAt)
            let fraction = Float(readAt - Double(whole))
            let a = echo[whole % echoLength]
            let b = echo[(whole + 1) % echoLength]
            let tap = a + (b - a) * fraction
            let repeatSignal = echoTone.process(tap)
            echo[echoIndex] = Saturation.soft(input + repeatSignal * echoFeedback)
            echoIndex += 1
            if echoIndex >= echoLength { echoIndex = 0 }
            // The right side trails a touch behind for width.
            let late = echo[(whole + echoLength - Int(sampleRate * 0.011)) % echoLength]
            return (topL.process(tap), topR.process(0.6 * tap + 0.4 * late))
        }
    }

    @inline(__always)
    private static func comb(_ line: UnsafeMutablePointer<Line>, _ input: Float, _ feedback: Float, _ damping: Float) -> Float {
        let output = line.pointee.buffer[line.pointee.index]
        let filtered = output * (1 - damping) + line.pointee.memory * damping
        line.pointee.memory = filtered
        line.pointee.buffer[line.pointee.index] = input + filtered * feedback
        line.pointee.index += 1
        if line.pointee.index >= line.pointee.length { line.pointee.index = 0 }
        return output
    }

    @inline(__always)
    private static func allpass(_ line: UnsafeMutablePointer<Line>, _ input: Float) -> Float {
        let buffered = line.pointee.buffer[line.pointee.index]
        line.pointee.buffer[line.pointee.index] = input + buffered * 0.5
        line.pointee.index += 1
        if line.pointee.index >= line.pointee.length { line.pointee.index = 0 }
        return buffered - input
    }
}
