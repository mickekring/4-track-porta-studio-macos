import AVFoundation
import Observation
import OSLog
import Synchronization

/// What is plugged into one of the six input jacks.
nonisolated enum JackSource: Sendable, Equatable, Hashable, Codable {
    case nothing
    /// A channel of the Mac's audio input device, counted from zero.
    case deviceChannel(Int)
    /// The rhythm box sitting on the desk.
    case rhythmBox
}

/// The patch leads on the front panel.
nonisolated struct JackPatch: Sendable, Equatable, Codable {
    var input1 = JackSource.nothing
    var input2 = JackSource.nothing
    var input3 = JackSource.nothing
    var input4 = JackSource.nothing
    var input5 = JackSource.nothing
    var input6 = JackSource.nothing

    static let count = MachineDSP.jackCount

    subscript(jack: Int) -> JackSource {
        get {
            switch jack {
            case 0: input1
            case 1: input2
            case 2: input3
            case 3: input4
            case 4: input5
            default: input6
            }
        }
        set {
            switch jack {
            case 0: input1 = newValue
            case 1: input2 = newValue
            case 2: input3 = newValue
            case 3: input4 = newValue
            case 4: input5 = newValue
            default: input6 = newValue
            }
        }
    }

    var usesDeviceInput: Bool {
        (0..<Self.count).contains { if case .deviceChannel = self[$0] { true } else { false } }
    }
}

/// Carries audio from the input device's thread to the output device's.
///
/// The two may run from different clocks, so the reader resamples very
/// slightly to hold the amount of buffered audio steady instead of ever
/// running dry or overflowing.
nonisolated final class InputRing: @unchecked Sendable {
    static let capacity = 1 << 15
    static let maximumChannels = 8
    private static let mask = capacity - 1

    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)

    private(set) var channels = 0
    private var nominalStep = 1.0
    /// Frames kept in hand, measured at the start of each read.
    private(set) var targetFill = 256.0

    // Reader state, touched only by the output thread.
    private var readPosition = 0.0
    private var primed = false
    private var smoothedError = 0.0

    init() {
        storage = .allocate(capacity: Self.capacity * Self.maximumChannels)
        storage.initialize(repeating: 0, count: Self.capacity * Self.maximumChannels)
    }

    deinit {
        storage.deallocate()
    }

    /// Call only while no audio is flowing.
    func configure(channels: Int, inputRate: Double, outputRate: Double, targetFill: Int) {
        self.channels = min(Self.maximumChannels, max(0, channels))
        nominalStep = outputRate > 0 ? inputRate / outputRate : 1
        self.targetFill = Double(max(32, targetFill))
        primed = false
        smoothedError = 0
        written.store(0, ordering: .sequentiallyConsistent)
        readPosition = 0
    }

    /// Input thread: appends `frames` of deinterleaved audio.
    func write(_ list: UnsafePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let start = written.load(ordering: .relaxed)
        for channel in 0..<min(channels, buffers.count) {
            guard let source = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let line = storage + channel * Self.capacity
            for frame in 0..<frames {
                line[(start + frame) & Self.mask] = source[frame]
            }
        }
        written.store(start + frames, ordering: .releasing)
    }

    /// Output thread: fills `destination` (channel after channel, `stride`
    /// samples apart) with `frames` of input, or silence if none is flowing.
    func read(into destination: UnsafeMutablePointer<Float>, stride: Int, frames: Int) {
        func silence() {
            for channel in 0..<Self.maximumChannels {
                (destination + channel * stride).update(repeating: 0, count: frames)
            }
        }
        guard channels > 0 else { return silence() }
        let end = written.load(ordering: .acquiring)
        if !primed {
            guard Double(end) >= targetFill + 8 else { return silence() }
            readPosition = Double(end) - targetFill
            smoothedError = 0
            primed = true
        }

        // Hold the fill level with a gentle nudge to the resampling ratio.
        let fill = Double(end) - readPosition
        smoothedError += 0.003 * ((fill - targetFill) - smoothedError)
        var correction = 0.0
        if abs(smoothedError) > targetFill * 0.25 {
            correction = max(-0.004, min(0.004, smoothedError / targetFill * 0.002))
        }
        let step = nominalStep * (1 + correction)
        if fill < Double(frames) * step + 4 || fill > Double(Self.capacity) * 0.75 {
            // Ran dry or fell hopelessly behind: start over.
            primed = false
            return silence()
        }

        for frame in 0..<frames {
            let whole = readPosition.rounded(.down)
            let index = Int(whole)
            let fraction = Float(readPosition - whole)
            for channel in 0..<channels {
                let line = storage + channel * Self.capacity
                let sample: Float
                if fraction == 0 {
                    sample = line[index & Self.mask]
                } else {
                    sample = hermite(
                        line[(index - 1) & Self.mask], line[index & Self.mask],
                        line[(index + 1) & Self.mask], line[(index + 2) & Self.mask], fraction)
                }
                destination[channel * stride + frame] = sample
            }
            readPosition += step
        }
        for channel in channels..<Self.maximumChannels {
            (destination + channel * stride).update(repeating: 0, count: frames)
        }
    }
}

