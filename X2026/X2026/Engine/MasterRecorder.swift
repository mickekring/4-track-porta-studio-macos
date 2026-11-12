import AVFoundation
import OSLog
import Synchronization

/// The two-track machine you mix down to.
///
/// It is wired to LINE OUT and records in real time, exactly as the manual's
/// mixdown procedure has it: start the master recorder, press PLAY, ride the
/// faders, and fade out with MASTER. What you get is a WAV file.
nonisolated final class MasterRecorder: @unchecked Sendable {
    /// Samples (not frames) the audio thread can queue before the writer catches up.
    private static let capacity = 1 << 19
    private static let mask = capacity - 1

    var sampleRate = 48_000.0

    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let rolling = Atomic<Bool>(false)
    private let peakL = Atomic<UInt32>(0)
    private let peakR = Atomic<UInt32>(0)
    private let framesCaptured = Atomic<Int>(0)
    private let overruns = Atomic<Int>(0)

    private let queue = DispatchQueue(label: "se.mickekring.X2026.master-recorder", qos: .utility)
    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private var url: URL?
    private let log = Logger(subsystem: "se.mickekring.X2026", category: "master")

    init() {
        storage = .allocate(capacity: Self.capacity)
        storage.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        timer?.cancel()
        storage.deallocate()
    }

    // MARK: - Audio thread

    /// Takes LINE OUT. Always meters; queues for disk only while recording.
    func capture(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        var maxL: Float = 0
        var maxR: Float = 0
        for frame in 0..<frames {
            maxL = max(maxL, abs(left[frame]))
            maxR = max(maxR, abs(right[frame]))
        }
        // Peak-hold with decay, read by the meters on the main thread.
        let oldL = Float(bitPattern: peakL.load(ordering: .relaxed)) * 0.93
        let oldR = Float(bitPattern: peakR.load(ordering: .relaxed)) * 0.93
        peakL.store(max(maxL, oldL).bitPattern, ordering: .relaxed)
        peakR.store(max(maxR, oldR).bitPattern, ordering: .relaxed)

        guard rolling.load(ordering: .relaxed) else { return }
        let write = tail.load(ordering: .relaxed)
        let read = head.load(ordering: .acquiring)
        guard write - read + frames * 2 <= Self.capacity else {
            overruns.wrappingAdd(1, ordering: .relaxed)
            return
        }
        for frame in 0..<frames {
            storage[(write + frame * 2) & Self.mask] = left[frame]
            storage[(write + frame * 2 + 1) & Self.mask] = right[frame]
        }
        tail.store(write + frames * 2, ordering: .releasing)
        framesCaptured.wrappingAdd(frames, ordering: .relaxed)
    }

    // MARK: - Front panel

    var isRecording: Bool { rolling.load(ordering: .relaxed) }

    /// Seconds recorded so far.
    var elapsed: Double { Double(framesCaptured.load(ordering: .relaxed)) / sampleRate }

    /// Current peak levels relative to the 0 mark.
    var levels: (left: Float, right: Float) {
        (Float(bitPattern: peakL.load(ordering: .relaxed)) / Level.reference,
         Float(bitPattern: peakR.load(ordering: .relaxed)) / Level.reference)
    }

    /// Starts recording to a new 24-bit WAV at `url`.
    func begin(url: URL) throws {
        guard !isRecording else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        queue.sync {
            self.file = file
            self.url = url
        }
        head.store(tail.load(ordering: .relaxed), ordering: .relaxed)
        framesCaptured.store(0, ordering: .relaxed)
        overruns.store(0, ordering: .relaxed)
        rolling.store(true, ordering: .relaxed)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(120))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Stops and returns the finished file.
    @discardableResult
    func end() -> URL? {
        guard isRecording else { return nil }
        rolling.store(false, ordering: .relaxed)
        timer?.cancel()
        timer = nil
        return queue.sync {
            drain()
            let finished = url
            file = nil
            url = nil
            let dropped = overruns.load(ordering: .relaxed)
            if dropped > 0 { log.error("Master recorder dropped \(dropped) buffers") }
            return finished
        }
    }

    /// Writer queue: moves whatever has been captured onto disk.
    private func drain() {
        guard let file else { return }
        let read = head.load(ordering: .relaxed)
        let write = tail.load(ordering: .acquiring)
        let frames = (write - read) / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return }
        // Tape levels sit around -12 dBFS; a master should not, so lift the
        // 0 mark to about -6 dBFS on the way to the file.
        let lift: Float = 2
        for frame in 0..<frames {
            channels[0][frame] = max(-1, min(1, storage[(read + frame * 2) & Self.mask] * lift))
            channels[1][frame] = max(-1, min(1, storage[(read + frame * 2 + 1) & Self.mask] * lift))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        do {
            try file.write(from: buffer)
        } catch {
            log.error("Master recorder could not write: \(error)")
        }
        head.store(read + frames * 2, ordering: .releasing)
    }
}
