import Foundation
import AppKit
import SwiftUI

// MARK: - Localized text
//
// Keys are the English strings themselves. Translations live in Resources/<lang>.lproj/Localizable.strings,
// and plural forms (e.g. "%d files") in Localizable.stringsdict. SwiftUI string literals such as Text("Clear")
// are looked up automatically; everything else goes through L() / LF().

/// Translates a fixed piece of UI text.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Keeps a left-to-right fragment (sizes, "1280 × 720 px", "2 MB → 1 MB") in order inside Arabic text.
func ltr(_ s: String) -> String { "\u{2066}" + s + "\u{2069}" }

/// Translates a format string and fills it in (plural rules come from Localizable.stringsdict).
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

// MARK: - App language

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ar
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("Same as macOS")
        case .en: return "English"
        case .ar: return "العربية"
        }
    }

    private static var domain: String { Bundle.main.bundleIdentifier ?? "com.mohammedbremoo.bremorph" }

    /// The language chosen in Bremorph's own settings (not the system-wide list).
    static var chosen: AppLanguage {
        let langs = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String]
        guard let first = langs?.first else { return .system }
        if first.hasPrefix("ar") { return .ar }
        if first.hasPrefix("en") { return .en }
        return .system
    }

    /// The language the running app is actually using.
    static var active: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// True when the running app shows a right-to-left language (Arabic).
    static var isRTL: Bool {
        Locale.Language(identifier: active).characterDirection == .rightToLeft
    }

    static func choose(_ lang: AppLanguage) {
        let d = UserDefaults.standard
        if lang == .system {
            d.removeObject(forKey: "AppleLanguages")
        } else {
            d.set([lang.rawValue], forKey: "AppleLanguages")
        }
        // Mirror AppKit parts (menus, panels) too when the app runs in Arabic on a non-Arabic Mac.
        let rtl = lang == .ar || (lang == .system && Locale.Language(identifier: Locale.preferredLanguages.first ?? "en").characterDirection == .rightToLeft)
        if rtl { d.set(true, forKey: "AppleTextDirection") } else { d.removeObject(forKey: "AppleTextDirection") }
        d.synchronize()
    }

    /// Quits and reopens Bremorph so the new language takes effect everywhere.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

extension View {
    /// Lays the view out right-to-left when Bremorph runs in Arabic.
    func localizedLayout() -> some View {
        environment(\.layoutDirection, AppLanguage.isRTL ? .rightToLeft : .leftToRight)
            .environment(\.locale, Locale(identifier: AppLanguage.active))
    }
}
