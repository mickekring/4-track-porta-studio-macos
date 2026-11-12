import Foundation

/// Physical constants of the Compact Cassette, and of how we lay audio onto it.
///
/// Everything in the emulation is derived from real tape geometry: the head
/// position is a distance along the tape, reel speeds follow from pack radius,
/// and the counter counts hub revolutions exactly like the belt-driven one did.
nonisolated enum CassetteStandard {
    /// 1⅞ inches per second.
    static let nominalSpeed = 0.047625                      // m/s
    /// Radius of the empty hub the tape winds onto.
    static let hubRadius = 0.0109                           // m
    /// Number of tracks across the tape. A 4-track uses the full width in one
    /// direction, so "side B" is the same four tracks played backwards.
    static let trackCount = 4

    /// Audio frames laid down per second of tape travel at nominal speed.
    /// This is a property of the *medium* (a spatial density), not of the
    /// audio device: the heads resample to and from it as the speed varies.
    static let sampleRate = 48_000.0
    /// Frames per metre of tape.
    static let framesPerMeter = sampleRate / nominalSpeed

    /// Distance from the erase head gap to the record/play head gap.
    /// At 4.76 cm/s the tape takes about a quarter of a second to cover it,
    /// which is where the classic punch-out gap comes from.
    static let eraseToRecordGap = 0.0125                    // m
}

/// A length of tape you can buy.
nonisolated struct TapeStock: Codable, Hashable, Sendable, Identifiable {
    /// Nominal playing time of both sides, the number printed on the box.
    var minutes: Int
    /// Length of the magnetic tape, without leaders.
    var tapeLength: Double                                  // m
    /// Total thickness of base film plus oxide coating.
    var thickness: Double                                   // m
    /// Clear, non-magnetic leader spliced on at each end. Nothing records here.
    var leaderLength: Double                                // m

    var id: Int { minutes }
    var name: String { "C-\(minutes)" }

    /// Leader + tape + leader.
    var totalLength: Double { tapeLength + 2 * leaderLength }

    /// Seconds of recording you get in one pass at nominal speed.
    var playingTime: Double { tapeLength / CassetteStandard.nominalSpeed }

    /// Number of 4-track frames of magnetic tape.
    var frameCount: Int { Int((tapeLength * CassetteStandard.framesPerMeter).rounded()) }

    /// Manufacturers always put a little more in than the box promises.
    static let c46 = TapeStock(minutes: 46, tapeLength: 68.0, thickness: 18e-6, leaderLength: 0.24)
    static let c60 = TapeStock(minutes: 60, tapeLength: 89.0, thickness: 18e-6, leaderLength: 0.24)
    static let c90 = TapeStock(minutes: 90, tapeLength: 133.5, thickness: 12e-6, leaderLength: 0.24)

    static let all: [TapeStock] = [.c46, .c60, .c90]
}

/// The two reels of one cassette, as pure geometry.
///
/// Position is measured in metres of tape that have passed the head, starting
/// from a fully rewound tape (everything on the left-hand supply reel).
nonisolated struct ReelGeometry: Sendable {
    let hubRadius: Double
    let thickness: Double
    let totalLength: Double

    init(stock: TapeStock) {
        hubRadius = CassetteStandard.hubRadius
        thickness = stock.thickness
        totalLength = stock.totalLength
    }

    /// Outer radius of a pack holding `wound` metres of tape.
    @inline(__always)
    func radius(wound: Double) -> Double {
        (hubRadius * hubRadius + max(0, wound) * thickness / .pi).squareRoot()
    }

    /// How many times the hub has turned to wind `wound` metres onto itself.
    @inline(__always)
    func turns(wound: Double) -> Double {
        (radius(wound: wound) - hubRadius) / thickness
    }

    /// Inverse of `turns(wound:)`.
    func wound(turns: Double) -> Double {
        let r = hubRadius + turns * thickness
        return .pi * (r * r - hubRadius * hubRadius) / thickness
    }

    /// Radius of the right-hand (take-up) pack at `position`.
    @inline(__always)
    func takeUpRadius(at position: Double) -> Double { radius(wound: position) }

    /// Radius of the left-hand (supply) pack at `position`.
    @inline(__always)
    func supplyRadius(at position: Double) -> Double { radius(wound: totalLength - position) }

    /// Turns the take-up hub has made since the tape was fully rewound.
    @inline(__always)
    func takeUpTurns(at position: Double) -> Double { turns(wound: position) }

    /// Turns the supply hub has made since the tape was fully rewound.
    @inline(__always)
    func supplyTurns(at position: Double) -> Double {
        turns(wound: totalLength) - turns(wound: totalLength - position)
    }

    /// Turns of a full pack.
    var fullTurns: Double { turns(wound: totalLength) }

    /// Radius of a full pack.
    var fullRadius: Double { radius(wound: totalLength) }
}
