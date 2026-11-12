import AppKit
import Observation
import OSLog

/// The five piano keys under the cassette well.
enum TransportKey: Int, CaseIterable, Sendable {
    case record
    case play
    case rewind
    case fastForward
    case stop

    var title: String {
        switch self {
        case .record: "RECORD"
        case .play: "PLAY"
        case .rewind: "REWIND"
        case .fastForward: "F FWD"
        case .stop: "STOP"
        }
    }
}

/// The X-2026 as you sit in front of it: its panel, its keys, its cassette
/// well, and the audio hardware behind it.
///
/// This is the main-thread half of the machine. It never touches audio; it
/// posts control frames to `core` and reads telemetry back.
@Observable
final class Machine {
    // MARK: Parts

    @ObservationIgnored let core: MachineCore
    let audio: AudioHost
    let library: TapeLibrary

    // MARK: Panel

    /// Every knob, fader and switch.
    var panel: Panel {
        didSet {
            guard panel != oldValue else { return }
            soundPanelChange(from: oldValue)
            explainFeedback(from: oldValue)
            post()
            saveSoon()
        }
    }

    /// The effects box on the AUX loop.
    var effect: AuxEffect.Settings {
        didSet {
            guard effect != oldValue else { return }
            post()
            saveSoon()
        }
    }

    /// The rhythm box.
    var rhythm: RhythmBox.Settings {
        didSet {
            guard rhythm != oldValue else { return }
            audio.context.rhythm.settings.post(rhythm)
            saveSoon()
        }
    }

    /// Loudness of the keys, motors and lid, 0…1.
    var mechanicalLevel: Double {
        didSet {
            post()
            saveSoon()
        }
    }

    /// Fine adjustment of overdub timing in milliseconds, on top of what the
    /// audio hardware reports about itself.
    var latencyTrim: Double {
        didSet {
            post()
            saveSoon()
        }
    }

    // MARK: Transport

    /// Keys currently latched down.
    private(set) var keysDown: Set<TransportKey> = []
    /// A key being held by the mouse right now (STOP never latches).
    private(set) var keyHeld: TransportKey?
    /// The foot switch has punched in.
    private(set) var punchedIn = false
    private(set) var footSwitchConnected: Bool

    // MARK: Cassette well

    /// The cassette on the spindles, if any.
    private(set) var loaded: Cassette?
    var lidOpen: Bool {
        didSet {
            guard lidOpen != oldValue else { return }
            core.sounds.push(lidOpen ? .lidOpen : .lidClose)
            saveSoon()
        }
    }

    // MARK: Live state

    /// Bumped whenever the counter jumps without the tape moving (reset, tape change).
    private(set) var counterRevision = 0
    private(set) var lamps: [TrackLamp] = Array(repeating: .tape, count: 4)
    /// How many segments of each LED column are lit (0…7). Published only
    /// when it changes, so a silent machine costs nothing to display.
    private(set) var meterSegments = [0, 0, 0, 0]
    /// The master recorder's display: lit segments (0…12) left and right,
    /// whether it is rolling, and for how many whole seconds.
    private(set) var masterSegments = [0, 0]
    private(set) var masterRecording = false
    private(set) var masterSeconds = 0
    private(set) var isRecording = false
    /// True while tape is moving in any direction.
    private(set) var isMoving = false
    /// True when the disk the tapes live on has no room left to record.
    private(set) var diskFull = false
    /// Something the owner should be told, shown once.
    var notice: String?

    // MARK: Private

    /// Level in dB at which each meter segment lights, top to bottom.
    nonisolated static let meterMarks: [Float] = [6, 3, 0, -3, -6, -10, -20]
    /// The master recorder's twelve segments, bottom to top.
    nonisolated static let masterMeterMarks: [Float] = (0..<12).map { Float($0) * 3 - 27 }

    /// Counter digits per revolution of the take-up hub. The counter is driven
    /// by a belt off that hub, so it counts turns, not time.
    static let counterDigitsPerTurn = 0.6

