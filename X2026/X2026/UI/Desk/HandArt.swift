import SwiftUI

/// A right hand reaching in over the machine, seen from above.
///
/// It is drawn in two layers so it can hold things: the fingers go *under*
/// whatever it carries and the thumb and back of the hand go *over* it.
/// Hand space is in millimetres with the wrist at the origin and the fingers
/// pointing up the screen; the view rotates it so the arm comes in from the
/// lower right.
enum HandArt {
    /// How far the arm is swung round from straight up the screen.
    static let reach = Angle.degrees(-32)

    /// Tip of the index finger, in hand space. This is what presses things.
    static let fingertip = CGPoint(x: -27, y: -158)
    /// The pad of the thumb, in hand space. This is where it grips.
    static let thumbPad = CGPoint(x: -78, y: -77)
    /// Where on a cassette (in its own millimetres) the thumb comes down.
    static let cassetteGrip = CGPoint(x: 86, y: 37)

    private static let skin = Color(red: 0.93, green: 0.76, blue: 0.64)
    private static let skinShade = Color(red: 0.80, green: 0.60, blue: 0.49)
    private static let outline = Color(red: 0.50, green: 0.32, blue: 0.25)
    private static let nail = Color(red: 0.97, green: 0.86, blue: 0.80)
    private static let denim = Color(red: 0.26, green: 0.38, blue: 0.56)

    private struct Finger {
        var x: CGFloat
        var length: CGFloat
        var width: CGFloat
        var lean: Double
    }

    /// Index, middle, ring, little: knuckle position along the top of the palm.
    private static let fingers = [
        Finger(x: -27, length: 73, width: 18.5, lean: -3),
        Finger(x: -8.5, length: 80, width: 19, lean: 0),
        Finger(x: 10.5, length: 74, width: 18, lean: 3),
        Finger(x: 28, length: 58, width: 16, lean: 7),
    ]

