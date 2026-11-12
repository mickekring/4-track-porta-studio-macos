import Foundation

/// The printed look of a cassette: which invented brand it is.
nonisolated enum CassetteDesign: String, Codable, CaseIterable, Sendable {
    /// Charcoal shell, cream label, a red stripe. The dependable ferric one.
    case rost
    /// Black shell, silver and gold. Chrome, for when it matters.
    case krom
    /// Smoked clear shell with the house orange. Sold next to the machine.
    case studio
    /// Bone-white shell, loud stripes. Bought in a three-pack at the petrol station.
    case pop

    var brand: String {
        switch self {
        case .rost: "ROST"
        case .krom: "KROM"
        case .studio: "Brustex"
        case .pop: "POP!"
        }
    }

    var grade: String {
        switch self {
        case .rost: "UD·I"
        case .krom: "SA·II"
        case .studio: "ST·II"
        case .pop: "FX"
        }
    }

    var blurb: String {
        switch self {
        case .rost: "NORMAL POSITION  TYPE I"
        case .krom: "HIGH POSITION  TYPE II"
        case .studio: "MULTITRACK MASTER  TYPE II"
        case .pop: "LOW NOISE"
        }
    }
}

/// One cassette on the desk: its label, its length, and where its tape was left.
///
/// The audio is not in here. It lives in the oxide file next to the label and
/// is only ever touched by the heads of the machine.
nonisolated struct Cassette: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// What somebody wrote on the label in ballpoint.
    var title: String
    /// The track sheet scribbled on the inlay card.
    var trackNotes: [String] = ["", "", "", ""]
    var stock: TapeStock
    var design: CassetteDesign
    /// Frames of tape wound past the head, measured for the side facing up.
    /// A cassette remembers where you stopped it — that is physics, not a feature.
    var position: Double = 0
    /// True when side B faces up, which plays all four tracks backwards.
    var flipped = false
    /// True once the record-protect tabs have been snapped off.
    var recordProtected = false
    var created = Date()

    /// Frames from one physical end of the tape to the other.
    var totalFrames: Double { stock.totalLength * CassetteStandard.framesPerMeter }

    /// Turns the cassette over. The tape that was on the left reel is now on the right.
    mutating func flip() {
        position = totalFrames - position
        flipped.toggle()
    }

    var sideLetter: String { flipped ? "B" : "A" }
}
