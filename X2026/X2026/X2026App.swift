import SwiftUI

/// There is one machine and one window: closing it switches off.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct X2026App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var machine: Machine
    @State private var desk: Desk

    /// True when the app is only running to host the unit tests or Xcode's
    /// previews. The test bundle is injected after launch, so ask the
    /// environment, not the runtime.
    private static let isHostingTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }()

    /// Errands and test runs must not see or change anything of the owner's.
    /// Decided by the dashes rather than by a list of flags, so that a new
    /// `--something-test` is kept off the real desk before anyone remembers
    /// to add it here. (Xcode's own launch arguments have a single dash.)
    private static var leavesNoTrace: Bool {
        #if DEBUG
        isHostingTests || CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
        #else
        isHostingTests
        #endif
    }

    init() {
        // An errand that needs neither machine nor window is done, and the
        // app gone again, before either exists.
        TapeDub.runErrandIfAsked()
        // Tests, previews and errands work at a desk of their own. They never
        // see the owner's cassettes or settings, let alone record on them.
        let machine = Self.leavesNoTrace ? Machine.onScratchDesk() : Machine()
        _machine = State(initialValue: machine)
        _desk = State(initialValue: Desk(machine: machine))
        if !Self.leavesNoTrace {
            FirstRun.stockTheDesk(machine.library)
            DemoTape.makeIfNeeded(library: machine.library)
        }
    }

    var body: some Scene {
        Window("\(Brand.maker) \(Brand.model)", id: "desk") {
            if Self.isHostingTests {
                Color.black
            } else {
                DeskView(desk: desk)
                    .frame(minWidth: 906, minHeight: 546)
                    .task {
                        if Self.leavesNoTrace {
                            // AppKit would remember where this window was last
                            // put, in the owner's settings, as if it were theirs.
                            for window in NSApplication.shared.windows { window.setFrameAutosaveName("") }
                        }
                        #if DEBUG
                        let loopback = SelfTest.isLoopbackRequested && SelfTest.prepareLoopback(machine: machine)
                        #endif
                        machine.powerOn()
                        #if DEBUG
                        if SelfTest.isInputRequested {
                            await SelfTest.runInput(machine: machine, desk: desk)
                            NSApplication.shared.terminate(nil)
                        }
                        if SelfTest.isMixdownRequested {
                            await SelfTest.runMixdown(machine: machine, desk: desk)
                            NSApplication.shared.terminate(nil)
                        }
                        if SelfTest.isTouchRequested {
                            await SelfTest.runTouch(machine: machine, desk: desk)
                            NSApplication.shared.terminate(nil)
                        }
                        if loopback {
                            await SelfTest.runLoopback(machine: machine, desk: desk)
                            NSApplication.shared.terminate(nil)
                        } else if SelfTest.isLoopbackRequested {
                            NSApplication.shared.terminate(nil)
                        }
                        if IconArt.isRequested {
                            IconArt.renderAll()
                            NSApplication.shared.terminate(nil)
                        }
                        if SelfTest.isRequested {
                            await SelfTest.run(machine: machine, desk: desk)
                            NSApplication.shared.terminate(nil)
                        }
                        #endif
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                        machine.powerOff()
                        machine.discardScratchDesk()
                    }
            }
        }
        .defaultSize(width: 1410, height: 850)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            MachineCommands(machine: machine, desk: desk)
        }

        Window("\(Brand.model) Owner's Manual", id: "manual") {
            ManualView()
        }
        .defaultSize(width: 720, height: 820)

        Settings {
            SettingsView(machine: machine)
        }
    }
}

/// What a new owner finds on the desk the first time.
enum FirstRun {
    static func stockTheDesk(_ library: TapeLibrary) {
        guard library.cassettes.isEmpty else { return }
        library.addBlank(stock: .c60, design: .krom, title: "")
        library.addBlank(stock: .c90, design: .rost, title: "Idéer & riff")
    }
}

