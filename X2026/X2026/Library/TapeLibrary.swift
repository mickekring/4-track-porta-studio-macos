import Foundation
import Observation
import OSLog

/// The pile of cassettes on the desk.
///
/// Each cassette is a folder holding its label (`label.json`) and its oxide
/// (`oxide.pcm`, four tracks of raw 16-bit audio that only the machine's heads
/// ever read or write).
@Observable
final class TapeLibrary {
    private(set) var cassettes: [Cassette] = []

    let root: URL
    private let log = Logger(subsystem: "se.mickekring.X2026", category: "library")

    static let packageExtension = "x2026tape"

    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "Tapes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        reload()
    }

    func folder(for cassette: Cassette) -> URL {
        root.appending(path: "\(cassette.id.uuidString).\(Self.packageExtension)", directoryHint: .isDirectory)
    }

    /// The file the heads read and write.
    func oxideURL(for cassette: Cassette) -> URL {
        folder(for: cassette).appending(path: "oxide.pcm")
    }

    private func labelURL(for cassette: Cassette) -> URL {
        folder(for: cassette).appending(path: "label.json")
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        cassettes = folders
            .filter { $0.pathExtension == Self.packageExtension }
            .compactMap { folder -> Cassette? in
                // A folder with oxide but no label is a recording session that
                // never finished (the app quit mid-demo, say): clear it away.
                guard FileManager.default.fileExists(atPath: folder.appending(path: "label.json").path(percentEncoded: false)) else {
                    try? FileManager.default.removeItem(at: folder)
                    return nil
                }
                do {
                    let data = try Data(contentsOf: folder.appending(path: "label.json"))
                    return try decoder.decode(Cassette.self, from: data)
                } catch {
                    log.error("Unreadable cassette label at \(folder.lastPathComponent, privacy: .public): \(error)")
                    return nil
                }
            }
            .sorted { $0.created < $1.created }
    }

    /// Unwraps a fresh blank tape and puts it on the desk.
    @discardableResult
    func addBlank(stock: TapeStock, design: CassetteDesign, title: String = "") -> Cassette {
        let cassette = Cassette(title: title, stock: stock, design: design)
        cassettes.append(cassette)
        save(cassette)
        return cassette
    }

    /// Puts a cassette that already has something on it onto the desk.
    func add(_ cassette: Cassette) {
        guard !cassettes.contains(where: { $0.id == cassette.id }) else { return }
        cassettes.append(cassette)
        save(cassette)
    }

    /// Writes the label back. Call whenever a cassette's title, notes or tape
    /// position change.
    func update(_ cassette: Cassette) {
        guard let index = cassettes.firstIndex(where: { $0.id == cassette.id }) else { return }
        cassettes[index] = cassette
        save(cassette)
    }

    /// Throws a cassette away for good. There is no getting it back.
    func discard(_ cassette: Cassette) {
        cassettes.removeAll { $0.id == cassette.id }
        do {
            try FileManager.default.removeItem(at: folder(for: cassette))
        } catch {
            log.error("Could not discard cassette: \(error)")
        }
    }

    func cassette(withID id: Cassette.ID) -> Cassette? {
        cassettes.first { $0.id == id }
    }

    private func save(_ cassette: Cassette) {
        do {
            try FileManager.default.createDirectory(at: folder(for: cassette), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(cassette).write(to: labelURL(for: cassette), options: .atomic)
        } catch {
            log.error("Could not save cassette label: \(error)")
        }
    }
}
