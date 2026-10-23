import Foundation
import AppKit
import ApplicationServices

// MARK: - Optional helper tools (Homebrew ffmpeg, LibreOffice, iWork apps)

enum Helpers {
    static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ffmpeg: String? { firstExecutable(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]) }
    static var ffprobe: String? { firstExecutable(["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]) }
    static var cwebp: String? { firstExecutable(["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"]) }
    static var soffice: String? {
        firstExecutable(["/Applications/LibreOffice.app/Contents/MacOS/soffice",
                         NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice"])
    }

    static func appInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
    static var hasPages: Bool { appInstalled("com.apple.iWork.Pages") }
    static var hasKeynote: Bool { appInstalled("com.apple.iWork.Keynote") }
    static var hasNumbers: Bool { appInstalled("com.apple.iWork.Numbers") }

    static var ffmpegMissing: String { L("This needs ffmpeg. Install it with Homebrew:  brew install ffmpeg") }
    static var officeMissing: String { L("This needs LibreOffice. Install it with Homebrew:  brew install --cask libreoffice") }
    static var pagesMissing: String { L("This needs Apple's Pages app (free on the App Store).") }

    static func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bremorph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Moves a finished temp file to its final place.
    static func place(_ temp: URL, at final: URL) throws {
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: temp, to: final)
    }
}

final class DataBox: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: - ffmpeg runner

enum FF {
    static func run(_ args: [String], duration: Double? = nil, progress: ProgressHandler? = nil) throws {
        guard let ff = Helpers.ffmpeg else { throw BremorphError(Helpers.ffmpegMissing) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let errBox = DataBox()
        err.fileHandleForReading.readabilityHandler = { h in errBox.append(h.availableData) }
        out.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard let d = duration, d > 0, let progress = progress else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)) {
                    progress(min(0.99, max(0, us / 1_000_000 / d)))
                }
            }
        }
        try p.run()
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if p.terminationStatus != 0 {
            let lines = String(decoding: errBox.data, as: UTF8.self)
                .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            throw BremorphError(lines.isEmpty ? L("ffmpeg failed") : "ffmpeg: " + lines.suffix(2).joined(separator: " "))
        }
        progress?(1)
    }

    static func probe(_ url: URL, _ args: [String]) -> String? {
        guard let probe = Helpers.ffprobe else { return nil }
        return try? Shell.run(probe, ["-v", "error"] + args + [url.path])
    }

    static func duration(_ url: URL) -> Double? {
        guard let s = probe(url, ["-show_entries", "format=duration", "-of", "csv=p=0"]) else { return nil }
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// First video and audio codec names, e.g. ("h264", "aac").
    static func codecs(_ url: URL) -> (video: String?, audio: String?) {
        guard let s = probe(url, ["-show_entries", "stream=codec_type,codec_name", "-of", "csv=p=0"]) else { return (nil, nil) }
        var v: String? = nil, a: String? = nil
        for line in s.split(separator: "\n") {
            let parts = line.split(separator: ",").map(String.init)
            guard parts.count >= 2 else { continue }
            // csv order follows -show_entries: codec_name,codec_type
            let name = parts[0], type = parts[1]
            if type == "video" && v == nil && name != "mjpeg" && name != "png" { v = name }
            if type == "audio" && a == nil { a = name }
        }
        return (v, a)
    }

    static func size(_ url: URL) -> (Int, Int)? {
        guard let s = probe(url, ["-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x"]) else { return nil }
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static func tags(_ url: URL) -> [String: String] {
        guard let s = probe(url, ["-show_entries", "format_tags", "-of", "json"]),
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = obj["format"] as? [String: Any],
              let tags = format["tags"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in tags { out[k.lowercased()] = "\(v)" }
        return out
    }

    static let evenScale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    static func scaleLongSide(_ max: Int) -> String {
        "scale='if(gte(iw,ih),min(\(max),iw),-2)':'if(gte(iw,ih),-2,min(\(max),ih))',scale=trunc(iw/2)*2:trunc(ih/2)*2"
    }

    /// Encoder settings for each video container.
    static func videoCodecArgs(for ext: String) -> [String] {
        switch ext {
        case "webm":
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                    "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "128k"]
        case "avi":
            return ["-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "4", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv":
            return ["-c:v", "wmv2", "-q:v", "4", "-c:a", "wmav2", "-b:a", "192k"]
        case "mkv":
            return ["-c:v", "libx264", "-crf", "21", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        default:
            return ["-c:v", "libx264", "-crf", "21", "-preset", "veryfast", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        }
    }

    static let writableVideoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv"]
    static func outVideoExt(_ input: URL) -> String {
        let e = input.pathExtension.lowercased()
        return writableVideoExts.contains(e) ? e : "mp4"
    }
}

// MARK: - LibreOffice (headless)

enum Office {
    /// Converts with LibreOffice and returns the produced file (in a temp folder).
    static func convert(_ input: URL, to format: String, filter: String? = nil, infilter: String? = nil) throws -> URL {
        guard let soffice = Helpers.soffice else { throw BremorphError(Helpers.officeMissing) }
        let outDir = try Helpers.tempDir()
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("bremorph-lo-profile")
        var args = ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--norestore", "--nologo", "--nodefault", "--nolockcheck"]
        if let infilter = infilter { args.append("--infilter=" + infilter) }
        args += ["--convert-to", filter.map { "\(format):\($0)" } ?? format, "--outdir", outDir.path, input.path]
        try Shell.run(soffice, args)
        let produced = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        guard let file = produced.first(where: { $0.pathExtension.lowercased() == format.lowercased() }) ?? produced.first else {
            throw BremorphError(LF("LibreOffice couldn't convert %@", input.lastPathComponent))
        }
        return file
    }
}

// MARK: - iWork apps (Pages / Keynote / Numbers) via AppleScript

enum IWork {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func osascript(_ source: String) throws {
        do {
            try Shell.run("/usr/bin/osascript", ["-e", source])
        } catch {
            let msg = error.localizedDescription
            if msg.contains("-1743") || msg.contains("Not authorized") {
                throw BremorphError("Allow Bremorph to control the app: System Settings → Privacy & Security → Automation → Bremorph.")
            }
            throw error
        }
    }

    /// app: "Pages", "Keynote" or "Numbers". exportAs: AppleScript export format, or nil to save natively.
    static func convert(app: String, input: URL, output: URL, exportAs: String?) throws {
        let inP = escape(input.path), outP = escape(output.path)
        let action = exportAs.map { "export d to POSIX file \"\(outP)\" as \($0)" } ?? "save d in POSIX file \"\(outP)\""
        let script = """
        tell application "\(app)"
            set d to open POSIX file "\(inP)"
            \(action)
            close d saving no
        end tell
        """
        try osascript(script)
        guard FileManager.default.fileExists(atPath: output.path) else { throw BremorphError(LF("%@ didn't produce a file", app)) }
    }
}

// MARK: - Settings

enum ModifierChoice: String, CaseIterable, Identifiable {
    case shift, command, control, option, shiftCommand, shiftOption, controlOption, controlShift
    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return [.shift]
        case .command: return [.command]
        case .control: return [.control]
        case .option: return [.option]
        case .shiftCommand: return [.shift, .command]
        case .shiftOption: return [.shift, .option]
        case .controlOption: return [.control, .option]
        case .controlShift: return [.control, .shift]
        }
    }

    var symbols: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .shiftCommand: return "⇧⌘"
        case .shiftOption: return "⌥⇧"
        case .controlOption: return "⌃⌥"
        case .controlShift: return "⌃⇧"
        }
    }

    var name: String { String(label.split(separator: " ", maxSplits: 1).last ?? "") }

    var label: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .shiftCommand: return "⇧⌘ Shift + Command"
        case .shiftOption: return "⌥⇧ Option + Shift"
        case .controlOption: return "⌃⌥ Control + Option"
        case .controlShift: return "⌃⇧ Control + Shift"
        }
    }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case nextToOriginal, downloads, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nextToOriginal: return L("Next to the original file")
        case .downloads: return L("Downloads folder")
        case .custom: return L("A folder I choose")
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var convertKeys: ModifierChoice { didSet { d.set(convertKeys.rawValue, forKey: "keys.convert") } }
    @Published var toolsKeys: ModifierChoice { didSet { d.set(toolsKeys.rawValue, forKey: "keys.tools") } }
    @Published var actionsKeys: ModifierChoice { didSet { d.set(actionsKeys.rawValue, forKey: "keys.actions") } }
    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var returnInFinder: Bool {
        didSet {
            d.set(returnInFinder, forKey: "returnInFinder")
            if returnInFinder { ReturnKeyTap.start(prompt: true) } else { ReturnKeyTap.stop() }
        }
    }
    @Published var outputLocation: OutputLocation { didSet { d.set(outputLocation.rawValue, forKey: "output.location") } }
    @Published var customFolder: String { didSet { d.set(customFolder, forKey: "output.folder") } }

    private init() {
        convertKeys = ModifierChoice(rawValue: d.string(forKey: "keys.convert") ?? "") ?? .shift
        toolsKeys = ModifierChoice(rawValue: d.string(forKey: "keys.tools") ?? "") ?? .command
        actionsKeys = ModifierChoice(rawValue: d.string(forKey: "keys.actions") ?? "") ?? .control
        hotkeyEnabled = (d.object(forKey: "hotkeyEnabled") as? Bool) ?? true
        returnInFinder = d.bool(forKey: "returnInFinder")
        outputLocation = OutputLocation(rawValue: d.string(forKey: "output.location") ?? "") ?? .nextToOriginal
        customFolder = d.string(forKey: "output.folder") ?? ""
    }

    func keys(for mode: WheelMode) -> ModifierChoice {
        switch mode {
        case .convert: return convertKeys
        case .tools: return toolsKeys
        case .actions: return actionsKeys
        }
    }

    func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Use This Folder")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let u = panel.url {
            customFolder = u.path
            outputLocation = .custom
        }
    }

    /// Read from any thread (used by Paths).
    nonisolated static var outputFolderOverride: URL? {
        let d = UserDefaults.standard
        switch OutputLocation(rawValue: d.string(forKey: "output.location") ?? "") ?? .nextToOriginal {
        case .nextToOriginal: return nil
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .custom:
            let p = d.string(forKey: "output.folder") ?? ""
            return p.isEmpty ? nil : URL(fileURLWithPath: p, isDirectory: true)
        }
    }
}

// MARK: - Return key in Finder opens the wheel (needs Accessibility permission)

enum ReturnKeyTap {
    static var tap: CFMachPort?
    static var source: CFRunLoopSource?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    static func start(prompt: Bool) -> Bool {
        if tap != nil { return true }
        guard isTrusted else {
            if prompt { requestTrust() }
            return false
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = ReturnKeyTap.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
            if (code == 36 || code == 76) && mods.isEmpty && ReturnKeyTap.shouldIntercept() {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { WheelController.shared.showForFinderSelection() }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    static func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }

    /// Only when Finder is in front, our wheel isn't open, and Finder isn't editing text (renaming, searching).
    static func shouldIntercept() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.finder" else { return false }
        let wheelOpen: Bool = Thread.isMainThread ? MainActor.assumeIsolated { WheelController.shared.visible } : false
        if wheelOpen { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &role)
            let r = (role as? String) ?? ""
            if r == (kAXTextFieldRole as String) || r == (kAXTextAreaRole as String) || r == "AXSearchField" || r == "AXComboBox" {
                return false
            }
        }
        return true
    }
}
