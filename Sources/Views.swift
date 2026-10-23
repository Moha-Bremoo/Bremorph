import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var store: JobStore
    @Environment(\.openWindow) private var openWindow
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 12) {
            HeaderBar()
            if store.files.isEmpty {
                DropZone(targeted: targeted)
            } else {
                HStack(spacing: 12) {
                    FileListView()
                        .frame(width: 290)
                        .panel()
                    ActionsView(pending: $store.pendingAction)
                        .frame(minWidth: 460, maxWidth: .infinity)
                        .panel()
                }
                .overlay(
                    targeted ? RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous)
                        .strokeBorder(Brand.signal, lineWidth: 2) : nil
                )
            }
            if !store.jobs.isEmpty {
                JobsView()
                    .frame(height: 170)
                    .panel()
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .background(AppBackground())
        .tint(Brand.accent)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            handleDrop(providers)
            return true
        }
        .sheet(item: $store.pendingAction) { action in
            OptionsSheet(action: action)
                .environmentObject(store)
                .tint(Brand.accent)
        }
        .onAppear {
            store.openMainWindow = { openWindow(id: "main") }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let s = store
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in s.add([url]) }
                }
            }
        }
    }
}

struct HeaderBar: View {
    @EnvironmentObject var store: JobStore
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("Bremorph")
                    .font(.system(size: 17, weight: .semibold))
                Text("Convert, compress and edit files. Nothing leaves your Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            settingsButton
            Button {
                store.chooseFiles()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        // Room for the window buttons, which stay on the left even in right-to-left languages.
        .padding(.leading, direction == .leftToRight ? 72 : 4)
        .padding(.trailing, direction == .leftToRight ? 4 : 72)
        .frame(height: 52)
    }

    @ViewBuilder private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Settings")
        }
    }
}

struct DropZone: View {
    @EnvironmentObject var store: JobStore
    let targeted: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
                .fill(targeted ? Brand.signal.opacity(0.08) : Brand.fill)
            RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
                .strokeBorder(targeted ? Brand.signal : Color.primary.opacity(0.16),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [6, 5]))

            VStack(spacing: 14) {
                ConversionGlyph(active: targeted)
                    .padding(.bottom, 6)

                Text("Drop files or folders here")
                    .font(.system(size: 22, weight: .semibold))
                Text("Images · Video · Audio · PDF · Documents · Slides · Sheets · Subtitles · Archives")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    store.chooseFiles()
                } label: {
                    Text("Choose Files…")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
                ShortcutsCard()
                    .padding(.top, 18)
            }
            .padding(30)
        }
    }
}

/// Two files with the brand's folded corner: one going in, one coming out. Says what the app does without words.
struct ConversionGlyph: View {
    var active = false
    @Environment(\.layoutDirection) private var direction
    private var sign: CGFloat { direction == .rightToLeft ? -1 : 1 }

    var body: some View {
        HStack(spacing: 14) {
            card(".heic", filled: false)
                .rotationEffect(.degrees(active ? -2 : -6))
                .offset(x: active ? 6 * sign : 0)
            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .flipsForRightToLeftLayoutDirection(true)
            card(".jpg", filled: true)
                .rotationEffect(.degrees(active ? 2 : 5))
                .offset(x: active ? -6 * sign : 0)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: active)
    }

    private func card(_ ext: String, filled: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            FolderCornerShape()
                .fill(filled ? Brand.signal : Color.primary.opacity(0.06))
            FolderCornerShape()
                .stroke(filled ? Color.black.opacity(0.15) : Color.primary.opacity(0.25), lineWidth: 1)
            FoldFlapShape()
                .fill(filled ? Color.black.opacity(0.22) : Color.primary.opacity(0.12))
            Text(ext)
                .font(Brand.mono(11, .semibold))
                .foregroundStyle(filled ? Brand.ink : Color.secondary)
                .padding(8)
        }
        .frame(width: 56, height: 70)
        .shadow(color: .black.opacity(filled ? 0.18 : 0), radius: 8, y: 4)
    }
}

