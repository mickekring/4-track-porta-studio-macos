import Foundation

/// The tape transport: one capstan, two reel hubs, and a tape between them.
///
/// The deck lives on the audio thread and moves the tape one output sample at
/// a time. In play the capstan sets the speed (with pitch control, start-up
/// run-in, wow and flutter). In fast wind a hub is driven instead, so the
/// tape's linear speed depends on how much is wound on it — slow off an empty
/// hub, fast near the end — exactly why the counter races and crawls.
nonisolated struct TapeDeck: Sendable {
    enum Motion: Int32, Sendable {
        case stop = 0
        case play = 1
        case fastForward = 2
        case rewind = 3
    }

    /// The numbers that make this particular machine itself.
    struct Calibration: Sendable {
        /// Seconds to wind a full C-60 from one end to the other.
        var fastWindTime = 105.0
        /// How much the wind motor slows as the pack it drives grows heavy.
        var windSag = 0.22
        /// Seconds for the wind motor to spin up, and for the brakes to bite.
        var windSpinUp = 0.32
        var windBrake = 0.09
        /// Seconds for the capstan to pull the tape up to speed after PLAY.
        var playRunIn = 0.075
        var playRunOut = 0.035
        /// Pitch knob range, as a fraction either way.
        var pitchRange = 0.10
        /// Overall wow and flutter, 1 = factory fresh.
        var flutterAmount: Float = 1
        /// Seconds a stalled reel takes to trip the auto-stop.
        var autoStopDelay = 0.45
    }

    var calibration = Calibration() {
        didSet { recalibrate() }
    }

    // MARK: Tape

    private(set) var geometry = ReelGeometry(stock: .c60)
    /// Frames of leader before the oxide starts.
    private(set) var leaderFrames = 0.0
    /// Frames from one end of the tape to the other, leaders included.
    private(set) var totalFrames = 0.0
    private(set) var hasTape = false

    /// Frames of tape that have passed the head since fully rewound.
    private(set) var position = 0.0
    /// Where the head was one sample ago.
    private(set) var previousPosition = 0.0

    // MARK: Motion

    private(set) var motion = Motion.stop
    /// Capstan drive, 0 (released) to 1 (pinch roller engaged, up to speed).
    private(set) var capstan = 0.0
    /// Driven hub speed in revolutions per second; positive winds forward.
    private(set) var windSpeed = 0.0
    /// Current tape velocity in frames per output sample.
    private(set) var velocity = 0.0

    private var sampleRate = 48_000.0
    private var framesPerSampleAtNominal = 1.0
    private var windBaseSpeed = 8.0
    private var referenceRadiusSpan = 0.0143
    private var windUpCoefficient = 0.0
    private var windBrakeCoefficient = 0.0
    private var runInCoefficient = 0.0
    private var runOutCoefficient = 0.0
    private var stallTime = 0.0
    /// Counts every time the mechanism trips itself to stop.
    private(set) var autoStopCount: UInt32 = 0

    private var flutter = WowFlutter()

    init() {
        recalibrate()
    }

    mutating func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        framesPerSampleAtNominal = CassetteStandard.sampleRate / sampleRate
        flutter.configure(sampleRate: sampleRate)
        recalibrate()
    }

    private mutating func recalibrate() {
        // Solve for the unloaded motor speed that winds a C-60 in exactly
        // `fastWindTime` given the linear sag with pack radius.
        let reference = ReelGeometry(stock: .c60)
        let sag = min(0.9, max(0.0001, calibration.windSag))
        referenceRadiusSpan = reference.fullRadius - reference.hubRadius
        windBaseSpeed = reference.fullTurns * log(1 / (1 - sag)) / (sag * calibration.fastWindTime)
        windUpCoefficient = 1 - exp(-1 / (calibration.windSpinUp * sampleRate))
        windBrakeCoefficient = 1 - exp(-1 / (calibration.windBrake * sampleRate))
        runInCoefficient = 1 - exp(-1 / (calibration.playRunIn * sampleRate))
        runOutCoefficient = 1 - exp(-1 / (calibration.playRunOut * sampleRate))
    }

    // MARK: - Loading

    /// Threads a cassette. `position` is where its tape was left, in frames.
    mutating func load(stock: TapeStock, position start: Double) {
        geometry = ReelGeometry(stock: stock)
        leaderFrames = stock.leaderLength * CassetteStandard.framesPerMeter
        totalFrames = stock.totalLength * CassetteStandard.framesPerMeter
        position = max(0, min(totalFrames, start))
        previousPosition = position
        hasTape = true
        halt()
    }

    mutating func unload() {
        hasTape = false
        halt()
    }

    private mutating func halt() {
        motion = .stop
        capstan = 0
        windSpeed = 0
        velocity = 0
        stallTime = 0
    }

    /// What the transport keys are asking for.
    mutating func set(motion requested: Motion) {
        motion = hasTape ? requested : .stop
        if motion == .stop { stallTime = 0 }
    }

    // MARK: - Derived

    /// Head position in oxide frames; negative or past the end means leader.
    @inline(__always)
    var oxideFrame: Double { position - leaderFrames }

    @inline(__always)
    var previousOxideFrame: Double { previousPosition - leaderFrames }

    /// Position in metres, for the reel geometry.
    @inline(__always)
    var positionMeters: Double { position / CassetteStandard.framesPerMeter }

    /// True while the pinch roller has the tape and is moving it.
    @inline(__always)
    var isRolling: Bool { capstan > 0.001 }

    /// Maximum hub speed of the wind motor, for scaling its whine.
    var windTopSpeed: Double { windBaseSpeed }

    // MARK: - Per-sample

    /// Moves the tape by one output sample. `pitch` is -1...1 from the knob.
    @inline(__always)
    mutating func advance(pitch: Double) {
        previousPosition = position
        guard hasTape else {
            velocity = 0
            return
        }

        let meters = positionMeters
        let takeUpRadius = geometry.takeUpRadius(at: meters)
        let supplyRadius = geometry.supplyRadius(at: meters)

        // Capstan: constant linear speed, give or take.
        let capstanTarget = motion == .play ? 1.0 : 0.0
        capstan += (capstanTarget > capstan ? runInCoefficient : runOutCoefficient) * (capstanTarget - capstan)
        var step = 0.0
        if capstan > 0.0005 {
            let wander = Double(flutter.next(
                supplyRadius: supplyRadius, takeUpRadius: takeUpRadius, amount: calibration.flutterAmount))
            step = capstan * (1 + calibration.pitchRange * pitch) * (1 + wander) * framesPerSampleAtNominal
        }

        // Wind motor: drives whichever hub is taking tape up.
        var windTarget = 0.0
        var drivenRadius = takeUpRadius
        switch motion {
        case .fastForward:
            windTarget = windBaseSpeed * loadFactor(takeUpRadius)
        case .rewind:
            drivenRadius = supplyRadius
            windTarget = -windBaseSpeed * loadFactor(supplyRadius)
        default:
            if windSpeed < 0 { drivenRadius = supplyRadius }
        }
        let braking = abs(windTarget) < abs(windSpeed) || windTarget * windSpeed < 0
        windSpeed += (braking ? windBrakeCoefficient : windUpCoefficient) * (windTarget - windSpeed)
        if abs(windSpeed) > 0.0005 {
            let metersPerSecond = windSpeed * 2 * .pi * drivenRadius
            step += metersPerSecond * CassetteStandard.framesPerMeter / sampleRate
        } else if windTarget == 0 {
            windSpeed = 0
        }

        // The tape is anchored to the hubs: at either end it simply stops.
        var next = position + step
        var blocked = false
        if next >= totalFrames {
            next = totalFrames
            blocked = step > 0
        } else if next <= 0 {
            next = 0
            blocked = step < 0
        }
        velocity = next - position
        position = next

        if blocked {
            windSpeed = 0
            if motion != .stop {
                stallTime += 1 / sampleRate
                if stallTime >= calibration.autoStopDelay {
                    motion = .stop
                    stallTime = 0
                    autoStopCount &+= 1
                }
            }
        } else {
            stallTime = 0
        }
    }

    /// Motor speed relative to no-load, given the radius of the pack it turns.
    @inline(__always)
    private func loadFactor(_ radius: Double) -> Double {
        let fill = (radius - geometry.hubRadius) / referenceRadiusSpan
        return max(0.1, 1 - calibration.windSag * fill)
    }
}

