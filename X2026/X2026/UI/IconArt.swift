import SwiftUI

/// The app icon: a cassette on the machine's own black plastic.
///
/// The PNGs in the asset catalogue are rendered from this view (run the debug
/// build with `--render-icon <folder>`), so the icon is drawn by the same
/// code as the cassettes in the app.
struct IconArt: View {
    /// Edge of the full icon canvas in points.
    var side: CGFloat

    var body: some View {
        let tile = side * 0.805
        let cassette = Cassette(title: "X-2026", stock: .c60, design: .studio, position: 9_000_000)
        ZStack {
            RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(white: 0.20), Color(white: 0.085), Color(white: 0.04)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom),
                            lineWidth: max(1, tile * 0.006))
                )
                .frame(width: tile, height: tile)
                .shadow(color: .black.opacity(0.35), radius: side * 0.02, y: side * 0.012)

            // A band of the house orange, like the stripe on the box.
            RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                .fill(Theme.brandOrange)
                .frame(width: tile, height: tile)
                .mask(
                    Rectangle()
                        .frame(width: tile, height: tile * 0.07)
                        .offset(y: tile * 0.30)
                )

            CassetteView(cassette: cassette)
                .environment(\.unit, tile * 0.0082)
                .rotationEffect(.degrees(-7))
                .shadow(color: .black.opacity(0.65), radius: tile * 0.03, x: tile * 0.012, y: tile * 0.03)
                .offset(y: -tile * 0.035)
        }
        .frame(width: side, height: side)
    }

    #if DEBUG
    static var isRequested: Bool { CommandLine.arguments.contains("--render-icon") }

    /// Writes the icon at every size macOS wants into the folder named after
    /// `--render-icon`.
    @MainActor
    static func renderAll() {
        guard let flag = CommandLine.arguments.firstIndex(of: "--render-icon"),
              CommandLine.arguments.count > flag + 1
        else { return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            let renderer = ImageRenderer(content: IconArt(side: CGFloat(pixels)))
            renderer.scale = 1
            guard let image = renderer.cgImage else { continue }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
            let url = folder.appending(path: "icon_\(pixels).png")
            do {
                try data.write(to: url)
                print("[icon] wrote \(url.path(percentEncoded: false))")
            } catch {
                print("[icon] could not write \(url.lastPathComponent): \(error)")
            }
        }
    }
    #endif
}

#Preview("Icon") {
    HStack(spacing: 24) {
        IconArt(side: 512)
        VStack(spacing: 16) {
            IconArt(side: 128)
            IconArt(side: 64)
            IconArt(side: 32)
        }
    }
    .padding(30)
    .background(Color(white: 0.75))
}