    private static func capsule(length: CGFloat, width: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: -width / 2, y: -length, width: width, height: length + width * 0.4), cornerRadius: width / 2)
    }

    private static func skinFill(_ context: GraphicsContext, _ path: Path, light: CGPoint, dark: CGPoint) {
        context.fill(path, with: .linearGradient(
            Gradient(colors: [skin.mix(with: .white, by: 0.10), skin, skinShade]),
            startPoint: light, endPoint: dark))
        context.stroke(path, with: .color(outline.opacity(0.55)), lineWidth: 0.7)
    }

    // MARK: - Lower layer

    /// The fingers. `curl` 0 lays them flat; 1 tucks them into the palm.
    /// `point` keeps the index finger out regardless, for pressing keys.
    static func drawFingers(_ context: GraphicsContext, curl: Double, point: Double) {
        for (index, finger) in fingers.enumerated().reversed() {
            var local = context
            local.translateBy(x: finger.x, y: -84)
            local.rotate(by: .degrees(finger.lean))
            let tucked = index == 0 ? curl * (1 - point) : curl
            let length = finger.length * (1 - 0.62 * tucked)
            let shape = capsule(length: length, width: finger.width)
            skinFill(local, shape, light: CGPoint(x: -finger.width / 2, y: -length), dark: CGPoint(x: finger.width / 2, y: 0))

            if tucked < 0.5 {
                // Two knuckle creases and a nail.
                for fraction in [0.36, 0.68] {
                    var crease = Path()
                    let y = -length * fraction
                    crease.move(to: CGPoint(x: -finger.width * 0.30, y: y))
                    crease.addQuadCurve(to: CGPoint(x: finger.width * 0.30, y: y), control: CGPoint(x: 0, y: y + 2.2))
                    local.stroke(crease, with: .color(outline.opacity(0.30)), lineWidth: 0.6)
                }
                let nailShape = Path(
                    roundedRect: CGRect(x: -finger.width * 0.31, y: -length + 2.2, width: finger.width * 0.62, height: finger.width * 0.72),
                    cornerRadius: finger.width * 0.26)
                local.fill(nailShape, with: .color(nail))
                local.stroke(nailShape, with: .color(outline.opacity(0.28)), lineWidth: 0.45)
            } else {
                // Curled under: all you see is the bend of the knuckle.
                var crease = Path()
                crease.move(to: CGPoint(x: -finger.width * 0.32, y: -length * 0.55))
                crease.addQuadCurve(to: CGPoint(x: finger.width * 0.32, y: -length * 0.55), control: CGPoint(x: 0, y: -length * 0.55 - 2.5))
                local.stroke(crease, with: .color(outline.opacity(0.32)), lineWidth: 0.7)
            }
        }
    }

    // MARK: - Upper layer

    /// Sleeve, back of the hand and thumb.
    static func drawBack(_ context: GraphicsContext) {
        // Denim sleeve disappearing off towards the elbow.
        var sleeve = Path()
        sleeve.move(to: CGPoint(x: -37, y: 20))
        sleeve.addLine(to: CGPoint(x: 38, y: 20))
        sleeve.addLine(to: CGPoint(x: 56, y: 330))
        sleeve.addLine(to: CGPoint(x: -52, y: 330))
        sleeve.closeSubpath()
        context.fill(sleeve, with: .linearGradient(
            Gradient(colors: [denim.mix(with: .white, by: 0.18), denim, denim.mix(with: .black, by: 0.30)]),
            startPoint: CGPoint(x: -45, y: 0), endPoint: CGPoint(x: 50, y: 0)))
        // Twill: faint diagonal weave.
        var weave = context
        weave.clip(to: sleeve)
        var offset: CGFloat = -120
        while offset < 420 {
            var thread = Path()
            thread.move(to: CGPoint(x: -70, y: offset))
            thread.addLine(to: CGPoint(x: 70, y: offset + 50))
            weave.stroke(thread, with: .color(.white.opacity(0.045)), lineWidth: 0.7)
            offset += 3.2
        }
        // Wrist.
        var wrist = Path()
        wrist.move(to: CGPoint(x: -30, y: -6))
        wrist.addLine(to: CGPoint(x: 30, y: -6))
        wrist.addLine(to: CGPoint(x: 33, y: 30))
        wrist.addLine(to: CGPoint(x: -32, y: 30))
        wrist.closeSubpath()
        context.fill(wrist, with: .linearGradient(
            Gradient(colors: [skin, skinShade]), startPoint: CGPoint(x: -30, y: 0), endPoint: CGPoint(x: 34, y: 0)))

        // Cuff with its stitching and brass button.
        let cuff = Path(roundedRect: CGRect(x: -41, y: 16, width: 83, height: 33), cornerRadius: 3)
        context.fill(cuff, with: .linearGradient(
            Gradient(colors: [denim.mix(with: .white, by: 0.24), denim.mix(with: .black, by: 0.18)]),
            startPoint: CGPoint(x: -41, y: 16), endPoint: CGPoint(x: 42, y: 49)))
        context.stroke(cuff, with: .color(.black.opacity(0.35)), lineWidth: 0.6)
        for inset in [2.6, 30.4] {
            var stitch = Path()
            stitch.move(to: CGPoint(x: -38, y: 16 + inset))
            stitch.addLine(to: CGPoint(x: 39, y: 16 + inset))
            context.stroke(
                stitch, with: .color(Color(red: 0.92, green: 0.72, blue: 0.36).opacity(0.85)),
                style: StrokeStyle(lineWidth: 0.6, dash: [2.2, 1.3]))
        }
        let button = CGRect(x: 26, y: 27, width: 9, height: 9)
        context.fill(Path(ellipseIn: button), with: .radialGradient(
            Gradient(colors: [Color(red: 0.95, green: 0.80, blue: 0.48), Color(red: 0.55, green: 0.38, blue: 0.16)]),
            center: CGPoint(x: button.midX - 1.5, y: button.midY - 1.5), startRadius: 0, endRadius: 6))
        context.stroke(Path(ellipseIn: button.insetBy(dx: 1.6, dy: 1.6)), with: .color(.black.opacity(0.35)), lineWidth: 0.5)

        // Thumb, swung out to the side.
        var thumb = context
        thumb.translateBy(x: -33, y: -26)
        thumb.rotate(by: .degrees(-52))
        let thumbShape = capsule(length: 64, width: 22)
        skinFill(thumb, thumbShape, light: CGPoint(x: -11, y: -64), dark: CGPoint(x: 11, y: 0))
        var crease = Path()
        crease.move(to: CGPoint(x: -6.5, y: -33))
        crease.addQuadCurve(to: CGPoint(x: 6.5, y: -33), control: CGPoint(x: 0, y: -30.5))
        thumb.stroke(crease, with: .color(outline.opacity(0.30)), lineWidth: 0.6)
        let thumbNail = Path(roundedRect: CGRect(x: -7.2, y: -62, width: 14.4, height: 16), cornerRadius: 6)
        thumb.fill(thumbNail, with: .color(nail))
        thumb.stroke(thumbNail, with: .color(outline.opacity(0.28)), lineWidth: 0.45)

        // Back of the hand.
        var palm = Path()
        palm.move(to: CGPoint(x: -30, y: 4))
        palm.addCurve(to: CGPoint(x: -41, y: -52), control1: CGPoint(x: -36, y: -8), control2: CGPoint(x: -44, y: -30))
        palm.addCurve(to: CGPoint(x: -34, y: -90), control1: CGPoint(x: -40, y: -66), control2: CGPoint(x: -38, y: -84))
        palm.addCurve(to: CGPoint(x: 36, y: -80), control1: CGPoint(x: -16, y: -98), control2: CGPoint(x: 22, y: -96))
        palm.addCurve(to: CGPoint(x: 31, y: 4), control1: CGPoint(x: 44, y: -62), control2: CGPoint(x: 38, y: -20))
        palm.closeSubpath()
        skinFill(context, palm, light: CGPoint(x: -38, y: -90), dark: CGPoint(x: 40, y: 10))

        // Knuckles and tendons.
        for finger in fingers {
            let knuckle = CGRect(x: finger.x - 5.5, y: -88, width: 11, height: 9)
            context.fill(Path(ellipseIn: knuckle), with: .color(skinShade.opacity(0.38)))
            var tendon = Path()
            tendon.move(to: CGPoint(x: finger.x, y: -76))
            tendon.addLine(to: CGPoint(x: finger.x * 0.42, y: -22))
            context.stroke(tendon, with: .color(skinShade.opacity(0.13)), lineWidth: 1.6)
        }
    }

    /// The silhouette, for the shadow the hand throws on the desk.
    static func silhouette(curl: Double, point: Double) -> Path {
        var shape = Path()
        shape.addRoundedRect(in: CGRect(x: -41, y: -92, width: 82, height: 100), cornerSize: CGSize(width: 22, height: 22))
        shape.addRect(CGRect(x: -45, y: 8, width: 96, height: 322))
        for (index, finger) in fingers.enumerated() {
            let length = finger.length * (1 - 0.62 * (index == 0 ? curl * (1 - point) : curl))
            shape.addRoundedRect(
                in: CGRect(x: finger.x - finger.width / 2, y: -84 - length, width: finger.width, height: length + 10),
                cornerSize: CGSize(width: finger.width / 2, height: finger.width / 2))
        }
        shape.addPath(
            capsule(length: 64, width: 22),
            transform: CGAffineTransform(translationX: -33, y: -26).rotated(by: -52 * .pi / 180))
        return shape
    }
}