/// A page with its top-right corner folded, as in the app icon.
struct FolderCornerShape: Shape {
    func path(in r: CGRect) -> Path {
        let fold = min(r.width, r.height) * 0.28
        let rad: CGFloat = 6
        var p = Path()
        p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.maxX - rad, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rad), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// The folded-over flap that goes with `FolderCornerShape`.
struct FoldFlapShape: Shape {
    func path(in r: CGRect) -> Path {
        let fold = min(r.width, r.height) * 0.28
        var p = Path()
        p.move(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.closeSubpath()
        return p
    }
}

struct ShortcutsCard: View {
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or skip this window. Bremorph works from Finder while it sits in your menu bar.")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            shortcut(settings.convertKeys.symbols, LF("Hold %@ while dragging files", settings.convertKeys.name), L("Convert wheel"))
            shortcut(settings.toolsKeys.symbols, LF("Hold %@ while dragging", settings.toolsKeys.name), L("Tools wheel"))
            shortcut(settings.actionsKeys.symbols, LF("Hold %@ while dragging", settings.actionsKeys.name), L("Actions wheel"))
            if settings.returnInFinder {
                shortcut("↩", L("Select files in Finder, press Return"), L("Wheel at your pointer"))
            }
            shortcut("⌃⌥M", L("Select files in Finder, press Control + Option + M"), L("Wheel at your pointer"))
            shortcut("…", L("Right-click files → Services"), L("Convert / Crop & Edit"))
        }
        .padding(16)
        .frame(maxWidth: 580, alignment: .leading)
        .panel(cornerRadius: 12)
    }

    private func shortcut(_ keys: String, _ how: String, _ what: String) -> some View {
        HStack(spacing: 10) {
            KeyChip(keys: keys)
            Text(how).font(.caption)
            Spacer(minLength: 6)
            Text(what).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - File list

struct FileListView: View {
    @EnvironmentObject var store: JobStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LF("%d files", store.files.count))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") { store.clearFiles() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.files, id: \.self) { url in
                        FileRow(url: url)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }
}

struct FileRow: View {
    @EnvironmentObject var store: JobStore
    let url: URL
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(FileKind.detect(url).title) · \(sizeText)")
                    .font(Brand.code(FileKind.detect(url).title + sizeText, 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    store.remove(url)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Brand.fillHover : Color.clear)
        )
        .onHover { h in withAnimation(Brand.Motion.hover) { hovering = h } }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            switch FileKind.detect(url) {
            case .image: ImageEditorWindows.open(url)
            case .pdf: OrganizerWindows.open(url)
            default: break
            }
        }
        .contextMenu {
            if FileKind.detect(url) == .image {
                Button("Crop & Edit…") { ImageEditorWindows.open(url) }
            }
            if FileKind.detect(url) == .pdf {
                Button("Organize Pages…") { OrganizerWindows.open(url) }
            }
            if [.image, .video, .audio, .pdf].contains(FileKind.detect(url)) {
                Button("Edit Metadata…") { MetadataWindows.open(url) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove from List") { store.remove(url) }
        }
    }

    private var sizeText: String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if FileKind.detect(url) == .folder { return L("Folder") }
        return ByteCountFormatter().string(fromByteCount: size)
    }
}

// MARK: - Actions

struct ActionsView: View {
    @EnvironmentObject var store: JobStore
    @Binding var pending: ActionID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(store.kindsPresent) { kind in
                    if kind != .folder && kind != .other {
                        KindSection(kind: kind, trigger: trigger)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: L("All files"), symbol: "tray.full", count: store.files.count)
                    ActionGrid(actions: ActionID.universalActions, trigger: trigger)
                }
            }
            .padding(20)
        }
    }

    private func trigger(_ action: ActionID) {
        if action.info.fields.isEmpty {
            store.run(action, options: ActionOptions())
        } else {
            pending = action
        }
    }
}

