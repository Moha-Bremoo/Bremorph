import SwiftUI
import AppKit

@main
struct BremorphApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = JobStore.shared

    init() {
        CLI.runIfRequested()
        AppLanguage.choose(AppLanguage.chosen)   // keeps the right-to-left setting in step with the chosen language
    }

    var body: some Scene {
        Window("Bremorph", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 580)
                .localizedLayout()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { store.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
                .localizedLayout()
        } label: {
            Image(nsImage: Brand.menuBarIcon)
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .tint(Brand.accent)
                .localizedLayout()
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: JobStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Bremorph") { showMain() }
        Button("Add Files to Convert…") {
            showMain()
            store.chooseFiles()
        }
        if !store.jobs.isEmpty {
            Divider()
            Text("Recent")
            ForEach(Array(store.jobs.prefix(6))) { job in
                Button(job.title) { job.reveal() }
            }
        }
        Divider()
        Toggle("Wheel While Dragging", isOn: $store.wheelEnabled)
        Button("Wheel for Finder Selection  ⌃⌥M") { WheelController.shared.showForFinderSelection() }
        Toggle("Open at Login", isOn: Binding(get: { store.openAtLogin }, set: { store.setOpenAtLogin($0) }))
        Divider()
        if #available(macOS 14.0, *) {
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
        } else {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",")
        }
        Button("Quit Bremorph") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showMain() {
        store.openMainWindow = { openWindow(id: "main") }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        MainActor.assumeIsolated {
            WheelController.shared.start()
        }
        HotKey.register {
            MainActor.assumeIsolated {
                if AppSettings.shared.hotkeyEnabled { WheelController.shared.showForFinderSelection() }
            }
        }
        MainActor.assumeIsolated {
            if AppSettings.shared.returnInFinder { ReturnKeyTap.start(prompt: false) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            JobStore.shared.add(urls)
            JobStore.shared.showWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in JobStore.shared.showWindow() }
        }
        return true
    }
}

/// Finder → right-click → Services / Quick Actions → "Convert with Bremorph"
final class ServiceProvider: NSObject {
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        Task { @MainActor in
            JobStore.shared.add(urls)
            JobStore.shared.showWindow()
        }
    }

    /// Finder → right-click → Services → "Crop & Edit with Bremorph"
    @objc func cropFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        Task { @MainActor in
            let images = urls.filter { FileKind.detect($0) == .image }
            if images.isEmpty {
                ToastController.shared.say(L("Crop & Edit works with images."))
            }
            for u in images.prefix(6) { ImageEditorWindows.open(u) }
        }
    }
}
