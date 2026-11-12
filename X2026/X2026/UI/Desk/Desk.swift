import Observation
import SwiftUI

/// The desk the machine sits on, and the hand that works it.
///
/// Loading a song means a hand picks a cassette up off the desk, opens the
/// lid, drops the tape onto the spindles and shuts the lid again. This object
/// is the choreographer: it moves the hand through each of those motions and
/// tells the machine what physically happened at the right moment.
@Observable
final class Desk {
    let machine: Machine

    /// Size of the scene in millimetres. Everything is laid out at 1:1.
    static let scene = CGSize(width: 604, height: 364)
    /// Top-left corner of the machine in the scene.
    static let machineOrigin = CGPoint(x: 112, y: 128)

    struct Carried: Equatable {
        var cassette: Cassette
        /// Scene position of the point where the thumb holds it.
        var grip: CGPoint
        var angle: Angle
        /// 0 = lying on a surface, 1 = held well above it.
        var lift: Double
    }

    /// Where the hand is, or nil when it is out of the picture.
    private(set) var hand: HandPose?
    /// The cassette the hand is holding.
    private(set) var carried: Carried?
    /// 0 = lid shut, 1 = lid open.
    private(set) var lidOpening: Double
    /// True while the hand is busy; other requests wait their turn.
    private(set) var busy = false

    /// True when you are leaning in over the machine and it fills the window.
    var leanedIn = false

    /// The machine's footprint in the scene, front panel included.
    static let machineFrame = CGRect(
        x: machineOrigin.x, y: machineOrigin.y,
        width: Layout.size.width, height: Layout.size.height + Layout.frontHeight)

    /// Cassette whose label is being written on.
    var editing: Cassette?
    /// Cassette about to be thrown away, pending confirmation.
    var discarding: Cassette?
    var hovered: Cassette.ID?

    @ObservationIgnored private var performance: Task<Void, Never>?

    init(machine: Machine) {
        self.machine = machine
        lidOpening = machine.lidOpen ? 1 : 0
    }

    // MARK: - Geography

    /// Cassettes lying on the desk: all of them except the one in the machine
    /// and the one in the hand.
    var cassettesOnDesk: [Cassette] {
        machine.library.cassettes.filter { $0.id != machine.loaded?.id && $0.id != carried?.cassette.id }
    }

    /// Where a cassette lies when it is on the desk: its top-left corner and
    /// the slight angle it was put down at.
    func spot(for cassette: Cassette) -> (origin: CGPoint, angle: Angle) {
        let all = machine.library.cassettes
        let index = all.firstIndex { $0.id == cassette.id } ?? 0
        // A loose row along the back of the desk, closing up as it fills.
        let room = 232.0
        let pitch = all.count <= 1 ? 0 : min(74, room / Double(all.count - 1))
        // The same cassette always lands the same way: derive the scatter from its ID.
        let seed = cassette.id.uuid
        let wobble = Double(Int(seed.0) % 17) - 8
        let drop = Double(Int(seed.1) % 21)
        return (CGPoint(x: 84 + Double(index) * pitch, y: 14 + drop), .degrees(wobble * 0.9))
    }

    /// Scene position of the thumb when it holds a cassette lying at `origin`.
    private func grip(at origin: CGPoint) -> CGPoint {
        origin + HandArt.cassetteGrip
    }

    private var wellGrip: CGPoint { grip(at: Self.machineOrigin + Layout.cassette) }

    private var lidFront: CGPoint {
        Self.machineOrigin + CGPoint(x: Layout.lid.midX, y: Layout.lid.maxY - 3)
    }

    private var lidRaised: CGPoint {
        Self.machineOrigin + CGPoint(x: Layout.lid.midX, y: Layout.lid.minY + Layout.lid.height * 0.16)
    }

    private var offstage: HandPose {
        HandPose(wrist: CGPoint(x: Self.scene.width + 90, y: Self.scene.height + 150), lift: 1, curl: 0.3, point: 0)
    }

    // MARK: - Requests