    @ObservationIgnored private var counterAnchorValue: Double
    @ObservationIgnored private var counterAnchorTurns = 0.0
    @ObservationIgnored private var geometry: ReelGeometry?
    @ObservationIgnored private var medium: TapeMedium?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var seenAutoStops: UInt32 = 0
    @ObservationIgnored private var seenLatency = -1
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var lastReport = Telemetry()
    @ObservationIgnored private var explainedFeedback = false
    /// Room a take needs before RECORD is allowed: about five minutes of four-track.
    private static let roomToRecord: Int64 = 150_000_000
    @ObservationIgnored private let log = Logger(subsystem: "se.mickekring.X2026", category: "machine")
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let remembers: Bool
    @ObservationIgnored private let housekeeping = DispatchQueue(label: "se.mickekring.X2026.tape-housekeeping", qos: .utility)

    private static let snapshotKey = "machine.snapshot.v1"
    /// Set once the owner has been told what the REMIX howl is. Once is enough.
    private static let explainedFeedbackKey = "machine.explained.feedback"

    // MARK: - Lifetime

    /// - Parameter remembers: false for a machine that reads its saved state
    ///   but never writes it back (test runs, previews, errands).
    init(library: TapeLibrary = TapeLibrary(), defaults: UserDefaults = .standard, remembers: Bool = true) {
        self.library = library
        self.defaults = defaults
        self.remembers = remembers
        core = MachineCore()
        audio = AudioHost(core: core)

        let snapshot = Snapshot.load(from: defaults)
        var restored = snapshot?.panel ?? .readyToPlay
        if snapshot != nil, (snapshot?.factoryRevision ?? 1) < Snapshot.currentRevision {
            // Panels saved before the machine shipped set up for mixdown were
            // in NORM, where MASTER and EQ do nothing to the tape. Once only.
            restored.remix = true
        }
        panel = restored
        effect = snapshot?.effect ?? AuxEffect.Settings()
        var restoredRhythm = snapshot?.rhythm ?? RhythmBox.Settings()
        restoredRhythm.running = false
        rhythm = restoredRhythm
        mechanicalLevel = snapshot?.mechanicalLevel ?? 0.6
        latencyTrim = snapshot?.latencyTrim ?? 0
        lidOpen = snapshot?.lidOpen ?? false
        footSwitchConnected = snapshot?.footSwitchConnected ?? false
        counterAnchorValue = snapshot?.counter ?? 0
        audio.patch = snapshot?.patch ?? JackPatch()
        audio.context.rhythm.settings.post(rhythm)

        // A cassette left in the machine is still there next time.
        if let id = snapshot?.loadedCassette, let cassette = library.cassette(withID: id) {
            do {
                try thread(cassette)
            } catch {
                log.error("Could not re-thread cassette: \(error)")
            }
        }
        explainedFeedback = remembers && defaults.bool(forKey: Self.explainedFeedbackKey)
        checkDisk()
        post()
    }