/// Everything the audio threads need, bundled so that none of it is tied to
/// the main actor.
nonisolated final class RenderContext: @unchecked Sendable {
    let core: MachineCore
    let ring = InputRing()
    let patch = Mailbox(JackPatch())
    let rhythm = RhythmBox()
    let masterRecorder = MasterRecorder()

    private var currentPatch = JackPatch()
    private let scratch: UnsafeMutablePointer<Float>
    private let rhythmScratch: UnsafeMutablePointer<Float>

    init(core: MachineCore) {
        self.core = core
        scratch = .allocate(capacity: InputRing.maximumChannels * MachineCore.maximumFrames)
        scratch.initialize(repeating: 0, count: InputRing.maximumChannels * MachineCore.maximumFrames)
        rhythmScratch = .allocate(capacity: MachineCore.maximumFrames)
        rhythmScratch.initialize(repeating: 0, count: MachineCore.maximumFrames)
    }

    deinit {
        scratch.deallocate()
        rhythmScratch.deallocate()
    }

    /// The node that *is* the machine as far as the Mac's output is concerned.
    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] _, _, frameCount, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            render(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
    }

    /// The node that swallows the Mac's input and hands it across threads.
    func makeSinkNode() -> AVAudioSinkNode {
        AVAudioSinkNode { [ring] _, frameCount, list in
            ring.write(list, frames: Int(frameCount))
            return noErr
        }
    }

    /// Output thread. Also called directly by the offline self-tests.
    func render(frames total: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        if let fresh = patch.read() { currentPatch = fresh }
        let span = MachineCore.maximumFrames
        var done = 0
        while done < total {
            let frames = min(span, total - done)
            ring.read(into: scratch, stride: span, frames: frames)
            rhythm.render(into: rhythmScratch, frames: frames)
            for jack in 0..<JackPatch.count {
                let destination = core.jacks + jack * span
                switch currentPatch[jack] {
                case .nothing:
                    destination.update(repeating: 0, count: frames)
                case .deviceChannel(let channel):
                    if channel >= 0 && channel < InputRing.maximumChannels {
                        destination.update(from: scratch + channel * span, count: frames)
                    } else {
                        destination.update(repeating: 0, count: frames)
                    }
                case .rhythmBox:
                    destination.update(from: rhythmScratch, count: frames)
                }
            }
            core.render(frames: frames, left: left + done, right: right + done)
            masterRecorder.capture(left: core.lineOut, right: core.lineOut + span, frames: frames)
            done += frames
        }
    }
}

/// Connects the machine to the Mac's audio hardware.
@Observable
final class AudioHost {
    let core: MachineCore
    @ObservationIgnored let context: RenderContext

    private(set) var isRunning = false
    private(set) var sampleRate = 48_000.0
    private(set) var outputDeviceName = ""
    private(set) var inputDeviceName = ""
    /// Names of the input device's channels, for the jack menus.
    private(set) var inputChannelNames: [String] = []
    /// True once the user has said no to the microphone prompt.
    private(set) var microphoneDenied = false
    /// Frames (at the output rate) a sound takes to go out of the Mac and come back in.
    private(set) var roundTripLatency = 0
    private(set) var problem: String?

