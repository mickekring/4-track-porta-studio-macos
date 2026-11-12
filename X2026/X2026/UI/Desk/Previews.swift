import SwiftUI

extension Machine {
    /// A machine on a throwaway desk, for Xcode previews: its tapes live in a
    /// temporary folder and it remembers nothing.
    static func forPreview(loadTape: Bool = true) -> Machine {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "x2026-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let library = TapeLibrary(root: root)
        let suite = "x2026.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard

        var demo = library.addBlank(stock: .c60, design: .krom, title: "Summer demos '89")
        demo.position = demo.totalFrames * 0.31
        library.update(demo)
        var riffs = library.addBlank(stock: .c90, design: .rost, title: "Idéer & riff — vol. 3")
        riffs.position = riffs.totalFrames * 0.72
        library.update(riffs)
        library.addBlank(stock: .c46, design: .studio, title: "")
        var mix = library.addBlank(stock: .c46, design: .pop, title: "Mixtape för Anna")
        mix.flip()
        library.update(mix)

        let machine = Machine(library: library, defaults: defaults)
        if loadTape, let first = library.cassette(withID: demo.id) {
            try? machine.insert(first)
        }
        return machine
    }
}

#Preview("Desk", traits: .fixedLayout(width: 1410, height: 850)) {
    DeskView(desk: Desk(machine: .forPreview()))
}

#Preview("Machine close-up", traits: .fixedLayout(width: 1560, height: 900)) {
    MachineView(machine: .forPreview())
        .environment(\.unit, 4)
        .padding(20)
        .background(Color(red: 0.42, green: 0.30, blue: 0.20))
}

#Preview("Changing the tape", traits: .fixedLayout(width: 1410, height: 850)) {
    let machine = Machine.forPreview(loadTape: false)
    let desk = Desk(machine: machine)
    DeskView(desk: desk)
        .task { desk.freezeMidInsert() }
}

extension Desk {
    static func forPreview(leanedIn: Bool) -> Desk {
        let desk = Desk(machine: .forPreview())
        desk.leanedIn = leanedIn
        return desk
    }
}

#Preview("Leaning in", traits: .fixedLayout(width: 1410, height: 850)) {
    DeskView(desk: .forPreview(leanedIn: true))
}

#Preview("Label editor") {
    LabelEditor(cassette: Cassette(
        title: "Summer demos '89",
        trackNotes: ["Rhythm box", "Bass (DI)", "", ""],
        stock: .c60, design: .krom, position: 4_000_000)) { _ in }
}