struct SectionHeader: View {
    let title: String
    let symbol: String
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            SymbolBadge(symbol: symbol)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text("\(count)")
                .font(Brand.mono(11, .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct KindSection: View {
    @EnvironmentObject var store: JobStore
    let kind: FileKind
    let trigger: (ActionID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: kind.title, symbol: kind.symbol, count: store.count(of: kind))
            ForEach([ActionGroup.convert, ActionGroup.tools], id: \.self) { group in
                let actions = ActionID.actions(for: kind, group: group)
                if !actions.isEmpty {
                    Text(group.title.uppercased())
                        .font(Brand.code(group.title, 10, .semibold))
                        .tracking(AppLanguage.isRTL ? 0 : 0.8)   // letter-spacing breaks Arabic joining
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ActionGrid(actions: actions, trigger: trigger)
                }
            }
        }
    }
}

struct ActionGrid: View {
    @EnvironmentObject var store: JobStore
    let actions: [ActionID]
    let trigger: (ActionID) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
            ForEach(actions) { action in
                let n = store.targets(for: action).count
                ActionTile(action: action, enabled: n >= action.info.minFiles && n > 0 && action.isAvailable) {
                    trigger(action)
                }
                .help(helpText(action, n))
            }
        }
    }

    private func helpText(_ a: ActionID, _ n: Int) -> String {
        if !a.isAvailable { return a.missingHelpText }
        if n < a.info.minFiles { return LF("Add at least %d files for this", a.info.minFiles) }
        if a.info.combines { return a.info.title + ": " + LF("combines %d files into one", n) }
        return a.info.title + ": " + LF("%d files", n)
    }
}

struct ActionTile: View {
    let action: ActionID
    let enabled: Bool
    let perform: () -> Void
    @State private var hovering = false

    private var lit: Bool { hovering && enabled }

