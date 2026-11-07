import SwiftUI
import AppKit

/// Visual tokens for the card-based "glass" look.
enum Theme {
    static let cardRadius: CGFloat = 18
    static let gap: CGFloat = 10
    static let rowRadius: CGFloat = 8

    // Semantic system colours: the app follows the system's light/dark appearance, increased contrast and
    // the user's accent colour without us hard-coding hex values. (Fork change; see docs/p4-ui.md step 1.)
    static let ink = Color(nsColor: .labelColor)
    static let ink2 = Color(nsColor: .labelColor).opacity(0.82)           // read rows, toolbar labels
    static let muted = Color(nsColor: .secondaryLabelColor)                // counts, snippets, meta
    static let faint = Color(nsColor: .tertiaryLabelColor)                 // placeholders, read times
    static let hairline = Color(nsColor: .separatorColor)
    static let fieldFill = Color(nsColor: .quaternarySystemFill)
    static let selectedRow = Color(nsColor: .controlAccentColor).opacity(0.14)
    static let chip = Color(nsColor: .tertiarySystemFill)
    static let pillFill = Color(nsColor: .controlBackgroundColor)
    static let pillStroke = Color(nsColor: .separatorColor)
    /// Raised surfaces on a card or the ground: selected sidebar row, segmented control, file chips.
    static let raised = Color(nsColor: .controlBackgroundColor)
    /// Reply box at the bottom of a conversation.
    static let composerFill = Color(nsColor: .textBackgroundColor)
    static let composerStroke = Color(nsColor: .separatorColor)
    /// The "code" tile in the list (ink on light, cobalt-tinted on dark).
    static let codeTile = dynamic(light: "#16181D", dark: "#16213A")
    static let onCodeTile = dynamic(light: "#FFFFFF", dark: "#BFD1FF")

    static func card(_ scheme: ColorScheme) -> Color { Color(nsColor: .textBackgroundColor) }
    static let cardFill = Color(nsColor: .textBackgroundColor)
    /// Window ground behind the floating cards when the background is Solid.
    static func ground(_ scheme: ColorScheme) -> Color { Color(nsColor: .windowBackgroundColor) }
    static func sidebar(_ scheme: ColorScheme) -> Color { Color(nsColor: .windowBackgroundColor).opacity(0.9) }
    static func stroke(_ scheme: ColorScheme) -> Color { Color(nsColor: .separatorColor) }
    static func field(_ scheme: ColorScheme) -> Color { Color(nsColor: .quaternarySystemFill) }
    static func bubbleIn(_ scheme: ColorScheme) -> Color { Color(nsColor: .tertiarySystemFill) }

    /// The default accent ("Graphite" in upstream) now follows the system accent colour.
    static let graphiteHex = "#2B2F38"

    static func accent(_ hex: String) -> Color {
        Color(nsColor: .controlAccentColor)
    }
    /// Text/icon colour on top of a filled accent shape.
    static func onAccent(_ hex: String) -> Color {
        .white
    }
    /// Fill for primary buttons/bubbles.
    static func accentFill(_ hex: String) -> Color {
        Color(nsColor: .controlAccentColor)
    }
    static func dynamic(light: String, dark: String) -> Color {
        let l = NSColor(Color(hex: light)), d = NSColor(Color(hex: dark))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l })
    }

}

private struct AccentKey: EnvironmentKey { static let defaultValue: Color = .blue }
private struct OnAccentKey: EnvironmentKey { static let defaultValue: Color = .white }
private struct AccentFillKey: EnvironmentKey { static let defaultValue: Color = .blue }
extension EnvironmentValues {
    var accent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
    var accentFill: Color {
        get { self[AccentFillKey.self] }
        set { self[AccentFillKey.self] = newValue }
    }
    var onAccent: Color {
        get { self[OnAccentKey.self] }
        set { self[OnAccentKey.self] = newValue }
    }
}

/// SwiftUI keeps resetting the main window to "fullScreenNone" for some toolbar setups;
/// put full screen back whenever it does, so the green button and ⌃⌘F work.
enum WindowConfigurator {
    static func allowFullScreen(_ w: NSWindow) {
        guard w.collectionBehavior.contains(.fullScreenNone) || !w.collectionBehavior.contains(.fullScreenPrimary) else { return }
        w.collectionBehavior.remove(.fullScreenNone)
        w.collectionBehavior.insert(.fullScreenPrimary)
    }
}

/// Account picture: custom image if set, otherwise a monogram in the account colour.
struct AccountAvatar: View {
    var account: Account
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let img = AccountPictures.image(account.id) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Circle().fill(account.color.gradient)
                    Text(String(account.label.prefix(1)).uppercased())
                        .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.black.opacity(0.06)))
    }
}

enum AccountPictures {
    nonisolated(unsafe) private static var cache: [UUID: NSImage] = [:]
    static func url(_ id: UUID) -> URL { Paths.appSupport.appendingPathComponent("account-\(id.uuidString).png") }
    static func image(_ id: UUID) -> NSImage? {
        if let i = cache[id] { return i }
        guard let i = NSImage(contentsOf: url(id)) else { return nil }
        cache[id] = i
        return i
    }
    static func set(_ id: UUID, from source: URL) {
        guard let img = NSImage(contentsOf: source), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url(id))
        cache[id] = NSImage(data: png)
    }
}

/// Plain button with a soft hover fill (toolbar text buttons).
struct HoverPlainStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverPlainBody(configuration: configuration) }
}
private struct HoverPlainBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover || configuration.isPressed ? Theme.fieldFill : .clear))
            .onHover { hover = $0 }
    }
}
