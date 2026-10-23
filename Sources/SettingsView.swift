import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            WheelSettings()
                .tabItem { Label("Wheel & Keys", systemImage: "circle.grid.cross") }
            HelperSettings()
                .tabItem { Label("Helpers", systemImage: "shippingbox") }
        }
        .frame(width: 560, height: 470)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var store: JobStore
    @ObservedObject var settings = AppSettings.shared
    @State private var language = AppLanguage.chosen

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bremorph").font(.system(size: 18, weight: .semibold))
                        Text(LF("Version %@ · Made by Mohammed Bremoo", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Results") {
                Picker("Save converted files", selection: $settings.outputLocation) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
                }
                if settings.outputLocation == .custom {
                    HStack {
                        Text(settings.customFolder.isEmpty ? L("No folder chosen") : settings.customFolder)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { settings.chooseCustomFolder() }
                    }
                }
                Toggle("Show results in Finder when done", isOn: $store.revealWhenDone)
            }
            Section("Language") {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                if language != AppLanguage.chosen {
                    HStack {
                        Text("Bremorph needs to restart to switch language.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") {
                            AppLanguage.choose(language)
                            AppLanguage.relaunch()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            Section("Startup") {
                Toggle("Open Bremorph at login", isOn: Binding(get: { store.openAtLogin }, set: { store.setOpenAtLogin($0) }))
                Text("Bremorph needs to be running (it lives in the menu bar) for the wheel to appear in Finder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Everything happens on this Mac. Files are never uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct WheelSettings: View {
    @EnvironmentObject var store: JobStore
    @ObservedObject var settings = AppSettings.shared
    @State private var trusted = ReturnKeyTap.isTrusted

    var body: some View {
        Form {
            Section("While dragging files") {
                Toggle("Show the wheel while dragging", isOn: $store.wheelEnabled)
                keyPicker(L("Convert wheel"), $settings.convertKeys)
                keyPicker(L("Tools wheel"), $settings.toolsKeys)
                keyPicker(L("Actions wheel"), $settings.actionsKeys)
                Text("Start dragging, then hold the keys. You can let go of the keys and keep dragging; drop on a slice, or on the centre to cancel.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Selected files in Finder") {
                Toggle("Press Return in Finder to open the wheel", isOn: $settings.returnInFinder)
                if settings.returnInFinder && !trusted {
                    HStack {
                        Text("Needs Accessibility permission.").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings…") {
                            ReturnKeyTap.requestTrust()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        Button("Check Again") {
                            trusted = ReturnKeyTap.isTrusted
                            if trusted { ReturnKeyTap.start(prompt: false) }
                        }
                    }
                }
                Text("Return still renames when you're already editing a name. To rename with this on, click the file's name once more.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("⌃⌥M opens the wheel for the Finder selection", isOn: $settings.hotkeyEnabled)
            }
            Section("Inside the wheel") {
                Text("Arrow keys move between slices and Return picks one. Number keys 1 to 9 jump straight to a slice. Tab, or a click in the centre, switches wheels. Esc closes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = ReturnKeyTap.isTrusted }
    }

    private func keyPicker(_ label: String, _ binding: Binding<ModifierChoice>) -> some View {
        Picker(label, selection: binding) {
            ForEach(ModifierChoice.allCases) { Text($0.label).tag($0) }
        }
    }
}

struct HelperSettings: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("Optional helpers") {
                row("ffmpeg", Helpers.ffmpeg, L("MP3, OGG, Opus, WMA, MKV, WebM, AVI, WMV, AVIF, Crop Video, and files macOS can't open"),
                    install: "brew install ffmpeg")
                row("LibreOffice", Helpers.soffice, L("PowerPoint, Excel, ODS/ODT, CSV/TSV and best-quality Word ⇄ PDF"),
                    install: "brew install --cask libreoffice")
                row(L("WebP encoder"), Helpers.cwebp ?? (ImageOps.writable.contains("org.webmproject.webp") ? "built in" : nil),
                    L("Saving images as WebP"), install: "brew install webp")
                row("Pages", Helpers.hasPages ? "installed" : nil, L("Pages documents"), install: nil)
                row("Keynote", Helpers.hasKeynote ? "installed" : nil, L("Keynote presentations"), install: nil)
                row("Numbers", Helpers.hasNumbers ? "installed" : nil, L("Numbers spreadsheets"), install: nil)
            }
            Section {
                Text("Bremorph finds these automatically. Everything else works without them.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Check Again") { refresh += 1 }
            }
        }
        .formStyle(.grouped)
        .id(refresh)
    }

    private func row(_ name: String, _ found: String?, _ what: String, install: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: found != nil ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(found != nil ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium))
                Text(what).font(.caption).foregroundStyle(.secondary)
                if found == nil, let cmd = install {
                    HStack(spacing: 6) {
                        Text(cmd).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
