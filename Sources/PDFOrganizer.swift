import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

struct PageItem: Identifiable, Equatable {
    let id = UUID()
    let doc: Int          // which source document
    let index: Int        // page index in that document
    var rotation: Int     // extra rotation in degrees
    let thumbnail: NSImage

    static func == (a: PageItem, b: PageItem) -> Bool { a.id == b.id && a.rotation == b.rotation }
}

@MainActor
final class OrganizerModel: ObservableObject {
    let url: URL
    private(set) var docs: [PDFDocument] = []
    @Published var pages: [PageItem] = []
    @Published var selection: Set<UUID> = []
    @Published var dragging: PageItem?
    @Published var status: String?

    init(url: URL) throws {
        self.url = url
        let doc = try PDFOps.open(url)
        docs = [doc]
        pages = Self.items(for: doc, docIndex: 0)
    }

    static func items(for doc: PDFDocument, docIndex: Int) -> [PageItem] {
        (0..<doc.pageCount).compactMap { i in
            guard let p = doc.page(at: i) else { return nil }
            return PageItem(doc: docIndex, index: i, rotation: 0, thumbnail: p.thumbnail(of: NSSize(width: 220, height: 280), for: .cropBox))
        }
    }

    func toggle(_ item: PageItem, extend: Bool) {
        if extend {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            selection = selection == [item.id] ? [] : [item.id]
        }
    }

    func selectAll() { selection = Set(pages.map(\.id)) }

    func rotateSelected(_ degrees: Int) {
        for i in pages.indices where selection.contains(pages[i].id) {
            pages[i].rotation = (pages[i].rotation + degrees + 360) % 360
        }
    }

    func deleteSelected() {
        pages.removeAll { selection.contains($0.id) }
        selection = []
    }

    func duplicateSelected() {
        var result: [PageItem] = []
        for p in pages {
            result.append(p)
            if selection.contains(p.id) {
                result.append(PageItem(doc: p.doc, index: p.index, rotation: p.rotation, thumbnail: p.thumbnail))
            }
        }
        pages = result
    }

    func reverse() { pages.reverse() }

    /// Moves the selected pages one step earlier (-1) or later (+1).
    func shiftSelected(_ step: Int) {
        guard !selection.isEmpty else { return }
        var p = pages
        let indices = p.indices.filter { selection.contains(p[$0].id) }
        if step < 0 {
            guard let first = indices.first, first > 0 else { return }
            for i in indices { p.swapAt(i, i - 1) }
        } else {
            guard let last = indices.last, last < p.count - 1 else { return }
            for i in indices.reversed() { p.swapAt(i, i + 1) }
        }
        withAnimation(.easeInOut(duration: 0.15)) { pages = p }
    }

    func insertPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for u in panel.urls {
            guard let d = try? PDFOps.open(u) else { continue }
            docs.append(d)
            pages += Self.items(for: d, docIndex: docs.count - 1)
        }
    }

    func move(_ item: PageItem, before target: PageItem) {
        guard let from = pages.firstIndex(of: item), let to = pages.firstIndex(of: target), from != to else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func build(_ items: [PageItem]) -> PDFDocument {
        let out = PDFDocument()
        for item in items {
            guard let page = docs[item.doc].page(at: item.index)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + item.rotation) % 360
            out.insert(page, at: out.pageCount)
        }
        return out
    }

    func save(selectedOnly: Bool) {
        let items = selectedOnly ? pages.filter { selection.contains($0.id) } : pages
        guard !items.isEmpty else { status = L("Nothing to save."); return }
        let out = Paths.output(for: url, suffix: selectedOnly ? "selected pages" : "organized", ext: "pdf")
        do {
            try PDFOps.save(build(items), to: out)
            status = LF("Saved %@", out.lastPathComponent) + " (" + LF("%d pages", items.count) + ")"
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch {
            status = error.localizedDescription
        }
    }
}

@MainActor
enum OrganizerWindows {
    private static var windows: [NSWindow] = []

    static func open(_ url: URL) {
        let model: OrganizerModel
        do { model = try OrganizerModel(url: url) } catch {
            ToastController.shared.say(error.localizedDescription)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("Organize") + " — " + url.lastPathComponent
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 420)
        w.contentView = NSHostingView(rootView: OrganizerView(m: model).tint(Brand.accent).background(AppBackground()).localizedLayout())
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { note in
            let closing = note.object as AnyObject?
            MainActor.assumeIsolated { windows.removeAll { $0 === closing } }
        }
        windows.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct OrganizerView: View {
    @ObservedObject var m: OrganizerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { m.rotateSelected(-90) } label: { Image(systemName: "rotate.left") }
                    .help("Rotate selected pages left").disabled(m.selection.isEmpty)
                Button { m.rotateSelected(90) } label: { Image(systemName: "rotate.right") }
                    .help("Rotate selected pages right").disabled(m.selection.isEmpty)
                Button { m.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate selected pages").disabled(m.selection.isEmpty)
                Button { m.deleteSelected() } label: { Image(systemName: "trash") }
                    .help("Delete selected pages").disabled(m.selection.isEmpty)
                Button { m.shiftSelected(-1) } label: { Image(systemName: "arrow.left") }
                    .help("Move selected pages earlier").disabled(m.selection.isEmpty)
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button { m.shiftSelected(1) } label: { Image(systemName: "arrow.right") }
                    .help("Move selected pages later").disabled(m.selection.isEmpty)
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Divider().frame(height: 18)
                Button("Insert PDF…") { m.insertPDF() }
                Button("Reverse Order") { m.reverse() }
                Button("Select All") { m.selectAll() }.keyboardShortcut("a")
                Spacer()
                Text(LF("%d pages", m.pages.count)).font(.caption).foregroundStyle(.secondary)
                Button("Save Selected") { m.save(selectedOnly: true) }.disabled(m.selection.isEmpty)
                Button {
                    m.save(selectedOnly: false)
                } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 18) {
                    ForEach(Array(m.pages.enumerated()), id: \.element.id) { pair in
                        PageCell(item: pair.element, number: pair.offset + 1, selected: m.selection.contains(pair.element.id))
                            .onTapGesture {
                                let mods = NSEvent.modifierFlags
                                m.toggle(pair.element, extend: mods.contains(.command) || mods.contains(.shift))
                            }
                            .onDrag {
                                m.dragging = pair.element
                                return NSItemProvider(object: pair.element.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: PageDropDelegate(target: pair.element, model: m))
                    }
                }
                .padding(20)
            }
            HStack {
                Text("Drag pages to reorder, or select and use ← → (⌘← ⌘→). Click to select, ⌘-click to select several.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let s = m.status { Text(s).font(.caption).foregroundStyle(.green) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

struct PageCell: View {
    let item: PageItem
    let number: Int
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: item.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: 130, height: 165)
                .rotationEffect(.degrees(Double(item.rotation)))
                .scaleEffect(item.rotation % 180 == 0 ? 1 : 130.0 / 165.0)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            Text("\(number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

struct PageDropDelegate: DropDelegate {
    let target: PageItem
    let model: OrganizerModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            if let d = model.dragging, d.id != target.id { model.move(d, before: target) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.dragging = nil }
        return true
    }
}
