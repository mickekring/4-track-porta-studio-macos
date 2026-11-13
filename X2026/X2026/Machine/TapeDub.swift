import AVFoundation
import Foundation

/// Putting music on a cassette without anyone sitting through it.
///
/// A second X-2026 behind the scenes does the recording, the only way an
/// X-2026 can: two tracks at a time. Whatever is "plugged into" INPUT 1 and
/// INPUT 2 goes through the faders at their 0 mark, panned hard left and
/// right, onto tracks 1 and 2. Then the tape is wound back and the same is
/// done onto tracks 3 and 4. The heads, bias, saturation, hiss and noise
/// reduction are the ones anything recorded at the desk goes through; only
/// the clock is faster.
///
/// One thing is unlike a person doing it by hand. Someone overdubbing plays
/// along to what the tape plays them, so their take follows every waver of
/// the tape. A dub has nobody listening: it is fed by the clock. So each
/// pass is made on a machine switched on fresh, whose wow and flutter then
/// run exactly the same course both times, and the two pairs of tracks land
/// on the tape in step to the sample.
nonisolated enum TapeDub {
    static let sampleRate = 48_000.0
    /// Frames per turn of the machine: 10 ms.
    static let block = 480

    /// Records four tracks onto `medium` in two passes, each starting `start`
    /// frames into the tape and lasting `total` frames.
    ///
    /// - Parameter fill: called before every block with the pass (0 for
    ///   tracks 1 and 2, 1 for tracks 3 and 4), the frame the block starts
    ///   at and its length. It writes what INPUT 1 and INPUT 2 hear.
    static func record(
        onto medium: TapeMedium, stock: TapeStock, from start: Double, frames total: Int,
        noiseReduction: Bool = true,
        fill: (_ pass: Int, _ frame: Int, _ count: Int,
               _ first: UnsafeMutablePointer<Float>, _ second: UnsafeMutablePointer<Float>) -> Void
    ) {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer {
            left.deallocate()
            right.deallocate()
        }

        for pass in 0..<2 {
            // A fresh machine for each pass: see above.
            let core = MachineCore()
            core.prepare(sampleRate: sampleRate)
            core.insert(medium: medium, stock: stock, position: start, recordProtected: false)

            var controls = ControlFrame()
            controls.mechanicalLevel = 0
            controls.panel = Panel()
            controls.panel.noiseReduction = noiseReduction
            controls.panel.fader1 = 0.75
            controls.panel.fader2 = 0.75
            controls.panel.pan1 = 0
            controls.panel.pan2 = 1
            controls.panel.master = 0.75
            controls.panel.recordL = pass == 0 ? .upper : .lower
            controls.panel.recordR = pass == 0 ? .upper : .lower
            controls.transport = TransportRequest(motion: .play, recordKey: true)
            core.controls.post(controls)

            var frame = 0
            while frame < total {
                let frames = min(block, total - frame)
                for jack in 2..<MachineDSP.jackCount {
                    (core.jacks + jack * MachineCore.maximumFrames).update(repeating: 0, count: frames)
                }
                fill(pass, frame, frames, core.jacks, core.jacks + MachineCore.maximumFrames)
                core.render(frames: frames, left: left, right: right)
                frame += frames
            }

            controls.transport = TransportRequest()
            core.controls.post(controls)
            core.render(frames: block, left: left, right: right)
            core.eject()
        }
    }

    /// Plays `total` frames of the tape from `start` through the machine and
    /// returns what comes out of LINE OUT.
    static func play(
        _ medium: TapeMedium, stock: TapeStock, from start: Double, frames total: Int, panel: Panel
    ) -> (left: [Float], right: [Float]) {
        let core = MachineCore()
        core.prepare(sampleRate: sampleRate)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer {
            left.deallocate()
            right.deallocate()
        }
        core.insert(medium: medium, stock: stock, position: start, recordProtected: true)
        var controls = ControlFrame()
        controls.mechanicalLevel = 0
        controls.panel = panel
        controls.transport = TransportRequest(motion: .play, recordKey: false)
        core.controls.post(controls)

        var lineL = [Float](repeating: 0, count: total)
        var lineR = [Float](repeating: 0, count: total)
        var frame = 0
        while frame < total {
            let frames = min(block, total - frame)
            for jack in 0..<MachineDSP.jackCount {
                (core.jacks + jack * MachineCore.maximumFrames).update(repeating: 0, count: frames)
            }
            core.render(frames: frames, left: left, right: right)
            lineL.withUnsafeMutableBufferPointer { ($0.baseAddress! + frame).update(from: core.lineOut, count: frames) }
            lineR.withUnsafeMutableBufferPointer {
                ($0.baseAddress! + frame).update(from: core.lineOut + MachineCore.maximumFrames, count: frames)
            }
            frame += frames
        }
        core.eject()
        return (lineL, lineR)
    }
}