/// Speed instability of a small belt-driven cassette mechanism.
///
/// Slow wow comes from the reels and the pinch roller, faster flutter from the
/// capstan, and a little randomness from everything else.
nonisolated struct WowFlutter: Sendable {
    private var capstanPhase: Float = 0
    private var pinchPhase: Float = 1.3
    private var supplyPhase: Float = 2.1
    private var takeUpPhase: Float = 4.4
    private var noise = NoiseSource(seed: 0xC455_E77E)
    private var slowDrift = OnePole()
    private var roughness = OnePole()
    private var slowScale: Float = 0
    private var roughScale: Float = 0
    /// 2π × metres of tape per output sample; divide by a circumference to
    /// get that wheel's phase step.
    private var phasePerSample: Float = 0

    // Circumferences decide the frequencies: a 2 mm capstan turns 7.6 times a
    // second, the 13 mm pinch roller a little over once.
    private static let capstanCircumference: Float = .pi * 0.002
    private static let pinchCircumference: Float = .pi * 0.013

    mutating func configure(sampleRate: Double) {
        phasePerSample = Float(2 * Double.pi * CassetteStandard.nominalSpeed / sampleRate)
        slowDrift.setCutoff(0.8, sampleRate: sampleRate)
        roughness.setCutoff(18, sampleRate: sampleRate)
        slowScale = 0.00045 / (0.5774 * (slowDrift.coefficient / 2).squareRoot())
        roughScale = 0.00040 / (0.5774 * (roughness.coefficient / 2).squareRoot())
    }

    /// Fractional speed error for this sample (0.001 = 0.1 %).
    @inline(__always)
    mutating func next(supplyRadius: Double, takeUpRadius: Double, amount: Float) -> Float {
        capstanPhase += phasePerSample / Self.capstanCircumference
        pinchPhase += phasePerSample / Self.pinchCircumference
        supplyPhase += phasePerSample / (2 * .pi * Float(supplyRadius))
        takeUpPhase += phasePerSample / (2 * .pi * Float(takeUpRadius))
        if capstanPhase > 2 * .pi { capstanPhase -= 2 * .pi }
        if pinchPhase > 2 * .pi { pinchPhase -= 2 * .pi }
        if supplyPhase > 2 * .pi { supplyPhase -= 2 * .pi }
        if takeUpPhase > 2 * .pi { takeUpPhase -= 2 * .pi }

        let white = noise.next()
        let periodic = 0.00055 * sinf(capstanPhase)
            + 0.00060 * sinf(pinchPhase)
            + 0.00035 * sinf(supplyPhase)
            + 0.00035 * sinf(takeUpPhase)
        let random = slowDrift.process(white * slowScale) + roughness.process(white * roughScale)
        return amount * (periodic + random)
    }
}