/// How the hand is held at one instant.
struct HandPose: Equatable {
    /// Where the wrist is, in scene millimetres.
    var wrist: CGPoint
    /// 0 = resting on the surface, 1 = lifted well clear of it.
    var lift: Double = 1
    /// 0 = fingers flat, 1 = fingers tucked into the palm.
    var curl: Double = 0
    /// 1 = the index finger stays out however curled the rest are.
    var point: Double = 0

    /// A hand lifted towards the eye looks a touch larger.
    var scale: CGFloat { 1 + 0.07 * lift }

    /// Scene position of the thumb pad in this pose.
    var thumbPad: CGPoint { wrist + HandArt.thumbPad.rotated(by: HandArt.reach) * scale }

    /// A pose that puts the index fingertip on `target`.
    static func pressing(_ target: CGPoint, lift: Double = 0) -> HandPose {
        var pose = HandPose(wrist: .zero, lift: lift, curl: 1, point: 1)
        pose.wrist = target - HandArt.fingertip.rotated(by: HandArt.reach) * pose.scale
        return pose
    }

    /// A pose that puts the thumb pad on `target`, fingers closed underneath.
    static func gripping(_ target: CGPoint, lift: Double = 0, curl: Double = 1) -> HandPose {
        var pose = HandPose(wrist: .zero, lift: lift, curl: curl, point: 0)
        pose.wrist = target - HandArt.thumbPad.rotated(by: HandArt.reach) * pose.scale
        return pose
    }