/// Menu-bar commands and the keyboard shortcuts for the transport.
struct MachineCommands: Commands {
    let machine: Machine
    let desk: Desk

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("\(Brand.model) Owner's Manual") { openWindow(id: "manual") }
                .keyboardShortcut("?", modifiers: [.command])
        }
        CommandMenu("Transport") {
            // No key equivalents here on purpose: bare letters in the menu bar
            // would swallow typing everywhere. The desk handles the keys itself.
            Button("Play  (Space)") { tap(.play) }
            Button("Stop  (Return)") { tap(.stop) }
            Button("Record  (R)") { tap(.record) }
            Button("Rewind  (←)") { tap(.rewind) }
            Button("Fast Forward  (→)") { tap(.fastForward) }
            Divider()
            Button("Step on the Foot Switch  (P)") { machine.stepOnFootSwitch() }
                .disabled(!machine.footSwitchConnected)
            Button("Reset Counter  (0)") { machine.resetCounter() }
        }
        CommandGroup(before: .toolbar) {
            Button("Whole Desk") { desk.focus = nil }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(desk.focus == nil)
            ForEach(Array(Desk.Focus.allCases.enumerated()), id: \.element) { index, device in
                Button("Zoom In on the \(device.name)") { desk.focus = device }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
            }
            Divider()
        }
        CommandMenu("Tape") {
            Button(desk.lidOpening > 0.5 ? "Close the Lid" : "Open the Lid") { desk.toggleLid() }
                .keyboardShortcut("l", modifiers: [.command])
            Button("Take the Cassette Out") { desk.eject() }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(machine.loaded == nil)
            Button("Turn the Cassette Over") { desk.turnOverLoaded() }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(machine.loaded == nil)
            Divider()
            Menu("Unwrap a Blank Tape") {
                ForEach(CassetteDesign.allCases, id: \.self) { design in
                    ForEach(TapeStock.all) { stock in
                        Button("\(design.brand) \(design.grade) \(stock.name)") {
                            desk.unwrapBlank(stock: stock, design: design)
                        }
                    }
                }
            }
            Button("Show Tapes in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([machine.library.root])
            }
        }
    }

    /// Space bar behaves like a finger that knows what it wants: PLAY when
    /// stopped, STOP when anything is running.
    private func tap(_ key: TransportKey) {
        let target: TransportKey = key == .play && !machine.keysDown.isEmpty ? .stop : key
        machine.press(target)
        Task {
            try? await Task.sleep(for: .milliseconds(110))
            machine.release(target)
        }
    }
}

/// The few things that are about the Mac rather than the machine.
struct SettingsView: View {
    @Bindable var machine: Machine

    var body: some View {
        Form {
            Section("Sound of the mechanism") {
                Slider(value: $machine.mechanicalLevel, in: 0...1) {
                    Text("Keys, motors and lid")
                } minimumValueLabel: {
                    Image(systemName: "speaker")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3")
                }
            }
            Section("Audio hardware") {
                LabeledContent("PHONES go to", value: machine.audio.outputDeviceName.isEmpty ? "—" : machine.audio.outputDeviceName)
                LabeledContent("Input jacks take from", value: machine.audio.inputDeviceName.isEmpty ? "—" : machine.audio.inputDeviceName)
                Text("The machine uses the output and input chosen in System Settings → Sound, and follows them when they change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Sample rate", value: "\(Int(machine.audio.sampleRate)) Hz")
                LabeledContent(
                    "Round trip",
                    value: machine.audio.roundTripLatency == 0
                        ? "no input in use"
                        : String(format: "%.1f ms", Double(machine.audio.roundTripLatency) / machine.audio.sampleRate * 1000))
                if machine.audio.microphoneDenied {
                    Text("The X-2026 is not allowed to use audio input. Allow it under System Settings → Privacy & Security → Microphone.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let problem = machine.audio.problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                Slider(value: $machine.latencyTrim, in: -20...20, step: 0.5) {
                    Text("Head alignment")
                } minimumValueLabel: {
                    Text("−20").font(.caption)
                } maximumValueLabel: {
                    Text("+20").font(.caption)
                }
                Text(String(format: "%+.1f ms. Overdubs are shifted to cancel the Mac's audio round trip; nudge this if yours land early or late.", machine.latencyTrim))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Overdub timing")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