    /// Puts `cassette` in the machine, swapping out whatever is there.
    func insert(_ cassette: Cassette) {
        perform { desk in
            if desk.machine.loaded != nil { await desk.takeOutCassette() }
            await desk.putIn(cassette)
            await desk.leave()
        }
    }

    /// Takes the cassette out of the machine and puts it back on the desk.
    func eject(turnOver: Bool = false) {
        guard machine.loaded != nil else { return }
        perform { desk in
            await desk.takeOutCassette(turnOver: turnOver)
            await desk.leave()
        }
    }

    /// Turns the cassette in the machine over to its other side.
    func turnOverLoaded() {
        guard let cassette = machine.loaded else { return }
        perform { desk in
            await desk.takeOutCassette(turnOver: true)
            if let turned = desk.machine.library.cassette(withID: cassette.id) {
                await desk.putIn(turned)
            }
            await desk.leave()
        }
    }

    func toggleLid() {
        perform { desk in
            if desk.lidOpening > 0.5 {
                await desk.closeLid()
            } else {
                await desk.openLid()
            }
            await desk.leave()
        }
    }

    /// Turns a cassette on the desk over. Side B plays everything backwards.
    func turnOver(_ cassette: Cassette) {
        var turned = cassette
        turned.flip()
        machine.library.update(turned)
    }

    func setRecordProtect(_ protected: Bool, on cassette: Cassette) {
        var changed = cassette
        changed.recordProtected = protected
        machine.library.update(changed)
    }

    /// Unwraps a blank tape and offers a pen.
    func unwrapBlank(stock: TapeStock, design: CassetteDesign) {
        let cassette = machine.library.addBlank(stock: stock, design: design)
        editing = cassette
    }

    func throwAway(_ cassette: Cassette) {
        guard machine.loaded?.id != cassette.id else { return }
        machine.library.discard(cassette)
    }

    // MARK: - Choreography

    private func perform(_ script: @escaping @MainActor (Desk) async -> Void) {
        guard !busy else { return }
        busy = true
        performance = Task { [weak self] in
            guard let self else { return }
            await script(self)
            self.busy = false
        }
    }

