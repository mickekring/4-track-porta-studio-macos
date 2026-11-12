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

    /// How many frames had been written, and when (on the Mac's clock) the
    /// input device handed over the last of them.
    struct Stamp: Sendable {
        var written = 0
        var hostTime: UInt64 = 0
    }

    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    /// Posted by the input thread for every buffer it delivers.
    let stamp = Mailbox(Stamp())

    private(set) var channels = 0
    private(set) var inputRate = 48_000.0
    private var nominalStep = 1.0
    /// Ring position of the first frame handed out by the last `read`, or
    /// nil if that read produced silence. Output thread only.
    private(set) var lastReadStart: Double?
    /// Frames kept in hand, measured at the start of each read.
    private(set) var targetFill = 256.0

    // Reader state, touched only by the output thread.
    private var readPosition = 0.0
    private var primed = false
    private var smoothedError = 0.0
    /// Frames written when the ring last ran dry. Reading only resumes once
    /// a full reserve of *new* input has arrived after that.
    private var ranDryAt = 0

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
        self.inputRate = inputRate > 0 ? inputRate : 48_000
        nominalStep = outputRate > 0 ? inputRate / outputRate : 1
        lastReadStart = nil
        stamp.post(Stamp())
        self.targetFill = Double(max(32, targetFill))
        primed = false
        smoothedError = 0
        ranDryAt = 0
        written.store(0, ordering: .sequentiallyConsistent)
        readPosition = 0
    }

    /// Input thread: appends `frames` of deinterleaved audio.
    func write(_ list: UnsafePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let start = written.load(ordering: .relaxed)
        stamp.post(Stamp(written: start + frames, hostTime: mach_absolute_time()))
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
            lastReadStart = nil
            for channel in 0..<Self.maximumChannels {
                (destination + channel * stride).update(repeating: 0, count: frames)
            }
        }
        guard channels > 0 else { return silence() }
        let end = written.load(ordering: .acquiring)
        if !primed {
            guard Double(end - ranDryAt) >= targetFill + 8 else { return silence() }
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
            // Ran dry or fell hopelessly behind: start over, but only with
            // fresh input. If the input has stopped for good, stay silent
            // rather than chew over the last scraps for ever.
            primed = false
            ranDryAt = end
            return silence()
        }

        lastReadStart = readPosition
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

    /// Measured age of the input frame being consumed, counted from the
    /// moment the input device delivered it, in microseconds; 0 until known.
    /// It replaces the guess that the two devices' callbacks are, on
    /// average, half a buffer apart: for one session they are a fixed
    /// distance apart, and this is it.
    let measuredLoop = Atomic<Int>(0)
    private var smoothedLoop = 0.0
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

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
            render(frames: Int(frameCount), left: left, right: right, measuring: true)
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
    func render(
        frames total: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
        measuring: Bool = false
    ) {
        if let fresh = patch.read() { currentPatch = fresh }
        let span = MachineCore.maximumFrames
        var done = 0
        while done < total {
            let frames = min(span, total - done)
            ring.read(into: scratch, stride: span, frames: frames)
            if done == 0 && measuring { measureLoop() }
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

nonisolated extension RenderContext {
    /// How old is the input frame being consumed right now? The frames
    /// still waiting behind it, plus the time since the input device last
    /// delivered.
    fileprivate func measureLoop() {
        guard let firstRead = ring.lastReadStart,
              let stamp = ring.stamp.read(attempts: 2), stamp.hostTime != 0
        else { return }
        let now = mach_absolute_time()
        guard now >= stamp.hostTime else { return }
        let sinceDelivery = Double(now - stamp.hostTime) * Self.secondsPerTick
        let age = (Double(stamp.written) - firstRead) / ring.inputRate + sinceDelivery
        guard age > 0, age < 1 else { return }
        smoothedLoop = smoothedLoop == 0 ? age : smoothedLoop + (age - smoothedLoop) * 0.02
        measuredLoop.store(Int(smoothedLoop * 1_000_000), ordering: .relaxed)
    }

    fileprivate func forgetLoop() {
        smoothedLoop = 0
        measuredLoop.store(0, ordering: .relaxed)
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
    #if DEBUG
    /// For the self-test: stands in for audio that will not start.
    func debugReport(problem text: String?) { problem = text }
    /// For the self-test: what a change of hardware does, without the wait.
    func debugRestart() { restartAfterChange() }
    #endif

    /// True while the input comes from a Bluetooth headset, which macOS
    /// drops into hands-free mode for as long as its microphone is open.
    private(set) var inputIsBluetooth = false
    /// True while a jack is plugged into the Mac's input and the Mac has no
    /// input the machine can use.
    private(set) var inputMissing = false

    /// What is plugged into the input jacks.
    var patch = JackPatch() {
        didSet {
            guard patch != oldValue else { return }
            context.patch.post(patch)
            guard started else { return }
            if patch.usesDeviceInput && !inputRunning {
                Task { await bringUpInput() }
            } else if oldValue.usesDeviceInput && !patch.usesDeviceInput && inputAuthorised {
                // Nothing is plugged into the Mac's input any more: let go of
                // the microphone (a Bluetooth headset gets its good sound back).
                // Also when the input never came up: the engine may be holding
                // the device all the same, or be stopped because of it.
                rebuildEngine()
                configure()
            }
        }
    }

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var source: AVAudioSourceNode?
    @ObservationIgnored private var sink: AVAudioSinkNode?
    @ObservationIgnored private var inputRunning = false
    @ObservationIgnored private var inputAuthorised = false
    @ObservationIgnored private var started = false
    /// The part of the round trip that is fixed by the hardware: both
    /// devices' reported latencies and the output buffer, in output frames.
    @ObservationIgnored private var hardwareRoundTrip = 0
    @ObservationIgnored private var estimatedRoundTrip = 0
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private let log = Logger(subsystem: "se.mickekring.X2026", category: "audio")

    // The engine is left to pick and manage its own devices: it follows the
    // input and output chosen in macOS's Sound settings. With those on
    // different devices (which is nearly always: even the built-in microphone
    // and speakers are two) it runs them through a private aggregate device,
    // and announces a configuration change when it sets that up.
    //
    // Two things learned the hard way:
    // - Re-asserting a device on every change makes the engine announce
    //   another change, for ever, with no audio in between. Nothing is ever
    //   set twice on the same engine.
    // - Input and output share one I/O unit, so they cannot be pointed at two
    //   different devices by hand (error -10851). One device for both is
    //   fine, which is all the loopback self-test needs.
    @ObservationIgnored private var pinnedDevice: AudioDeviceID?
    @ObservationIgnored private var pinnedInput: AudioDeviceID?
    @ObservationIgnored private var bufferRequested: Set<AudioDeviceID> = []
    @ObservationIgnored private var pendingRestart: Task<Void, Never>?
    @ObservationIgnored private var recentRestarts: [ContinuousClock.Instant] = []
    /// True while the fuse has blown and the hardware is being left alone.
    @ObservationIgnored private var resting = false
    /// How long to wait before trying again after audio would not start.
    @ObservationIgnored private var retryDelay = AudioHost.firstRetry
    private static let firstRetry: Duration = .seconds(2)
    /// How many times the engine has been (re)started, for the self-tests.
    @ObservationIgnored private(set) var restartCount = 0

    /// One device to use for both directions instead of the system's choice
    /// (the loopback self-test sets this). Set before `start()`.
    @ObservationIgnored var loopbackDevice: AudioDeviceID?

    /// The real devices sound goes out of and comes in on, for names and
    /// latencies (the engine's own device may be an aggregate of the two).
    private var outputInUse: AudioDeviceID? { loopbackDevice ?? AudioHardware.defaultDevice(input: false) }
    private var inputInUse: AudioDeviceID? { loopbackDevice ?? AudioHardware.defaultDevice(input: true) }

    private var wantsInput: Bool { patch.usesDeviceInput && inputAuthorised }

    /// I/O buffer we ask the hardware for. Small, so playing through the machine feels live.
    static let preferredBufferFrames: UInt32 = 128

    init(core: MachineCore) {
        self.core = core
        context = RenderContext(core: core)
        refreshInputChannels()
    }

    // MARK: - Lifecycle

    /// Powers the machine up.
    func start() {
        started = true
        inputAuthorised = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
            ) { [weak self] note in
                let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, sender == ObjectIdentifier(self.engine) else { return }
                    self.hardwareChanged()
                }
            }
        }
        configure()
        // A jack left plugged into the Mac's input from last time: ask for the
        // microphone if that was never settled, and note a refusal so that
        // the silent jack can be explained.
        if patch.usesDeviceInput && !inputAuthorised {
            Task { await bringUpInput() }
        }
    }

    func stop() {
        pendingRestart?.cancel()
        pendingRestart = nil
        resting = false
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
        inputAuthorised = true
        refreshInputChannels()
        configure()
    }

    func refreshInputChannels() {
        guard let device = inputInUse else {
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

    /// The engine says its hardware changed (a device came or went, the
    /// sample rate moved, a headset switched mode). These come in bursts, so
    /// wait for the burst to pass and then start again once.
    private func hardwareChanged() {
        guard !resting else { return }
        pendingRestart?.cancel()
        pendingRestart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.restartAfterChange()
        }
    }

    private func restartAfterChange() {
        // A fuse of our own: if restarting keeps provoking another change,
        // stop chasing it rather than spin for ever with no sound at all.
        let now = ContinuousClock.now
        recentRestarts = recentRestarts.filter { now - $0 < .seconds(6) } + [now]
        guard recentRestarts.count <= 5 else {
            log.error("Audio hardware will not settle; giving it a rest")
            engine.stop()
            isRunning = false
            problem = "The audio hardware kept changing under the machine, so it has stopped trying for a moment."
            recentRestarts = []
            resting = true
            pendingRestart = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self else { return }
                self.rebuildEngine()
                self.configure()
            }
            return
        }
        log.info("Audio hardware changed; restarting")
        refreshInputChannels()
        configure()
    }

    /// Audio that would not start is tried again by the clock, a little less
    /// eagerly each time. The cause (a headset half way through changing
    /// mode, no device plugged in) often clears without the engine ever
    /// saying so, and this cannot feed the change-restart loop: nothing
    /// here answers a notification.
    private func retryLater() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(16))
        pendingRestart = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.rebuildEngine()
            self.configure()
        }
    }

    /// Throws the engine away and starts with a new one that knows nothing
    /// of the devices the old one was using.
    private func rebuildEngine() {
        pendingRestart?.cancel()
        engine.stop()
        if let source { engine.detach(source) }
        if let sink { engine.detach(sink) }
        source = nil
        sink = nil
        inputRunning = false
        isRunning = false
        engine = AVAudioEngine()
        pinnedDevice = nil
        pinnedInput = nil
        bufferRequested = []
    }

    /// Asks a device for a small buffer, once. A driver that says no (or
    /// answers with a change notification) is not asked again.
    private func requestSmallBuffer(on device: AudioDeviceID) {
        guard bufferRequested.insert(device).inserted else { return }
        guard AudioHardware.bufferFrames(of: device) != Int(Self.preferredBufferFrames) else { return }
        AudioHardware.requestBuffer(frames: Self.preferredBufferFrames, on: device)
    }

    // MARK: - Engine graph

    /// Replaces the first estimate of the round trip with one that uses the
    /// measured age of the input in the ring, once audio has been flowing
    /// for a moment. Call now and then from the main thread.
    func refineLatency() {
        guard inputRunning else { return }
        let micros = context.measuredLoop.load(ordering: .relaxed)
        guard micros > 0 else { return }
        let measured = Int((Double(micros) / 1_000_000 * sampleRate).rounded()) + hardwareRoundTrip
        if abs(measured - roundTripLatency) >= 3 {
            roundTripLatency = measured
        }
    }

    /// How the round trip was arrived at, for the self-tests and Settings.
    var latencyReport: String {
        let micros = context.measuredLoop.load(ordering: .relaxed)
        return "first estimate \(estimatedRoundTrip) frames; input is \(String(format: "%.2f", Double(micros) / 1000)) ms old when used, plus \(hardwareRoundTrip) frames of hardware"
    }

    private func configure() {
        // Whatever restart was waiting is overtaken by this one.
        pendingRestart?.cancel()
        pendingRestart = nil
        resting = false
        engine.stop()
        if let source { engine.detach(source) }
        if let sink { engine.detach(sink) }
        source = nil
        sink = nil
        inputRunning = false
        problem = nil
        // With the engine stopped nothing is reading or writing the ring:
        // empty it, so a jack left patched never loops the last scraps of input.
        context.ring.configure(channels: 0, inputRate: 48_000, outputRate: 48_000, targetFill: 256)
        context.forgetLoop()
        hardwareRoundTrip = 0
        restartCount += 1
        var stage = "choosing the output device"

        do {
            if let loopbackDevice, pinnedDevice != loopbackDevice {
                try engine.outputNode.withAUAudioUnit { try $0.setDeviceID(loopbackDevice) }
                pinnedDevice = loopbackDevice
            }
            // What the engine is actually driving: the device itself, or its
            // private aggregate of the input and output devices.
            let engineOutput = engine.outputNode.withAUAudioUnit { $0.deviceID }
            let realOutput = outputInUse ?? engineOutput
            requestSmallBuffer(on: engineOutput)
            outputDeviceName = AudioHardware.name(of: realOutput)

            let hardwareFormat = engine.outputNode.inputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
                throw NoDevice(what: "The Mac has no audio output to play through.")
            }
            let rate = hardwareFormat.sampleRate
            sampleRate = rate
            core.prepare(sampleRate: rate)
            context.rhythm.prepare(sampleRate: rate)
            if context.masterRecorder.isRecording && context.masterRecorder.sampleRate != rate {
                // A file cannot change sample rate half way: close the take.
                context.masterRecorder.end()
            }
            context.masterRecorder.sampleRate = rate

            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
                throw CocoaError(.featureUnsupported)
            }
            stage = "connecting the machine to the output"
            let source = context.makeSourceNode(format: format)
            engine.attach(source)
            try engine.connectNode(source, to: engine.mainMixerNode, format: format)
            self.source = source

            var inputLatency = 0
            var bluetooth = false
            if wantsInput, let realInput = inputInUse {
                stage = "opening the input device"
                if let loopbackDevice, pinnedInput != loopbackDevice {
                    // The loopback test listens to the device it plays into,
                    // not to whatever microphone the Mac has chosen.
                    try engine.inputNode.withAUAudioUnit { try $0.setDeviceID(loopbackDevice) }
                    pinnedInput = loopbackDevice
                }
                let engineInput = engine.inputNode.withAUAudioUnit { $0.deviceID }
                requestSmallBuffer(on: engineInput)
                let inputFormat = engine.inputNode.outputFormat(forBus: 0)
                if inputFormat.channelCount > 0 && inputFormat.sampleRate > 0 {
                    let inputBuffer = AudioHardware.bufferFrames(of: engineInput)
                    let outputBuffer = AudioHardware.bufferFrames(of: engineOutput)
                    // Enough in hand to ride out both devices delivering in lumps.
                    let scale = rate / inputFormat.sampleRate
                    let target = Int(Double(inputBuffer) * 1.25) + Int(Double(outputBuffer) / scale * 0.5) + 48
                    context.ring.configure(
                        channels: Int(inputFormat.channelCount),
                        inputRate: inputFormat.sampleRate, outputRate: rate, targetFill: target)
                    stage = "connecting the input"
                    let sink = context.makeSinkNode()
                    engine.attach(sink)
                    try engine.connectNode(engine.inputNode, to: sink, format: inputFormat)
                    self.sink = sink
                    inputRunning = true
                    bluetooth = AudioHardware.isBluetooth(realInput)
                    // Latencies are the real devices' own; an aggregate
                    // standing in for them reports little or nothing.
                    let inputHardware = AudioHardware.hardwareLatency(of: realInput, input: true)
                    let outputHardware = AudioHardware.hardwareLatency(of: realOutput, input: false)
                    inputLatency = Int((Double(inputHardware + inputBuffer / 2 + target) * scale).rounded())
                    hardwareRoundTrip = Int((Double(inputHardware) * scale).rounded()) + outputHardware + outputBuffer
                } else {
                    log.notice("No usable input device")
                }
            }
            inputIsBluetooth = bluetooth
            inputMissing = wantsInput && !inputRunning

            let outputLatency = AudioHardware.hardwareLatency(of: realOutput, input: false)
                + AudioHardware.bufferFrames(of: engineOutput)
            roundTripLatency = inputRunning ? inputLatency + outputLatency : 0
            estimatedRoundTrip = roundTripLatency

            stage = "starting the audio engine (\(Int(rate)) Hz)"
            engine.prepare()
            try engine.start()
            isRunning = true
            retryDelay = Self.firstRetry
            log.info("Audio running at \(rate, format: .fixed(precision: 0)) Hz, round trip \(self.roundTripLatency) frames, input \(self.inputRunning)")
        } catch {
            isRunning = false
            inputMissing = false
            problem = "Audio would not start while \(stage): \(error.localizedDescription)"
            log.error("Could not start audio while \(stage, privacy: .public): \(error)")
            retryLater()
        }
    }

    private struct NoDevice: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }
}