    var body: some View {
        Button(action: perform) {
            VStack(spacing: 5) {
                if action.info.group == .convert {
                    // Formats are set like file extensions.
                    Text(action.info.title)
                        .font(Brand.code(action.info.title, 13.5, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Image(systemName: action.info.symbol)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(lit ? Brand.ink : Brand.accent)
                    Text(action.info.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(lit ? Brand.ink : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous)
                    .fill(lit ? Brand.signal : Brand.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous)
                    .strokeBorder(lit ? Color.black.opacity(0.12) : Brand.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { h in withAnimation(Brand.Motion.hover) { hovering = h } }
    }
}

/// Presses a tile down by a pixel instead of shrinking it.
struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 1 : 0)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(Brand.Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Options sheet

struct OptionsSheet: View {
    let action: ActionID
    @EnvironmentObject var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @State private var o = ActionOptions()
    @State private var durationText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SymbolBadge(symbol: action.info.symbol, size: 30)
                Text(action.info.title).font(.system(size: 19, weight: .semibold))
            }
            let n = store.targets(for: action).count
            Text(action.info.combines ? LF("Combines %d files into one.", n) : LF("Applies to %d files.", n))
                .foregroundStyle(.secondary)
            if let d = durationText {
                Text(d).font(.caption).foregroundStyle(.secondary)
            }
            Form {
                ForEach(action.info.fields, id: \.self) { f in
                    field(f)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Run") {
                    store.run(action, options: o)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await loadDuration() }
    }

    @ViewBuilder
    private func field(_ f: OptionField) -> some View {
        switch f {
        case .quality:
            VStack(alignment: .leading) {
                Text(LF("Quality: %d%%", Int(o.quality * 100)))
                Slider(value: $o.quality, in: 0.1...1.0)
                Text("Lower quality = smaller file.").font(.caption).foregroundStyle(.secondary)
            }
        case .maxDimension:
            Picker("Longest side", selection: $o.maxDimension) {
                ForEach([480, 640, 1024, 1280, 1600, 1920, 2560, 3840], id: \.self) { Text("\($0) px").tag($0) }
            }
        case .trim:
            NumberField(label: "Start (seconds)", value: $o.start)
            NumberField(label: "End (seconds)", value: $o.end)
        case .speed:
            Picker("Speed", selection: $o.speed) {
                ForEach([0.25, 0.5, 0.75, 1.25, 1.5, 2.0, 3.0, 4.0, 8.0], id: \.self) { v in
                    Text(String(format: "%gx", v)).tag(v)
                }
            }
        case .sizeTarget:
            Picker("Aim for", selection: $o.sizeByPercent) {
                Text("A percentage of the original").tag(true)
                Text("An exact size").tag(false)
            }
            .pickerStyle(.radioGroup)
            if o.sizeByPercent {
                VStack(alignment: .leading) {
                    Text(LF("%d%% of the original size", Int(o.sizePercent)))
                    Slider(value: $o.sizePercent, in: 5...95, step: 5)
                }
            } else {
                NumberField(label: "Target size (MB)", value: $o.targetMB)
                Text("For small files, use decimals: 0.5 MB is 500 KB.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Bremorph lowers quality (and size, if needed) to land just under the target.")
                .font(.caption).foregroundStyle(.secondary)
        case .split:
            Picker("Split", selection: $o.splitMode) {
                Text("Into equal parts").tag(SplitMode.parts)
                Text("Every N seconds").tag(SplitMode.seconds)
            }
            .pickerStyle(.radioGroup)
            NumberField(label: o.splitMode == .parts ? L("Number of parts") : L("Seconds per part"), value: $o.splitValue)
            Text("Cuts happen at the nearest keyframe, so parts may differ by a fraction of a second.")
                .font(.caption).foregroundStyle(.secondary)
        case .snapshotTime:
            NumberField(label: "Time (seconds)", value: $o.snapshotTime)
        case .pageRange:
            TextField("Page range", text: $o.pageRange, prompt: Text("e.g. 1-3, 5, 8-"))
        case .rotation:
            Picker("Rotate", selection: $o.rotation) {
                Text("90° clockwise").tag(90)
                Text("180°").tag(180)
                Text("90° counter-clockwise").tag(270)
            }
        case .videoQuality:
            Picker("Quality", selection: $o.videoQuality) {
                ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
            }
        case .gif:
            NumberField(label: "Start (seconds)", value: $o.start)
            NumberField(label: "End (seconds)", value: $o.end)
            Picker("Frames per second", selection: $o.gifFPS) {
                ForEach([5, 8, 10, 12, 15, 20, 24], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Width", selection: $o.gifWidth) {
                ForEach([240, 320, 480, 640, 800], id: \.self) { Text("\($0) px").tag($0) }
            }
        case .collage:
            Stepper(LF("Columns: %d", o.columns), value: $o.columns, in: 1...6)
        case .pdfStrength:
            Picker("Method", selection: $o.pdfStrong) {
                Text("Standard: text stays selectable").tag(false)
                Text("Strong: smallest file, pages become images").tag(true)
            }
            .pickerStyle(.radioGroup)
            if o.pdfStrong {
                VStack(alignment: .leading) {
                    Text(LF("Image quality: %d%%", Int(o.quality * 100)))
                    Slider(value: $o.quality, in: 0.2...0.95)
                }
            }
        }
    }

    private func loadDuration() async {
        let fields = action.info.fields
        guard fields.contains(.trim) || fields.contains(.gif) || fields.contains(.snapshotTime) || fields.contains(.split),
              let first = store.targets(for: action).first else { return }
        var dur = try? await AVURLAsset(url: first).load(.duration).seconds
        if dur == nil || !(dur!.isFinite) || dur! <= 0 { dur = FF.duration(first) }
        guard let d = dur, d.isFinite, d > 0 else { return }
        let rounded = (d * 10).rounded(.down) / 10
        durationText = LF("Duration of %@: %.1f s", first.lastPathComponent, d)
        if fields.contains(.gif) {
            o.end = min(rounded, 5)
        } else if fields.contains(.trim) {
            o.end = rounded
        }
    }
}

/// A number field that updates its value on every keystroke, so clicking Run never loses an edit.
struct NumberField: View {
    let label: String
    @Binding var value: Double
    @State private var text = ""

    var body: some View {
        TextField(L(label), text: $text)
            .onAppear { text = Self.format(value) }
            .onChange(of: text) { t in
                if let v = Double(t.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) {
                    value = v
                }
            }
            .onChange(of: value) { v in
                let current = Double(text.replacingOccurrences(of: ",", with: "."))
                if current != v { text = Self.format(v) }
            }
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}

// MARK: - Jobs

struct JobsView: View {
    @EnvironmentObject var store: JobStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Show results in Finder", isOn: $store.revealWhenDone)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button("Clear Finished") { store.clearFinished() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.jobs) { job in
                        JobRow(job: job)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.statusSymbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .queued:
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                case .running:
                    SignalProgress(value: job.progress)
                case .done:
                    if let m = job.message {
                        Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if let first = job.outputs.first {
                        Text(LF("Saved %@", first.lastPathComponent) + (job.outputs.count > 1 ? " +\(job.outputs.count - 1)" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .failed(let err):
                    Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer()
            if !job.outputs.isEmpty && job.state == .done {
                Button("Show") { job.reveal() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.fill))
    }

    private var color: Color {
        switch job.state {
        case .queued: return .secondary
        case .running: return Brand.accent
        case .done: return .green
        case .failed: return .orange
        }
    }
}