    /// Switches the machine on: starts audio and the telemetry poll.
    func powerOn() {
        audio.start()
        post()
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// Switches off, leaving everything as it was.
    func powerOff() {
        poll?.invalidate()
        poll = nil
        releaseKeys(sound: nil)
        rememberTapePosition()
        // A mixdown still rolling is closed properly rather than cut off.
        audio.context.masterRecorder.end()
        audio.stop()
        medium?.flush(wait: true)
        save()
    }

    // MARK: - Control frames

    private var motion: TapeDeck.Motion {
        if keysDown.contains(.play) { return .play }
        if keysDown.contains(.rewind) { return .rewind }
        if keysDown.contains(.fastForward) { return .fastForward }
        return .stop
    }

    private func post() {
        var frame = ControlFrame()
        frame.panel = panel
        frame.effect = effect
        frame.mechanicalLevel = Float(mechanicalLevel)
        frame.transport = TransportRequest(
            motion: motion,
            recordKey: keysDown.contains(.record),
            punch: punchedIn)
        let trim = Int((latencyTrim / 1000 * audio.sampleRate).rounded())
        frame.recordLatency = max(0, audio.roundTripLatency + trim)
        // Sources inside the Mac make no trip through its audio hardware.
        for jack in 0..<JackPatch.count where audio.patch[jack] == .rhythmBox {
            frame.internalJacks |= 1 << UInt8(jack)
        }
        frame.recordInhibit = diskFull
        core.controls.post(frame)
    }

    /// Says in words what the howl is, the first time a track is armed
    /// straight into the REMIX loop. The loop itself is left alone: it is
    /// what the hardware does.
    private func explainFeedback(from old: Panel) {
        guard !explainedFeedback, old.trackInFeedbackLoop == nil, let track = panel.trackInFeedbackLoop else { return }
        explainedFeedback = true
        if remembers { defaults.set(true, forKey: Self.explainedFeedbackKey) }
        notice = "Track \(track + 1) is armed while SUB GAIN \(track + 3) is turned toward TRK \(track + 1) and the switch is on REMIX. That sends the track straight back into itself: the howl the manual warns about. Turn SUB GAIN \(track + 3) to 0, or switch to NORM while you record."
    }

    private func soundPanelChange(from old: Panel) {
        if panel.noiseReduction != old.noiseReduction || panel.monitor != old.monitor
            || panel.remix != old.remix || panel.recordL != old.recordL || panel.recordR != old.recordR {
            core.sounds.push(.switchLarge)
        }
        if panel.micGain1 != old.micGain1 || panel.micGain2 != old.micGain2
            || panel.metersShowMixer != old.metersShowMixer {
            core.sounds.push(.switchSmall)
        }
    }

    // MARK: - Transport keys

    /// A finger comes down on a key.
    func press(_ key: TransportKey) {
        keyHeld = key
        if key == .play || key == .record {
            // Have the tape under the head in memory before it starts to move.
            prefetch(around: core.tapePosition)
        }
        if key == .record {
            checkDisk()
            if diskFull && loaded != nil {
                notice = "The disk is nearly full, so the X-2026 will play but not record. Free some space and press RECORD again."
            }
        }
        switch key {
        case .stop:
            if keysDown.isEmpty {
                core.sounds.push(.stopKey)
            } else {
                releaseKeys(sound: .keyRelease)
            }
        case .play:
            guard !keysDown.contains(.play) else { break }
            if !keysDown.isEmpty { releaseKeys(sound: .keyRelease) }
            keysDown = [.play]
            core.sounds.push(.keyDown)
        case .record:
            // RECORD alone is enough: it takes PLAY down with it. Pressed
            // while already playing, it punches in.
            guard !keysDown.contains(.record) else { break }
            if keysDown.contains(.rewind) || keysDown.contains(.fastForward) {
                releaseKeys(sound: .keyRelease)
            }
            keysDown = [.record, .play]
            core.sounds.push(.keyDown)
        case .rewind, .fastForward:
            guard !keysDown.contains(key) else { break }
            if !keysDown.isEmpty { releaseKeys(sound: .keyRelease) }
            keysDown = [key]
            core.sounds.push(.keyDown)
        }
        post()
    }

    /// The finger lifts.
    func release(_ key: TransportKey) {
        if keyHeld == key { keyHeld = nil }
    }

    /// Lets every latched key spring back up.
    private func releaseKeys(sound: MechanicalSound?) {
        guard !keysDown.isEmpty || punchedIn else { return }
        let wasRecording = keysDown.contains(.record) || punchedIn
        keysDown = []
        punchedIn = false
        if let sound { core.sounds.push(sound) }
        post()
        rememberTapePosition()
        if wasRecording { flushTape() }
    }

    /// Steps on the foot switch: punches in and out while the tape plays.
    func stepOnFootSwitch() {
        guard footSwitchConnected else { return }
        core.sounds.push(.footSwitch)
        guard keysDown == [.play] else { return }
        punchedIn.toggle()
        post()
        if !punchedIn { flushTape() }
    }

    func setFootSwitch(connected: Bool) {
        guard connected != footSwitchConnected else { return }
        footSwitchConnected = connected
        core.sounds.push(.plug)
        if !connected && punchedIn {
            punchedIn = false
            post()
        }
        saveSoon()
    }

    // MARK: - Counter

    /// What the counter reads with the tape at `position` (in frames).
    func counterValue(at position: Double) -> Double {
        guard let geometry else { return counterAnchorValue }
        let turns = geometry.takeUpTurns(at: position / CassetteStandard.framesPerMeter)
        return counterAnchorValue + (turns - counterAnchorTurns) * Self.counterDigitsPerTurn
    }

    private func anchorCounter(to value: Double, position: Double) {
        counterRevision += 1
        counterAnchorValue = value
        counterAnchorTurns = geometry?.takeUpTurns(at: position / CassetteStandard.framesPerMeter) ?? 0
    }

    /// The button beside the counter.
    func resetCounter() {
        core.sounds.push(.counterReset)
        anchorCounter(to: 0, position: core.tapePosition)
        saveSoon()
    }

    // MARK: - Cassettes

    /// Puts a cassette on the spindles. The lid must be open and the well empty.
    func insert(_ cassette: Cassette) throws {
        guard loaded == nil else { return }
        try thread(cassette)
        core.sounds.push(.cassetteIn)
        saveSoon()
    }

    private func thread(_ cassette: Cassette) throws {
        let medium = try TapeMedium(
            url: library.oxideURL(for: cassette),
            frameCount: cassette.stock.frameCount,
            flipped: cassette.flipped)
        let reading = currentCounter
        self.medium = medium
        geometry = ReelGeometry(stock: cassette.stock)
        core.insert(
            medium: medium, stock: cassette.stock,
            position: cassette.position, recordProtected: cassette.recordProtected)
        // The counter belongs to the machine, not the tape: it keeps showing
        // whatever it showed, and counts on from there.
        anchorCounter(to: reading, position: cassette.position)
        loaded = cassette
        prefetch(around: cassette.position)
    }

    /// Lifts the cassette out of the well and returns it, its tape position updated.
    @discardableResult
    func removeCassette() -> Cassette? {
        guard var cassette = loaded else { return nil }
        releaseKeys(sound: .keyRelease)
        let reading = currentCounter
        cassette.position = core.eject()
        library.update(cassette)
        // Letting go of the oxide syncs it to disk, which can take a moment:
        // do that away from the main thread.
        if let finished = medium {
            medium = nil
            housekeeping.async { withExtendedLifetime(finished) {} }
        }
        geometry = nil
        counterAnchorValue = reading
        counterAnchorTurns = 0
        counterRevision += 1
        loaded = nil
        core.sounds.push(.cassetteOut)
        saveSoon()
        return cassette
    }

    /// Applies label edits to the cassette in the well.
    func relabel(_ cassette: Cassette) {
        library.update(cassette)
        if loaded?.id == cassette.id {
            var updated = cassette
            updated.position = core.tapePosition
            loaded = updated
        }
    }

    private var currentCounter: Double {
        counterValue(at: geometry == nil ? 0 : core.tapePosition)
    }

    private func rememberTapePosition() {
        guard var cassette = loaded else { return }
        cassette.position = core.tapePosition
        loaded = cassette
        library.update(cassette)
    }

    /// Asks for what was just recorded to be written out to disk — a moment
    /// later, once the heads are off the tape, so the audio thread is never
    /// touching a page that is being written back.
    private func flushTape() {
        guard let medium else { return }
        housekeeping.asyncAfter(deadline: .now() + 1.5) { medium.flush() }
    }

    private func checkDisk() {
        let values = try? library.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? .max
        let full = free < Self.roomToRecord
        if full != diskFull {
            diskFull = full
            post()
        }
    }

    /// Warms the stretch of tape around the head so the audio thread never
    /// has to wait for the disk.
    private func prefetch(around position: Double) {
        guard let medium, let cassette = loaded else { return }
        let leader = cassette.stock.leaderLength * CassetteStandard.framesPerMeter
        let frame = Int(position - leader)
        let ahead = Int(CassetteStandard.sampleRate * 6)
        let behind = Int(CassetteStandard.sampleRate * 2)
        housekeeping.async { medium.prefetch(frames: (frame - behind)..<(frame + ahead)) }
    }

    #if DEBUG
    /// Reads oxide straight off the loaded cassette, for the self-tests.
    func debugReadTape(track: Int, from frame: Int, count: Int) -> [Float] {
        guard let medium else { return [] }
        return (frame..<(frame + count)).map { medium.read(track: track, frame: $0) }
    }
    #endif

    // MARK: - Telemetry

    /// Latest report from the audio thread. If a read happens to collide
    /// with the audio thread writing, the previous report is good enough.
    var telemetry: Telemetry {
        if let fresh = core.telemetry.read() { lastReport = fresh }
        return lastReport
    }

    private func tick() {
        guard let report = core.telemetry.read() else { return }
        lastReport = report
        ticks += 1
        audio.refineLatency()
        if ticks % 60 == 0 { checkDisk() }

        if report.autoStopCount != seenAutoStops {
            seenAutoStops = report.autoStopCount
            releaseKeys(sound: .autoStop)
        }
        if audio.roundTripLatency != seenLatency {
            seenLatency = audio.roundTripLatency
            post()
        }

        let fresh = (0..<4).map { TrackLamp(rawValue: report.lamps[$0]) ?? .tape }
        if fresh != lamps { lamps = fresh }

        // Meters: work out what the LEDs show and publish only a change. A
        // segment comes on a little before its mark, as ladder comparators do.
        let segments = (0..<4).map { column in
            let level = Level.decibels(report.meters[column])
            return Self.meterMarks.count { level >= $0 - 1.2 }
        }
        if segments != meterSegments { meterSegments = segments }

        let recorder = audio.context.masterRecorder
        let levels = recorder.levels
        let master = [levels.left, levels.right].map { level in
            Self.masterMeterMarks.count { Level.decibels(level) >= $0 }
        }
        if master != masterSegments { masterSegments = master }
        let rolling = recorder.isRecording
        if rolling != masterRecording { masterRecording = rolling }
        let seconds = rolling ? Int(recorder.elapsed) : 0
        if seconds != masterSeconds { masterSeconds = seconds }
        if report.isRecording != isRecording { isRecording = report.isRecording }
        let moving = report.capstan > 0.01 || abs(report.windSpeed) > 0.01
        let justStopped = isMoving && !moving
        if moving != isMoving { isMoving = moving }

        // Keep the page cache ahead of the head: twice a second while the
        // tape moves, and once more where it comes to rest after a wind.
        if (moving && ticks % 15 == 0) || justStopped { prefetch(around: report.position) }
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        /// Bumped when the factory set-up changes in a way old saves should follow.
        static let currentRevision = 2

        var factoryRevision: Int?
        var panel: Panel
        var effect: AuxEffect.Settings
        var rhythm: RhythmBox.Settings
        var patch: JackPatch
        var mechanicalLevel: Double
        var latencyTrim: Double
        var lidOpen: Bool
        var footSwitchConnected: Bool
        var counter: Double
        var loadedCassette: UUID?

        static func load(from defaults: UserDefaults) -> Snapshot? {
            guard let data = defaults.data(forKey: Machine.snapshotKey) else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }
    }

    /// Call when the jack patch changes, so it is remembered.
    func patchChanged() {
        core.sounds.push(.plug)
        saveSoon()
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard remembers else { return }
        let snapshot = Snapshot(
            factoryRevision: Snapshot.currentRevision,
            panel: panel, effect: effect, rhythm: rhythm, patch: audio.patch,
            mechanicalLevel: mechanicalLevel, latencyTrim: latencyTrim,
            lidOpen: lidOpen, footSwitchConnected: footSwitchConnected,
            counter: currentCounter.truncatingRemainder(dividingBy: 1000),
            loadedCassette: loaded?.id)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.snapshotKey)
        }
    }
}
