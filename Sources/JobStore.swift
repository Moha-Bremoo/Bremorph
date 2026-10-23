import SwiftUI
import AppKit
import ServiceManagement

enum JobState: Equatable {
    case queued, running, done, failed(String)
}

@MainActor
final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    @Published var progress: Double = 0
    @Published var state: JobState = .queued
    @Published var outputs: [URL] = []
    @Published var message: String?

    init(title: String) { self.title = title }

    var statusSymbol: String {
        switch state {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isFinished: Bool {
        switch state {
        case .done, .failed: return true
        default: return false
        }
    }

    func reveal() {
        let existing = outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
    }
}

@MainActor
final class JobStore: ObservableObject {
    static let shared = JobStore()

    @Published var files: [URL] = []
    @Published var jobs: [Job] = []
    @Published var revealWhenDone: Bool = (UserDefaults.standard.object(forKey: "revealWhenDone") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(revealWhenDone, forKey: "revealWhenDone") }
    }

    @Published var wheelEnabled: Bool = (UserDefaults.standard.object(forKey: "wheelEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(wheelEnabled, forKey: "wheelEnabled") }
    }
    @Published var pendingAction: ActionID?
    @Published var openAtLogin: Bool = SMAppService.mainApp.status == .enabled

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            ToastController.shared.say(LF("Couldn't change Open at Login: %@", error.localizedDescription))
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    var openMainWindow: (() -> Void)?
    private var tail: Task<Void, Never>?

    var kindsPresent: [FileKind] {
        let set = Set(files.map { FileKind.detect($0) })
        return FileKind.allCases.filter { set.contains($0) }
    }

    func count(of kind: FileKind) -> Int { files.filter { FileKind.detect($0) == kind }.count }
    func targets(for action: ActionID) -> [URL] { files.filter { action.accepts($0) } }

    func add(_ urls: [URL]) {
        for u in urls where !files.contains(u) { files.append(u) }
    }

    func remove(_ url: URL) { files.removeAll { $0 == url } }
    func clearFiles() { files.removeAll() }
    func clearFinished() { jobs.removeAll { $0.isFinished } }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = L("Add")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Bremorph" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    static func openWindow(for action: ActionID, urls: [URL]) {
        for u in urls.prefix(6) {
            switch action {
            case .imgEdit: ImageEditorWindows.open(u)
            case .vidCrop: ImageEditorWindows.openVideo(u)
            case .pdfOrganize: OrganizerWindows.open(u)
            case .editMeta: MetadataWindows.open(u)
            default: break
            }
        }
    }

    /// Runs any work as a tracked job (used by editor windows).
    @discardableResult
    func runCustom(title: String, work: @escaping @Sendable (@escaping ProgressHandler) async throws -> EngineResult) -> Job {
        let job = Job(title: title)
        jobs.insert(job, at: 0)
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            job.state = .running
            do {
                let result = try await Task.detached {
                    try await work { p in Task { @MainActor in if job.state == .running { job.progress = p } } }
                }.value
                job.outputs = result.outputs
                job.message = result.message
                job.progress = 1
                job.state = .done
                if self?.revealWhenDone == true, !result.outputs.isEmpty { job.reveal() }
            } catch {
                job.state = .failed(error.localizedDescription)
            }
        }
        return job
    }

    @discardableResult
    func run(_ action: ActionID, options: ActionOptions, on urls: [URL]? = nil) -> [Job] {
        let targets = (urls ?? files).filter { action.accepts($0) }
        guard targets.count >= action.info.minFiles, !targets.isEmpty else { return [] }
        if action.info.opensWindow {
            JobStore.openWindow(for: action, urls: targets)
            return []
        }
        var created: [Job] = []
        let batches: [[URL]] = action.info.combines ? [targets] : targets.map { [$0] }
        for batch in batches {
            let title = batch.count > 1
                ? action.info.title + " · " + LF("%d files", batch.count)
                : "\(action.info.title) · \(batch[0].lastPathComponent)"
            let job = Job(title: title)
            jobs.insert(job, at: 0)
            created.append(job)
            let previous = tail
            tail = Task { [weak self] in
                await previous?.value
                job.state = .running
                do {
                    let result = try await Engine.run(action, inputs: batch, options: options) { p in
                        Task { @MainActor in
                            if job.state == .running { job.progress = p }
                        }
                    }
                    job.outputs = result.outputs
                    job.message = result.message
                    job.progress = 1
                    job.state = .done
                    if self?.revealWhenDone == true, !result.outputs.isEmpty { job.reveal() }
                } catch {
                    job.state = .failed(error.localizedDescription)
                }
            }
        }
        return created
    }
}