    /// Runs `update` with eased progress 0…1 over `duration` seconds.
    private func animate(_ duration: Double, _ update: (Double) -> Void) async {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            let elapsed = (clock.now - start) / .seconds(1)
            let progress = min(1, elapsed / max(0.001, duration))
            update(Ease.inOut(progress))
            if progress >= 1 { break }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Moves the hand to `target`, taking along anything it holds.
    private func move(to target: HandPose, in duration: Double, turningTo angle: Angle? = nil) async {
        let from = hand ?? offstage
        let startAngle = carried?.angle ?? .zero
        await animate(duration) { t in
            let pose = HandPose.mix(from, target, t)
            self.hand = pose
            if var held = self.carried {
                held.grip = pose.thumbPad
                held.lift = pose.lift
                if let angle {
                    held.angle = .degrees(Ease.mix(startAngle.degrees, angle.degrees, t))
                }
                self.carried = held
            }
        }
    }

    private func openLid() async {
        guard lidOpening < 0.5 else { return }
        await move(to: .pressing(lidFront, lift: 0.5), in: hand == nil ? 0.5 : 0.32)
        await move(to: .pressing(lidFront, lift: 0.05), in: 0.09)
        machine.lidOpen = true
        let from = hand ?? offstage
        let up = HandPose.pressing(lidRaised + CGPoint(x: 0, y: 6), lift: 0.7)
        await animate(0.26) { t in
            self.lidOpening = t
            self.hand = HandPose.mix(from, up, t)
        }
    }

    private func closeLid() async {
        guard lidOpening > 0.5 else { return }
        await move(to: .pressing(lidRaised, lift: 0.75), in: hand == nil ? 0.5 : 0.3)
        let from = hand ?? offstage
        let down = HandPose.pressing(lidFront + CGPoint(x: 0, y: -8), lift: 0.05)
        await animate(0.24) { t in
            self.lidOpening = 1 - t
            self.hand = HandPose.mix(from, down, t)
        }
        machine.lidOpen = false
        await move(to: .pressing(lidFront + CGPoint(x: 0, y: -8), lift: 0.4), in: 0.1)
    }

    /// Nobody changes a tape with the transport running: STOP first.
    private func pressStopIfRunning() async {
        guard !machine.keysDown.isEmpty else { return }
        let stop = Self.machineOrigin + CGPoint(x: Layout.keyX[TransportKey.stop.rawValue], y: Layout.keyTop + 11)
        await move(to: .pressing(stop, lift: 0.5), in: hand == nil ? 0.5 : 0.3)
        await move(to: .pressing(stop, lift: 0), in: 0.07)
        machine.press(.stop)
        await pause(0.09)
        machine.release(.stop)
        await move(to: .pressing(stop, lift: 0.5), in: 0.09)
        await pause(0.25)
    }

    private func putIn(_ cassette: Cassette) async {
        guard machine.loaded == nil else { return }
        await pressStopIfRunning()
        await openLid()

        // Reach for the cassette where it lies and pick it up.
        let place = spot(for: cassette)
        let pickup = grip(at: place.origin)
        await move(to: .gripping(pickup, lift: 0.55, curl: 0.2), in: hand == nil ? 0.55 : 0.42)
        await move(to: .gripping(pickup, lift: 0.04), in: 0.13)
        carried = Carried(cassette: cassette, grip: pickup, angle: place.angle, lift: 0)
        await move(to: .gripping(pickup, lift: 0.85), in: 0.15)

        // Carry it over the well, squaring it up on the way, and lower it in.
        await move(to: .gripping(wellGrip, lift: 0.85), in: 0.6, turningTo: .zero)
        await move(to: .gripping(wellGrip, lift: 0.06), in: 0.22)
        do {
            try machine.insert(cassette)
        } catch {
            // The tape would not thread: put it back where it came from.
            await move(to: .gripping(pickup, lift: 0.5), in: 0.5, turningTo: place.angle)
            carried = nil
            return
        }
        carried = nil
        await move(to: .gripping(wellGrip + CGPoint(x: 14, y: 8), lift: 0.5, curl: 0.3), in: 0.14)
        await closeLid()
    }

    private func takeOutCassette(turnOver: Bool = false) async {
        guard machine.loaded != nil else { return }

        await pressStopIfRunning()
        await openLid()

        await move(to: .gripping(wellGrip, lift: 0.5, curl: 0.3), in: 0.3)
        await move(to: .gripping(wellGrip, lift: 0.05), in: 0.12)
        guard var cassette = machine.removeCassette() else { return }
        carried = Carried(cassette: cassette, grip: wellGrip, angle: .zero, lift: 0)
        await move(to: .gripping(wellGrip, lift: 0.85), in: 0.16)

        if turnOver {
            // A flick of the wrist.
            await animate(0.28) { t in
                if t > 0.5, self.carried?.cassette.flipped == cassette.flipped {
                    cassette.flip()
                    self.machine.library.update(cassette)
                    self.carried?.cassette = cassette
                }
                self.carried?.lift = 0.85 + 0.15 * sin(t * .pi)
            }
        }
        let place = spot(for: cassette)
        let drop = grip(at: place.origin)
        await move(to: .gripping(drop, lift: 0.8), in: 0.55, turningTo: place.angle)
        await move(to: .gripping(drop, lift: 0.03), in: 0.16)
        carried = nil
        await move(to: .gripping(drop + CGPoint(x: 12, y: 10), lift: 0.5, curl: 0.3), in: 0.14)
    }

    /// For previews: the hand caught half way through loading a tape.
    func freezeMidInsert() {
        guard let cassette = machine.library.cassettes.first else { return }
        lidOpening = 1
        let target = Ease.mix(grip(at: spot(for: cassette).origin), wellGrip, 0.78)
        let pose = HandPose.gripping(target, lift: 0.85)
        hand = pose
        carried = Carried(cassette: cassette, grip: pose.thumbPad, angle: .degrees(-2), lift: 0.85)
    }

    private func leave() async {
        guard hand != nil else { return }
        await move(to: offstage, in: 0.5)
        hand = nil
    }
}
