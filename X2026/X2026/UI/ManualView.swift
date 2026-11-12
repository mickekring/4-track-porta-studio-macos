import SwiftUI

/// The owner's manual, in the box with the machine.
struct ManualView: View {
    private struct Chapter: Identifiable {
        var id: String { title }
        var title: String
        var lead: String
        var steps: [String] = []
        var note: String?
    }

    private static let chapters: [Chapter] = [
        Chapter(
            title: "Welcome",
            lead: "The \(Brand.maker) \(Brand.model) is a four-track cassette multitracker with a six-input mixer. It records up to two tracks at a time onto ordinary cassettes, in one direction, at 1⅞ ips. There is no screen, no timeline and no undo. What goes on the tape stays on the tape until you record over it.",
            note: "Out of the box it is set up to play: click the DEMO cassette, wait for the lid to shut, and press PLAY. Press Z to lean in over the machine, and Z again to sit back and see the whole desk."),
        Chapter(
            title: "Loading a cassette",
            lead: "Cassettes lie on the desk behind the machine. Click one and it is put in for you. Click the lid to open or close it; with the lid open, click the cassette to take it out.",
            steps: [
                "Unwrap a new blank from the BLANK TAPES box. A C-60 holds about 31 minutes of four-track.",
                "Double-click a cassette on the desk to write on its label and fill in the track sheet.",
                "A cassette remembers where its tape was stopped. The counter does not: it belongs to the machine and counts on from whatever it last showed. Reset it yourself.",
                "The first five seconds of every cassette are clear leader. Nothing records there.",
            ]),
        Chapter(
            title: "Recording the first track",
            lead: "Say a rhythm box, on track 1.",
            steps: [
                "Click INPUT jack 1 on the front and plug something in: a channel of your Mac's audio input, or the rhythm box on the desk.",
                "Set GAIN 1 to LINE (MIC for a microphone or a quiet guitar).",
                "Set REMIX/NORM to NORM and the upper REC TRK selector to 1. Lamp 1 turns amber: armed, and you are hearing the input.",
                "Turn PAN 1 fully left. The left side of the stereo buss feeds tracks 1 and 3; the right side feeds 2 and 4.",
                "Put MASTER at 7 or 8 and the meter switch on TAPE. Raise INPUT fader 1 until meter 1 peaks around +3.",
                "To hear it: monitor selector on AUX, AUX SEND about halfway, AUX 3 turned towards TRK 1, then bring up MONITOR.",
                "Reset the counter. Press RECORD. PLAY goes down with it and lamp 1 turns red.",
                "Press STOP, then REWIND back to 000. It takes as long as it takes.",
            ],
            note: "Only the INPUT fader, EQ and MASTER change what is recorded. AUX and MONITOR only change what you hear."),
        Chapter(
            title: "Overdubbing",
            lead: "Now a bass on track 2 while listening to track 1.",
            steps: [
                "Rehearse with REC TRK off, monitor selector on LINE + AUX, and AUX 3 towards TRK 1 to hear the drums. An armed track switches from input to tape the moment you press PLAY, so arm it only for the take.",
                "For the take: lower REC TRK selector to 2 (amber), PAN 1 fully right, meter on TAPE, monitor selector on AUX, AUX 4 towards TRK 2 so you hear yourself.",
                "Press RECORD. Lamp 1 is green (tape), lamp 2 is red.",
            ],
            note: "Your playing is written to the spot on the tape you were hearing, compensating for the delay through the Mac's audio hardware. If overdubs land early or late, adjust Head alignment in Settings."),
        Chapter(
            title: "Punching in",
            lead: "Fix a line without redoing the take. There are three ways in.",
            steps: [
                "Foot switch: plug it into PUNCH IN/OUT (click the jack). Arm the track, press PLAY, step on the switch (or press P) to drop in, and again to drop out.",
                "REC TRK selector: leave it off, press RECORD, and slide the selector on and off at the right moments.",
                "RECORD key: arm the track, press PLAY, press RECORD to drop in. Slide REC TRK off or press STOP to drop out.",
            ],
            note: "The erase head sits a quarter of a second upstream of the record head. Dropping in leaves the old take faintly underneath for that long; dropping out leaves a gap of the same length. Punch in the spaces between phrases."),
        Chapter(
            title: "Ping-pong",
            lead: "Three tracks full? Mix them onto the fourth and free them up.",
            steps: [
                "Set REMIX/NORM to REMIX. Turn SUB GAIN 3, 4 and 5 towards TRK and all their SUB PANs fully right.",
                "Rehearse on LINE + SUB MIX with the meter on MIXER until the R meter sits around 0.",
                "Lower REC TRK to 4, meter to TAPE, monitor selector to AUX, AUX 6 towards TRK 4. Press RECORD.",
            ],
            note: "Never turn SUB GAIN 6 towards TRK 4 while bouncing to track 4: it howls. Bouncing to the track next door can howl too; back off the level and the treble. And every generation is a little duller and a little hissier than the last."),
        Chapter(
            title: "Mixing down",
            lead: "The master recorder on the right is wired to LINE OUT and records in real time.",
            steps: [
                "REMIX/NORM to REMIX, monitor selector to LINE + SUB MIX, meter to MIXER, MASTER at 7 or 8.",
                "Press PLAY and set levels with SUB GAIN 3–6 (towards TRK) and positions with SUB PAN.",
                "For reverb: switch the KLANG R-88 on, AUX SEND and both AUX RCV to taste, then AUX 3–6 towards TRK for the amount on each track.",
                "Rewind. Press REC on the master recorder, then PLAY. Ride the faders. Fade out with MASTER, then press STOP on the recorder and choose where to keep the mix.",
            ]),
        Chapter(
            title: "Things worth knowing",
            lead: "None of this is in the proper manual.",
            steps: [
                "Turn a cassette over and everything on it plays backwards, with the tracks in reverse order. Record a solo on side B and turn it back.",
                "PITCH moves the tape speed ten percent either way. Record with it down and play back at normal speed for instant chipmunks.",
                "Record with noise reduction on and play back with it off: bright, squashed, and very 1988.",
                "MIC gain on a line-level source overdrives the preamp, and hot levels saturate the tape rather than clip.",
                "Snap the record-protect tabs off a finished cassette (right-click it) and RECORD can no longer hurt it.",
                "Thrown-away cassettes are gone. So is whatever was under the tape you just recorded over.",
            ]),
        Chapter(
            title: "Keys",
            lead: "For when both hands are on the guitar.",
            steps: [
                "Space — PLAY, or STOP if anything is running",
                "Return — STOP",
                "R — RECORD",
                "← and → — REWIND and F FWD",
                "P — foot switch",
                "0 — reset counter",
                "Z — lean in / sit back",
                "⌘L — lid, ⌘E — take the cassette out, ⌘B — turn it over",
            ]),
    ]

