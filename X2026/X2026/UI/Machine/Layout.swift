import CoreGraphics

/// Where everything sits on the top panel, in millimetres from the top-left
/// corner of the chassis. Measured off the panel drawing on page 6 of the
/// owner's manual, scaled to the 380 × 195 mm in the specifications.
nonisolated enum Layout {
    static let size = CGSize(width: 380, height: 195)
    /// Height of the front face (the jacks) as seen from where you sit.
    static let frontHeight: CGFloat = 21

    // Channel strips
    static let channelX: [CGFloat] = [26.1, 50.8, 76.2, 101.2, 125.9, 150.7]
    static let auxY: CGFloat = 28.1
    static let panY: CGFloat = 48.8
    static let gainY: CGFloat = 69.4
    static let numberY: CGFloat = 168.2

    // Faders: the 10 and 0 marks of the scale
    static let faderTop: CGFloat = 102.0
    static let faderBottom: CGFloat = 147.4
    static var faderTravel: CGFloat { faderBottom - faderTop }

    // Master column
    static let masterX: CGFloat = 179.2
    static let auxSendY: CGFloat = 30.3
    static let returnLY: CGFloat = 49.9
    static let returnRY: CGFloat = 69.6

    // Slide switches
    static let switchX: CGFloat = 212.5
    static let noiseReductionY: CGFloat = 34.2
    static let monitorY: CGFloat = 63.6
    static let remixY: CGFloat = 91.7
    static let recordLY: CGFloat = 120.0
    static let recordRY: CGFloat = 148.7

    // Meters
    static let meter = CGRect(x: 70.7, y: 82.9, width: 36.6, height: 51.6)
    static let meterColumnX: [CGFloat] = [78.45, 85.45, 92.45, 99.45]
    static let meterRowY: [CGFloat] = [91.3, 97.3, 103.3, 109.4, 115.5, 121.5, 127.5]
    static let meterMarks = ["6", "3", "0", "3", "6", "10", "20"]
    static let segment = CGSize(width: 5.2, height: 3.5)
    static let lampY: CGFloat = 138.9
    static let meterSwitch = CGPoint(x: 88.95, y: 152.2)

    // Equaliser sliders: the +10 and -10 marks
    static let eqLX: CGFloat = 130.4
    static let eqRX: CGFloat = 144.0
    static let eqHighTop: CGFloat = 92.4
    static let eqHighBottom: CGFloat = 112.2
    static let eqLowTop: CGFloat = 128.4
    static let eqLowBottom: CGFloat = 148.3

    // Deck side
    static let monitorKnob = CGPoint(x: 238.6, y: 30.2)
    static let pitchKnob = CGPoint(x: 262.9, y: 30.2)
    static let counter = CGPoint(x: 309.8, y: 46.2)
    static let counterReset = CGPoint(x: 322.6, y: 46.2)
    static let badge = CGPoint(x: 358.5, y: 49.6)
    static let lid = CGRect(x: 249, y: 55.5, width: 129, height: 80.5)
    static let well = CGRect(x: 258.5, y: 58.5, width: 116, height: 73.5)
    static let cassette = CGPoint(x: 266.3, y: 62.6)

    // Transport keys
    static let keyX: [CGFloat] = [258.5, 276.6, 294.8, 312.9, 331.0]
    static let keySize = CGSize(width: 14.2, height: 20)
    static let keyTop: CGFloat = 169.6
    static let keyTray = CGRect(x: 248.2, y: 166.6, width: 93.2, height: 26.4)

    // Rear-panel legend strip (x of each jack)
    static let tapeOutX: [CGFloat] = [29.4, 42.6, 55.7, 72.9]
    static let lineOutX: [CGFloat] = [105.0, 118.2]
    static let auxSendJackX: CGFloat = 134.8
    static let auxReturnJackX: [CGFloat] = [150.2, 165.0]
    static let monitorOutX: [CGFloat] = [180.0, 193.3]

    // Front-panel jacks
    static let phonesX: CGFloat = 232
    static let punchX: CGFloat = 252
}