    /// What is plugged into the input jacks.
    var patch = JackPatch() {
        didSet {
            guard patch != oldValue else { return }
            context.patch.post(patch)
            if started && patch.usesDeviceInput && !inputRunning { Task { await bringUpInput() } }
        }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var source: AVAudioSourceNode?
    @ObservationIgnored private var sink: AVAudioSinkNode?
    @ObservationIgnored private var inputRunning = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private let log = Logger(subsystem: "se.mickekring.X2026", category: "audio")

    /// Devices to use instead of the system defaults (the loopback self-test sets these).
    @ObservationIgnored var forcedOutputDevice: AudioDeviceID?
    @ObservationIgnored var forcedInputDevice: AudioDeviceID?

    /// The device chosen in Settings for PHONES, by UID; nil follows the system.
    var outputUID: String? {
        didSet {
            guard outputUID != oldValue else { return }
            UserDefaults.standard.set(outputUID, forKey: Self.outputKey)
            if started { configure(withInput: inputRunning) }
        }
    }

    /// The device chosen in Settings for the input jacks, by UID; nil follows the system.
    var inputUID: String? {
        didSet {
            guard inputUID != oldValue else { return }
            UserDefaults.standard.set(inputUID, forKey: Self.inputKey)
            refreshInputChannels()
            if started { configure(withInput: inputRunning) }
        }
    }

    private static let outputKey = "audio.output.uid"
    private static let inputKey = "audio.input.uid"

    private var chosenOutput: AudioDeviceID? {
        forcedOutputDevice
            ?? outputUID.flatMap { AudioHardware.device(withUID: $0, input: false) }
            ?? AudioHardware.defaultDevice(input: false)
    }

    private var chosenInput: AudioDeviceID? {
        forcedInputDevice
            ?? inputUID.flatMap { AudioHardware.device(withUID: $0, input: true) }
            ?? AudioHardware.defaultDevice(input: true)
    }

    /// I/O buffer we ask the hardware for. Small, so playing through the machine feels live.
    static let preferredBufferFrames: UInt32 = 128

    init(core: MachineCore) {
        self.core = core
        context = RenderContext(core: core)
        outputUID = UserDefaults.standard.string(forKey: Self.outputKey)
        inputUID = UserDefaults.standard.string(forKey: Self.inputKey)
        refreshInputChannels()
    }

    // MARK: - Lifecycle

    /// Powers the machine up.
    func start() {
        started = true
        let authorised = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        configure(withInput: patch.usesDeviceInput && authorised)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.log.info("Audio hardware changed; restarting")
                    self.refreshInputChannels()
                    self.configure(withInput: self.inputRunning)
                }
            }
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
    }

    /// Asks for the microphone if we have not yet, then starts taking input.
    private func bringUpInput() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                microphoneDenied = true
                return
            }
        default:
            microphoneDenied = true
            return
        }
        microphoneDenied = false
        refreshInputChannels()
        configure(withInput: true)
    }

    func refreshInputChannels() {
        guard let device = chosenInput else {
            inputChannelNames = []
            inputDeviceName = ""
            return
        }
        inputDeviceName = AudioHardware.name(of: device)
        let count = min(InputRing.maximumChannels, AudioHardware.channelCount(of: device, input: true))
        inputChannelNames = (0..<count).map { channel in
            AudioHardware.channelName(of: device, input: true, channel: channel)
                ?? (count == 1 ? inputDeviceName : "\(inputDeviceName) \(channel + 1)")
        }
    }

    // MARK: - Engine graph

    private func configure(withInput wantInput: Bool) {
        engine.stop()
        if let source { engine.detach(source) }
        if let sink { engine.detach(sink) }
        source = nil
        sink = nil
        inputRunning = false
        problem = nil

        do {
            let wantedOutput = chosenOutput
            let outputDevice = try engine.outputNode.withAUAudioUnit { unit in
                if let wantedOutput, unit.deviceID != wantedOutput { try unit.setDeviceID(wantedOutput) }
                return unit.deviceID
            }
            AudioHardware.requestBuffer(frames: Self.preferredBufferFrames, on: outputDevice)
            outputDeviceName = AudioHardware.name(of: outputDevice)

            let hardwareFormat = engine.outputNode.inputFormat(forBus: 0)
            let rate = hardwareFormat.sampleRate > 0 ? hardwareFormat.sampleRate : 48_000
            sampleRate = rate
            core.prepare(sampleRate: rate)
            context.rhythm.prepare(sampleRate: rate)
            context.masterRecorder.sampleRate = rate

            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
                throw CocoaError(.featureUnsupported)
            }
            let source = context.makeSourceNode(format: format)
            engine.attach(source)
            try engine.connectNode(source, to: engine.mainMixerNode, format: format)
            self.source = source

            var inputLatency = 0
            if wantInput {
                let wantedInput = chosenInput
                let inputDevice = try engine.inputNode.withAUAudioUnit { unit in
                    if let wantedInput, unit.deviceID != wantedInput { try unit.setDeviceID(wantedInput) }
                    return unit.deviceID
                }
                AudioHardware.requestBuffer(frames: Self.preferredBufferFrames, on: inputDevice)
                let inputFormat = engine.inputNode.outputFormat(forBus: 0)
                if inputFormat.channelCount > 0 && inputFormat.sampleRate > 0 {
                    let inputBuffer = AudioHardware.bufferFrames(of: inputDevice)
                    let outputBuffer = AudioHardware.bufferFrames(of: outputDevice)
                    // Enough in hand to ride out both devices delivering in lumps.
                    let scale = rate / inputFormat.sampleRate
                    let target = Int(Double(inputBuffer) * 1.25) + Int(Double(outputBuffer) / scale * 0.5) + 48
                    context.ring.configure(
                        channels: Int(inputFormat.channelCount),
                        inputRate: inputFormat.sampleRate, outputRate: rate, targetFill: target)
                    let sink = context.makeSinkNode()
                    engine.attach(sink)
                    try engine.connectNode(engine.inputNode, to: sink, format: inputFormat)
                    self.sink = sink
                    inputRunning = true
                    let inputFrames = AudioHardware.hardwareLatency(of: inputDevice, input: true)
                        + inputBuffer / 2 + target
                    inputLatency = Int((Double(inputFrames) * scale).rounded())
                } else {
                    log.notice("No usable input device")
                }
            }

            let outputLatency = AudioHardware.hardwareLatency(of: outputDevice, input: false)
                + AudioHardware.bufferFrames(of: outputDevice)
            roundTripLatency = inputRunning ? inputLatency + outputLatency : 0

            engine.prepare()
            try engine.start()
            isRunning = true
            log.info("Audio running at \(rate, format: .fixed(precision: 0)) Hz, round trip \(self.roundTripLatency) frames, input \(self.inputRunning)")
        } catch {
            isRunning = false
            problem = error.localizedDescription
            log.error("Could not start audio: \(error)")
        }
    }
}