    static func mix(_ a: HandPose, _ b: HandPose, _ t: Double) -> HandPose {
        HandPose(
            wrist: Ease.mix(a.wrist, b.wrist, t),
            lift: Ease.mix(a.lift, b.lift, t),
            curl: Ease.mix(a.curl, b.curl, t),
            point: Ease.mix(a.point, b.point, t))
    }
}

extension CGPoint {
    func rotated(by angle: Angle) -> CGPoint {
        let c = cos(angle.radians)
        let s = sin(angle.radians)
        return CGPoint(x: x * c - y * s, y: x * s + y * c)
    }
}

/// One layer of the hand, positioned in the scene.
struct HandLayer: View {
    enum Part {
        case shadow
        case fingers
        case back
    }

    var pose: HandPose
    var part: Part

    @Environment(\.unit) private var unit

    var body: some View {
        Canvas { context, _ in
            var scaled = context
            scaled.scaleBy(x: unit, y: unit)
            let size = pose.scale
            switch part {
            case .shadow:
                scaled.translateBy(x: pose.wrist.x + 5 + 9 * pose.lift, y: pose.wrist.y + 7 + 14 * pose.lift)
                scaled.rotate(by: HandArt.reach)
                scaled.addFilter(.blur(radius: (2.5 + 6 * pose.lift) * unit / 2))
                scaled.fill(HandArt.silhouette(curl: pose.curl, point: pose.point), with: .color(.black.opacity(0.42 - 0.17 * pose.lift)))
            case .fingers:
                scaled.translateBy(x: pose.wrist.x, y: pose.wrist.y)
                scaled.rotate(by: HandArt.reach)
                scaled.scaleBy(x: size, y: size)
                HandArt.drawFingers(scaled, curl: pose.curl, point: pose.point)
            case .back:
                scaled.translateBy(x: pose.wrist.x, y: pose.wrist.y)
                scaled.rotate(by: HandArt.reach)
                scaled.scaleBy(x: size, y: size)
                HandArt.drawBack(scaled)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview("Hand") {
    let cassette = Cassette(title: "Summer demos '89", stock: .c60, design: .krom, position: 900_000)
    let grip = CGPoint(x: 150, y: 80)
    let pose = HandPose.gripping(grip, lift: 0.6)
    let pressing = HandPose.pressing(CGPoint(x: 300, y: 70), lift: 0)
    return ZStack(alignment: .topLeading) {
        Color(red: 0.42, green: 0.30, blue: 0.20)
        HandLayer(pose: pose, part: .shadow)
        HandLayer(pose: pose, part: .fingers)
        CassetteView(cassette: cassette)
            .shadow(color: .black.opacity(0.4), radius: 8, y: 8)
            .offset(x: (grip.x - HandArt.cassetteGrip.x) * 2.2, y: (grip.y - HandArt.cassetteGrip.y) * 2.2)
        HandLayer(pose: pose, part: .back)

        HandLayer(pose: pressing, part: .shadow)
        HandLayer(pose: pressing, part: .fingers)
        HandLayer(pose: pressing, part: .back)
        Circle().fill(.red).frame(width: 6, height: 6).position(x: 300 * 2.2, y: 70 * 2.2)
        Circle().fill(.green).frame(width: 6, height: 6).position(x: grip.x * 2.2, y: grip.y * 2.2)
    }
    .frame(width: 440 * 2.2, height: 300 * 2.2)
    .environment(\.unit, 2.2)
}