/// The errand behind `--dub-tape <folder>`: makes a cassette out of audio
/// files. See "Dubbing a cassette from stems" in `docs/x26-reference.md`.
nonisolated extension TapeDub {
    /// `order.json` in the folder: what to put on the tape.
    struct Order: Decodable {
        /// What gets written on the label.
        var title: String
        var design: CassetteDesign
        /// 46, 60 or 90.
        var minutes: Int
        var noiseReduction: Bool
        /// Snap the record-protect tabs off when done.
        var recordProtected: Bool
        /// Gain from the files to the input jacks in dB: one figure for all
        /// four tracks, so they keep the balance they have in the files. At
        /// 0, digital full scale lands 12 dB over the meters' 0 mark.
        var gain: Float
        /// Exactly four, in track order.
        var tracks: [Track]

        struct Track: Decodable {
            /// For the track sheet on the inlay card.
            var note: String
            /// Summed onto this track. Stereo files are folded to mono, (L+R)/2.
            var files: [String]
        }
    }

    struct Problem: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    /// Silence on the tape before the music, so the capstan is up to speed.
    private static let leadIn = 1.0
    /// Tape left running after the last sample.
    private static let tail = 0.5

    static var requestedFolder: URL? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--dub-tape"), arguments.indices.contains(flag + 1) else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }

    private static func say(_ text: String) {
        print("[dub] \(text)")
        fflush(stdout)
    }

    /// If the app was started with `--dub-tape <folder>`: makes the cassette
    /// that folder's order asks for, in `folder/cassette`, with what went in
    /// and what came back in `folder/proof`, and quits.
    ///
    /// Call before there is a machine or a window. Nothing of the owner's is
    /// opened and nothing is remembered; the errand works in its folder only.
    @MainActor
    static func runErrandIfAsked() {
        guard let folder = requestedFolder else { return }
        do {
            let order = try JSONDecoder().decode(Order.self, from: Data(contentsOf: folder.appending(path: "order.json")))
            guard order.tracks.count == 4 else { throw Problem(what: "The order must list exactly four tracks.") }
            guard let stock = TapeStock.all.first(where: { $0.minutes == order.minutes }) else {
                throw Problem(what: "There is no C-\(order.minutes); choose 46, 60 or 90.")
            }
            let shelf = folder.appending(path: "cassette", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: shelf)
            let library = TapeLibrary(root: shelf)
            var cassette = Cassette(title: order.title, stock: stock, design: order.design)
            cassette.trackNotes = order.tracks.map(\.note)
            cassette.recordProtected = order.recordProtected
            cassette.position = try dub(order, from: folder, onto: library.oxideURL(for: cassette), stock: stock)
            library.add(cassette)
            say("cassette: \(library.folder(for: cassette).path(percentEncoded: false))")
            say("done")
            exit(0)
        } catch {
            say("FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Does the work and returns the tape position to leave the cassette at.
    private static func dub(_ order: Order, from folder: URL, onto oxide: URL, stock: TapeStock) throws -> Double {
        // What goes on each track: its files, folded to mono and summed.
        var tracks: [[Float]] = []
        for (index, track) in order.tracks.enumerated() {
            var sum: [Float] = []
            for name in track.files {
                let samples = try mono(folder.appending(path: name))
                say(String(format: "track %d ← %@ (%.2f s)", index + 1, name, Double(samples.count) / sampleRate))
                if samples.count > sum.count { sum += [Float](repeating: 0, count: samples.count - sum.count) }
                for frame in samples.indices { sum[frame] += samples[frame] }
            }
            tracks.append(sum)
        }
        let length = tracks.map(\.count).max() ?? 0
        guard length > 0 else { throw Problem(what: "There is no audio in the order.") }
        let gain = Level.gain(dB: order.gain)
        for index in tracks.indices {
            tracks[index] += [Float](repeating: 0, count: length - tracks[index].count)
            if gain != 1 {
                for frame in tracks[index].indices { tracks[index][frame] *= gain }
            }
            say("track \(index + 1) \"\(order.tracks[index].note)\": \(levels(of: tracks[index]))")
        }

        let lead = Int(leadIn * sampleRate)
        let total = lead + length + Int(tail * sampleRate)
        let start = stock.leaderLength * CassetteStandard.framesPerMeter + 0.5 * CassetteStandard.sampleRate
        guard Double(total) + 0.5 * CassetteStandard.sampleRate < Double(stock.frameCount) else {
            throw Problem(what: String(format: "%.1f minutes of music will not fit on a %@.", Double(length) / sampleRate / 60, stock.name))
        }

        try FileManager.default.createDirectory(at: oxide.deletingLastPathComponent(), withIntermediateDirectories: true)
        let medium = try TapeMedium(url: oxide, frameCount: stock.frameCount)
        let clock = ContinuousClock.now
        record(onto: medium, stock: stock, from: start, frames: total, noiseReduction: order.noiseReduction) { pass, frame, count, first, second in
            for (jack, track) in [(first, tracks[pass * 2]), (second, tracks[pass * 2 + 1])] {
                // Silence until the lead-in is over and after the music ends.
                jack.update(repeating: 0, count: count)
                let from = max(frame, lead)
                let to = min(frame + count, lead + length)
                guard from < to else { continue }
                track.withUnsafeBufferPointer {
                    (jack + (from - frame)).update(from: $0.baseAddress! + (from - lead), count: to - from)
                }
            }
        }
        medium.flush(wait: true)
        say(String(format: "recorded %.1f s of tape in two passes (NR %@), in %.0f s", Double(total) / sampleRate, order.noiseReduction ? "on" : "off",
                   Double((ContinuousClock.now - clock) / .seconds(1))))

        // Proof: what went in, and what each track gives back on its own
        // through the machine (SUB GAIN full toward TRK, SUB PAN centred).
        let proof = folder.appending(path: "proof", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: proof)
        try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
        for index in tracks.indices {
            try write([[Float](repeating: 0, count: lead) + tracks[index]], to: proof.appending(path: "in \(index + 1).wav"))
        }
        var panel = Panel()
        panel.noiseReduction = order.noiseReduction
        panel.remix = true
        panel.master = 0.75
        for index in tracks.indices {
            panel.subGain = Quad(repeating: 0.5)
            panel.subGain[index] = 1
            panel.subPan = Quad(repeating: 0.5)
            let heard = play(medium, stock: stock, from: start, frames: total, panel: panel)
            try write([heard.left], to: proof.appending(path: "out \(index + 1).wav"))
            say("played track \(index + 1) back on its own")
        }
        // And the four together as the machine comes from the factory.
        var factory = Panel.readyToPlay
        factory.noiseReduction = order.noiseReduction
        let mix = play(medium, stock: stock, from: start, frames: total, panel: factory)
        try write([mix.left, mix.right], to: proof.appending(path: "mix.wav"))
        say("played all four back with the factory panel")
        return start
    }

    /// One file as mono samples at the tape's rate.
    private static func mono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == sampleRate else {
            throw Problem(what: "\(url.lastPathComponent) is at \(Int(format.sampleRate)) Hz. Convert it to 48 000 Hz first.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16), let channels = buffer.floatChannelData else {
            throw Problem(what: "\(url.lastPathComponent) could not be read as audio.")
        }
        let count = Int(format.channelCount)
        var samples: [Float] = []
        samples.reserveCapacity(Int(max(0, file.length)))
        while true {
            do {
                try file.read(into: buffer)
            } catch {
                // Some decoders report the end of the file as an error.
                if samples.isEmpty { throw error }
                break
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            let scale = 1 / Float(count)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<count { sum += channels[channel][frame] }
                samples.append(sum * scale)
            }
        }
        return samples
    }

    private static func write(_ channels: [[Float]], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = channels[0].count
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw Problem(what: "Could not write \(url.lastPathComponent).")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { data[index].update(from: $0.baseAddress!, count: frames) }
        }
        try file.write(from: buffer)
    }

    /// Where a track sits against the meters' 0 mark.
    private static func levels(of samples: [Float]) -> String {
        var power: Double = 0
        var peak: Float = 0
        var sparse: [Float] = []
        sparse.reserveCapacity(samples.count / 16 + 1)
        for (index, sample) in samples.enumerated() {
            let size = abs(sample)
            power += Double(size) * Double(size)
            peak = max(peak, size)
            if index % 16 == 0 { sparse.append(size) }
        }
        sparse.sort()
        let loud = sparse[min(sparse.count - 1, Int(Double(sparse.count) * 0.999))]
        let rms = Float((power / Double(max(1, samples.count))).squareRoot())
        return String(
            format: "average %+.1f dB against the 0 mark, loud moments %+.1f, highest peak %+.1f",
            Level.decibels(rms / (Level.reference * 0.7071)), Level.decibels(loud / Level.reference), Level.decibels(peak / Level.reference))
    }
}
