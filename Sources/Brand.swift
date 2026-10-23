import SwiftUI
import AppKit

// MARK: - Brand tokens
//
// Graphite and one signal colour. Neutrals come from the system so light and dark mode both work;
// lime is used for the thing you're about to act on (hovered slice, primary button, progress), nothing else.
// Format names and numbers are set in SF Mono, so they read like the file extensions they are.

enum Brand {
    /// Signal lime, used as a fill. Text on it is always `ink`.
    static let nsSignal = NSColor(srgbRed: 0.788, green: 0.949, blue: 0.243, alpha: 1)      // #C9F23E
    static let nsSignalPressed = NSColor(srgbRed: 0.690, green: 0.851, blue: 0.180, alpha: 1)
    static let nsInk = NSColor(srgbRed: 0.063, green: 0.071, blue: 0.067, alpha: 1)          // #101211
    /// Accent for text, icons and control tint: lime on dark backgrounds, deep olive on light ones (WCAG AA on both).
    static let nsAccent = NSColor(name: "BremorphAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? nsSignal
            : NSColor(srgbRed: 0.278, green: 0.373, blue: 0.000, alpha: 1)                    // #475F00
    }

    static let signal = Color(nsColor: nsSignal)
    static let signalPressed = Color(nsColor: nsSignalPressed)
    static let ink = Color(nsColor: nsInk)
    static let accent = Color(nsColor: nsAccent)

    /// Hairlines and quiet fills, derived from the label colour so they adapt to the appearance.
    static let hairline = Color.primary.opacity(0.10)
    static let fill = Color.primary.opacity(0.045)
    static let fillHover = Color.primary.opacity(0.08)

    enum Radius {
        static let tile: CGFloat = 10
        static let panel: CGFloat = 14
        static let card: CGFloat = 16
    }

    enum Motion {
        static let hover = Animation.easeOut(duration: 0.12)
        static let press = Animation.easeOut(duration: 0.08)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// SF Mono for Latin labels such as "WebP"; the regular system font for Arabic, which has no monospaced design.
    static func code(_ text: String, _ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        let arabic = text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0xFE70...0xFEFF).contains($0.value) }
        return .system(size: size, weight: weight, design: arabic ? .default : .monospaced)
    }

    /// Template "B" for the menu bar (falls back to a symbol).
    static let menuBarIcon: NSImage = {
        if let img = NSImage(named: "MenuBarIcon") {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        let fallback = NSImage(systemSymbolName: "doc.badge.arrow.up", accessibilityDescription: "Bremorph") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }()
}

// MARK: - Vibrancy

/// A live blur of whatever is behind the window (or view).
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = emphasized
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// The window background: the system's own translucent material, no decoration.
struct AppBackground: View {
    var body: some View {
        ZStack {
            VisualEffect(material: .underWindowBackground, blending: .behindWindow)
            // Mostly solid, so the window reads as graphite (or paper in light mode) rather than tinted by the wallpaper.
            Color(nsColor: .windowBackgroundColor).opacity(0.86)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Surfaces

extension View {
    /// A floating card (toasts, the shortcuts card). Liquid Glass on macOS 26, a material before that.
    @ViewBuilder
    func floatingCard(cornerRadius: CGFloat = Brand.Radius.card) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Brand.hairline))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
    }

    /// A flat panel inside the window (file list, actions, activity).
    func panel(cornerRadius: CGFloat = Brand.Radius.panel) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Brand.fill))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Brand.hairline))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Buttons

/// The one loud button on a screen: lime with dark text.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Brand.signalPressed : Brand.signal)
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.12)))
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Brand.Motion.press, value: configuration.isPressed)
    }
}

/// A quiet button that sits on any surface.
struct SecondaryButtonStyle: ButtonStyle {
    var compact = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.14) : (hovering ? Brand.fillHover : Brand.fill))
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.hairline))
            .onHover { h in withAnimation(Brand.Motion.hover) { hovering = h } }
            .animation(Brand.Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Small parts

/// A keycap showing a keyboard shortcut.
struct KeyChip: View {
    let keys: String
    var body: some View {
        Text(keys)
            .font(Brand.mono(11.5, .semibold))
            .frame(minWidth: 40)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Brand.hairline))
            .environment(\.layoutDirection, .leftToRight)   // shortcuts read the same in every language
    }
}

/// A small square holding a section's symbol.
struct SymbolBadge: View {
    let symbol: String
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(Brand.accent)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Brand.hairline))
    }
}

/// A thin progress bar in the signal colour.
struct SignalProgress: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Brand.signal)
                    .frame(width: max(4, g.size.width * min(1, max(0, value))))
                    .animation(.easeOut(duration: 0.2), value: value)
            }
        }
        .frame(height: 4)
    }
}
