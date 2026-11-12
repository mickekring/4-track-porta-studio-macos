import Foundation

/// Four of something, one per tape track (or per INPUT/TAPE channel 3–6).
/// Plain data, so it can cross to the audio thread by value.
nonisolated struct Quad<Value: Sendable & Equatable & Codable>: Sendable, Equatable, Codable {
    var first: Value
    var second: Value
    var third: Value
    var fourth: Value

    init(repeating value: Value) {
        first = value
        second = value
        third = value
        fourth = value
    }

    init(_ first: Value, _ second: Value, _ third: Value, _ fourth: Value) {
        self.first = first
        self.second = second
        self.third = third
        self.fourth = fourth
    }

    subscript(index: Int) -> Value {
        get {
            switch index {
            case 0: first
            case 1: second
            case 2: third
            default: fourth
            }
        }
        set {
            switch index {
            case 0: first = newValue
            case 1: second = newValue
            case 2: third = newValue
            default: fourth = newValue
            }
        }
    }
}

/// What the headphones are listening to.
nonisolated enum MonitorSource: Int, Sendable, Codable, CaseIterable {
    /// The stereo buss with the AUX buss added in the middle.
    case lineAndAux = 0
    /// The AUX buss alone, in both ears. This is the cue mix for overdubs.
    case aux = 1
    /// The stereo buss plus the sub mix (in NORM), for rehearsing in stereo.
    case lineAndSubMix = 2
}

/// A REC TRK selector: each stereo buss side can feed one of two tracks, or none.
nonisolated enum RecordSelect: Int, Sendable, Codable, CaseIterable {
    case upper = 0
    case off = 1
    case lower = 2
}

/// Every knob, fader and switch on the top panel.
///
/// Continuous controls run 0…1 over their travel. The INPUT/TRK knobs on
/// channels 3–6 are zero at twelve o'clock: below 0.5 they bring up the line
/// input, above 0.5 the tape track.
nonisolated struct Panel: Sendable, Equatable, Codable {
    // Channels 1–2
    var micGain1 = false
    var micGain2 = false
    var fader1 = 0.0
    var fader2 = 0.0
    var pan1 = 0.5
    var pan2 = 0.5
    var aux1 = 0.0
    var aux2 = 0.0

    // Channels 3–6
    var aux = Quad(repeating: 0.5)
    var subPan = Quad(repeating: 0.5)
    var subGain = Quad(repeating: 0.5)

    // Master section
    var auxSend = 0.0
    var auxReturnL = 0.0
    var auxReturnR = 0.0
    var eqHighL = 0.5
    var eqHighR = 0.5
    var eqLowL = 0.5
    var eqLowR = 0.5
    var master = 0.0
    var monitorLevel = 0.0
    var pitch = 0.5

    // Switches
    var noiseReduction = true
    var monitor = MonitorSource.lineAndSubMix
    var remix = false
    var recordL = RecordSelect.off
    var recordR = RecordSelect.off
    var metersShowMixer = false

    /// How it looks when somebody has just finished a mix and left it:
    /// everything you need to hear a tape the moment you press PLAY.
    static let readyToPlay: Panel = {
        var panel = Panel()
        panel.fader1 = 0.7
        panel.fader2 = 0.7
        panel.subGain = Quad(repeating: 0.82)
        panel.subPan = Quad(0.3, 0.7, 0.42, 0.58)
        panel.master = 0.75
        panel.monitorLevel = 0.45
        panel.auxSend = 0.5
        panel.remix = true
        panel.monitor = .lineAndSubMix
        return panel
    }()

    /// Track index (0…3) armed from the left buss, if any.
    var armedFromLeft: Int? {
        switch recordL {
        case .upper: 0
        case .off: nil
        case .lower: 2
        }
    }

    /// Track index (0…3) armed from the right buss, if any.
    var armedFromRight: Int? {
        switch recordR {
        case .upper: 1
        case .off: nil
        case .lower: 3
        }
    }

    func isArmed(track: Int) -> Bool {
        armedFromLeft == track || armedFromRight == track
    }
}

/// What the transport keys and the foot switch are asking for.
nonisolated struct TransportRequest: Sendable, Equatable {
    var motion = TapeDeck.Motion.stop
    /// The RECORD key is latched down.
    var recordKey = false
    /// The foot switch has punched in.
    var punch = false
}

/// One complete instruction to the audio thread.
nonisolated struct ControlFrame: Sendable {
    var panel = Panel()
    var transport = TransportRequest()
    var effect = AuxEffect.Settings()
    /// Loudness of keys, motors and lids, 0…1.
    var mechanicalLevel: Float = 0.6
    /// Round-trip delay of the computer's audio hardware in output samples.
    /// Overdubs are written this much earlier on the tape so they line up.
    var recordLatency = 0
}

/// Colour of the arrow lamp under each meter.
nonisolated enum TrackLamp: UInt8, Sendable {
    /// Green: you are hearing the tape.
    case tape = 0
    /// Amber: armed, and you are hearing the input.
    case standby = 1
    /// Red: recording.
    case recording = 2
}

/// What the audio thread reports back, many times a second.
nonisolated struct Telemetry: Sendable {
    var hasTape = false
    /// Frames of tape past the head, leaders included.
    var position = 0.0
    var motion = TapeDeck.Motion.stop
    /// 0 = pinch roller off, 1 = tape at playing speed.
    var capstan: Float = 0
    /// Hub speed of the wind motor in revolutions per second, signed.
    var windSpeed: Float = 0
    /// Meter levels as linear amplitude relative to the 0 mark.
    var meters = Quad<Float>(repeating: 0)
    var lamps = Quad<UInt8>(repeating: 0)
    /// Counts each time the mechanism stopped itself at the end of the tape.
    var autoStopCount: UInt32 = 0
    var isRecording = false
}
