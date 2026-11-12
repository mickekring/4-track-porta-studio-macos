import Foundation
import os

/// The machine's electronics and mechanism, safely shared between the audio
/// thread (which runs it) and the main thread (which works its controls).
///
/// - Knob positions go in through `controls`, a wait-free mailbox.
/// - Meter levels and tape position come out through `telemetry`.
/// - Clicks and clunks are queued on `sounds`.
/// - Changing the cassette takes a lock the audio thread only ever *tries*:
///   if a tape is being swapped it plays one buffer of silence rather than wait.
nonisolated final class MachineCore: @unchecked Sendable {
    let controls = Mailbox(ControlFrame())
    let telemetry = Mailbox(Telemetry())
    let sounds = EventQueue<MechanicalSound>(capacity: 64, filler: .keyDown)

    private let dsp: UnsafeMutablePointer<MachineDSP>
    private let current: UnsafeMutablePointer<ControlFrame>
    private let lock: os_unfair_lock_t

    static let maximumFrames = MachineDSP.maximumFrames

    init() {
        dsp = .allocate(capacity: 1)
        dsp.initialize(to: MachineDSP())
        current = .allocate(capacity: 1)
        current.initialize(to: ControlFrame())
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        dsp.pointee.tearDown()
        dsp.deinitialize(count: 1)
        dsp.deallocate()
        current.deinitialize(count: 1)
        current.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private func locked<Result>(_ body: (inout MachineDSP) -> Result) -> Result {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body(&dsp.pointee)
    }

    // MARK: - Main thread

    var sampleRate: Double { locked { $0.sampleRate } }

    /// Re-tunes everything for the audio device's sample rate.
    func prepare(sampleRate: Double) {
        locked { $0.prepare(sampleRate: sampleRate) }
    }

    var calibration: TapeDeck.Calibration {
        get { locked { $0.calibration } }
        set { locked { $0.calibration = newValue } }
    }

    /// Drops a cassette onto the spindles.
    func insert(medium: TapeMedium, stock: TapeStock, position: Double, recordProtected: Bool) {
        locked {
            $0.load(medium: medium, stock: stock, position: position, recordProtected: recordProtected)
            // Holding the lock makes us the only writer for a moment, so the
            // main thread may report on the audio thread's behalf.
            telemetry.post($0.idleReport())
        }
    }

    /// Lifts the cassette out. Returns where its tape was left.
    @discardableResult
    func eject() -> Double {
        locked {
            let position = $0.unload()
            telemetry.post($0.idleReport())
            return position
        }
    }

    /// Where the tape is right now, without waiting for the next audio block.
    var tapePosition: Double { locked { $0.deck.position } }

    // MARK: - Audio thread

    /// Sample `frame` of input jack `jack` (0…5) for the coming `render` call.
    /// Fill these, then render.
    var jacks: UnsafeMutablePointer<Float> { dsp.pointee.jacks }

    /// LINE OUT from the last `render`: left at 0, right at `maximumFrames`.
    var lineOut: UnsafeMutablePointer<Float> { dsp.pointee.lineOut }

    /// Runs the machine for up to `maximumFrames` samples.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard os_unfair_lock_trylock(lock) else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return
        }
        defer { os_unfair_lock_unlock(lock) }
        if let fresh = controls.read() { current.pointee = fresh }
        while let sound = sounds.pop() { dsp.pointee.trigger(sound) }
        let report = dsp.pointee.render(frames: frames, left: left, right: right, controls: current.pointee)
        telemetry.post(report)
    }
}
