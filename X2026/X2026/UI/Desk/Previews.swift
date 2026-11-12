import SwiftUI

extension Machine {
    /// A machine on a scratch desk with a few cassettes lying on it, for
    /// Xcode previews.
    static func forPreview(loadTape: Bool = true) -> Machine {
        let machine = Machine.onScratchDesk()
        let library = machine.library

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
    static func forPreview(focus: Focus?) -> Desk {
        let desk = Desk(machine: .forPreview())
        desk.focus = focus
        return desk
    }
}

#Preview("Leaning in", traits: .fixedLayout(width: 1410, height: 850)) {
    DeskView(desk: .forPreview(focus: .machine))
}

#Preview("Rhythm box up close", traits: .fixedLayout(width: 1410, height: 850)) {
    DeskView(desk: .forPreview(focus: .rhythmBox))
}

#Preview("Reverb up close", traits: .fixedLayout(width: 1410, height: 850)) {
    DeskView(desk: .forPreview(focus: .effectUnit))
}

#Preview("Master recorder up close", traits: .fixedLayout(width: 1410, height: 850)) {
    DeskView(desk: .forPreview(focus: .masterRecorder))
}

#Preview("Label editor") {
    LabelEditor(cassette: Cassette(
        title: "Summer demos '89",
        trackNotes: ["Rhythm box", "Bass (DI)", "", ""],
        stock: .c60, design: .krom, position: 4_000_000)) { _ in }
}