    private static let specifications: [(String, String)] = [
        ("Tape", "Compact Cassette, C-46 / C-60 / C-90"),
        ("Tracks", "4, one direction; records up to 2 at a time"),
        ("Tape speed", "4.76 cm/s (1⅞ ips)"),
        ("Pitch control", "±10 %"),
        ("Wow and flutter", "±0.15 %"),
        ("Fast wind time", "105 s for a C-60"),
        ("Frequency response", "40 Hz – 12.5 kHz (recorder)"),
        ("Channel separation", "45 dB at 1 kHz"),
        ("Equaliser", "±12 dB at 100 Hz and 10 kHz, shelving, on the stereo buss"),
        ("Noise reduction", "\(Brand.noiseReduction), switchable"),
        ("Dimensions", "380 × 195 × 69 mm, and any size you drag the window to"),
    ]

    private let paper = Color(red: 0.95, green: 0.93, blue: 0.87)
    private let ink = Color(red: 0.13, green: 0.12, blue: 0.11)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Brand.maker)
                            .font(.custom("AvenirNext-HeavyItalic", size: 38))
                            .foregroundStyle(Theme.brandOrange)
                        Text(Brand.model)
                            .font(.custom("HelveticaNeue-UltraLight", size: 54))
                    }
                    Text("\(Brand.descriptor)  ·  OWNER'S MANUAL")
                        .font(.custom("HelveticaNeue-Medium", size: 13))
                        .tracking(3)
                    Rectangle().fill(ink).frame(height: 2).padding(.top, 10)
                }

                ForEach(Self.chapters) { chapter in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(chapter.title.uppercased())
                            .font(.custom("HelveticaNeue-Bold", size: 15))
                            .tracking(1.5)
                        Text(chapter.lead)
                            .font(.custom("HelveticaNeue", size: 14))
                            .lineSpacing(3)
                        ForEach(Array(chapter.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.custom("HelveticaNeue-Bold", size: 13))
                                    .frame(width: 18, alignment: .trailing)
                                Text(step)
                                    .font(.custom("HelveticaNeue", size: 14))
                                    .lineSpacing(3)
                            }
                        }
                        if let note = chapter.note {
                            Text(note)
                                .font(.custom("HelveticaNeue-Italic", size: 13.5))
                                .lineSpacing(3)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ink.opacity(0.07))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("SPECIFICATIONS")
                        .font(.custom("HelveticaNeue-Bold", size: 15))
                        .tracking(1.5)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
                        ForEach(Self.specifications, id: \.0) { name, value in
                            GridRow {
                                Text(name).font(.custom("HelveticaNeue-Medium", size: 13.5))
                                Text(value).font(.custom("HelveticaNeue", size: 13.5))
                            }
                        }
                    }
                }

                Text("\(Brand.tagline) Made with love for a machine from 1988 that started a lot of people off.")
                    .font(.custom("HelveticaNeue-Italic", size: 12.5))
                    .foregroundStyle(ink.opacity(0.7))
                    .padding(.top, 6)
            }
            .foregroundStyle(ink)
            .textSelection(.enabled)
            .padding(38)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(paper)
        .frame(minWidth: 560, idealWidth: 700, minHeight: 500, idealHeight: 760)
    }
}

#Preview("Manual") {
    ManualView()
}
