import AppKit
import SwiftUI
import Carbon

// MARK: - Model

enum WheelMode: Int, CaseIterable {
    case convert, tools, actions

    var title: String { L(englishTitle) }
    var englishTitle: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }

    var next: WheelMode { WheelMode(rawValue: (rawValue + 1) % 3) ?? .convert }
}

enum Utility {
    case airdrop, copy, move, copyPath, terminal, float, zip, openInBremorph
}

struct WheelItem {
    let title: String
    let symbol: String
    var action: ActionID? = nil
    var utility: Utility? = nil
    var big = false
}

// MARK: - Controller

@MainActor
final class WheelController {
    static let shared = WheelController()

    static let size: CGFloat = 420

    private var panel: WheelPanel!
    private var view: WheelView!
    private var timer: Timer?
    private var mouseWasDown = false
    private var changeCountAtDown = 0
    private var files: [URL] = []
    private var clickMonitor: Any?
    private var flagsClearedSinceShow = false
    private(set) var visible = false
    private(set) var dragMode = true
    private(set) var mode: WheelMode = .convert
    var ownDrag = false

    func start() {
        let p = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        let frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        let container = NSView(frame: frame)
        // Frosted glass disc behind the slices.
        let glass = NSVisualEffectView(frame: frame)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        let r: CGFloat = 180
        glass.maskImage = NSImage(size: frame.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2)).fill()
            return true
        }
        container.addSubview(glass)
        let v = WheelView(frame: frame)
        v.controller = self
        container.addSubview(v)
        p.contentView = container
        panel = p
        view = v

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // Watches the mouse and modifier keys. No special permissions are needed for this.
    private func tick() {
        let down = (NSEvent.pressedMouseButtons & 1) != 0
        let flags = NSEvent.modifierFlags.intersection([.shift, .option, .control, .command])

        if visible && !dragMode {
            // Click mode (opened by the hotkey): wait until the hotkey's keys are released,
            // then Option = Tools and Control = Actions while held.
            if flags.isEmpty { flagsClearedSinceShow = true }
            if flagsClearedSinceShow, let m = Self.mode(for: flags) { setMode(m) }
            return
        }

        let dragPB = NSPasteboard(name: .drag)
        if down {
            if !mouseWasDown {
                mouseWasDown = true
                changeCountAtDown = dragPB.changeCount
            }
            guard JobStore.shared.wheelEnabled, !ownDrag else { return }
            if !visible {
                let triggered = Self.mode(for: flags) != nil
                if triggered && dragPB.changeCount != changeCountAtDown {
                    let urls = Self.fileURLs(dragPB)
                    if !urls.isEmpty { show(files: urls, mode: Self.mode(for: flags) ?? .convert, dragMode: true) }
                }
            } else if let m = Self.mode(for: flags), m != mode {
                setMode(m)
            }
        } else if mouseWasDown {
            mouseWasDown = false
            if visible && dragMode {
                // Give the drop a moment to land before hiding.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    MainActor.assumeIsolated {
                        if let self = self, self.dragMode, (NSEvent.pressedMouseButtons & 1) == 0 { self.hide() }
                    }
                }
            }
        }
    }

    /// Which wheel the held keys open (keys are set in Settings).
    static func mode(for flags: NSEvent.ModifierFlags) -> WheelMode? {
        let s = AppSettings.shared
        let pairs: [(WheelMode, NSEvent.ModifierFlags)] = [(.convert, s.convertKeys.flags), (.tools, s.toolsKeys.flags),
                                                            (.actions, s.actionsKeys.flags)]
        if let exact = pairs.first(where: { $0.1 == flags }) { return exact.0 }
        let partial = pairs.filter { !$0.1.isEmpty && flags.contains($0.1) }
            .sorted { $0.1.rawValue.nonzeroBitCount > $1.1.rawValue.nonzeroBitCount }
        return partial.first?.0
    }

    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        guard pb.types?.contains(.fileURL) == true else { return [] }
        return (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: Showing / hiding

    func show(files: [URL], mode: WheelMode, dragMode: Bool) {
        self.files = files
        self.dragMode = dragMode
        flagsClearedSinceShow = false
        view.dragMode = dragMode
        view.fileCount = files.count
        setMode(mode, force: true)

        let loc = NSEvent.mouseLocation
        var origin = NSPoint(x: loc.x - Self.size / 2, y: loc.y - Self.size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) {
            let f = screen.frame
            origin.x = min(max(origin.x, f.minX), f.maxX - Self.size)
            origin.y = min(max(origin.y, f.minY), f.maxY - Self.size)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if !dragMode { panel.makeKey() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        visible = true

        if !dragMode {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        panel.orderOut(nil)
        view.hover = nil
        view.centerHover = false
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    func setMode(_ m: WheelMode, force: Bool = false) {
        guard force || m != mode else { return }
        mode = m
        view.items = Self.items(for: files, mode: m)
        view.mode = m
        view.hover = nil
        view.needsDisplay = true
    }

    func cycleMode() { setMode(mode.next) }

    // MARK: Items

    static let utilities: [WheelItem] = [
        WheelItem(title: L("AirDrop"), symbol: "dot.radiowaves.left.and.right", utility: .airdrop),
        WheelItem(title: L("Copy"), symbol: "doc.on.doc", utility: .copy),
        WheelItem(title: L("Move To…"), symbol: "folder", utility: .move),
        WheelItem(title: L("Copy Path"), symbol: "link", utility: .copyPath),
        WheelItem(title: L("Terminal"), symbol: "terminal", utility: .terminal),
        WheelItem(title: L("Float"), symbol: "pin", utility: .float),
        WheelItem(title: L("ZIP"), symbol: "doc.zipper", utility: .zip),
        WheelItem(title: L("Open in Bremorph"), symbol: "macwindow", utility: .openInBremorph),
    ]

    static func items(for files: [URL], mode: WheelMode) -> [WheelItem] {
        if mode == .actions { return utilities }
        let kind = files.first.map { FileKind.detect($0) } ?? .other
        func acts(_ g: ActionGroup) -> [ActionID] {
            ActionID.actions(for: kind, group: g).filter { a in
                a.isAvailable && files.filter { a.accepts($0) }.count >= max(1, a.info.minFiles)
            }
        }
        var list = acts(mode == .convert ? .convert : .tools)
        if mode == .convert && kind == .image { list.insert(.imgEdit, at: 0) }   // cropping is one Shift-drag away
        if list.isEmpty { list = acts(.tools) }
        if list.isEmpty { list = ActionID.universalActions }
        if list.count > 12 { list.removeAll { $0 == .showInfo } }
        if list.count > 12 { list = Array(list.prefix(12)) }
        return list.map { a in
            WheelItem(title: a.info.title, symbol: a.info.symbol, action: a, big: a.info.group == .convert && a != .imgEdit)
        }
    }

    // MARK: Performing

    func perform(_ index: Int, urls: [URL]?) {
        let items = view.items
        guard index >= 0, index < items.count else { hide(); return }
        let targets = (urls?.isEmpty == false) ? urls! : files
        let item = items[index]
        hide()
        if let a = item.action {
            Self.run(a, on: targets)
        } else if let u = item.utility {
            Utilities.perform(u, targets)
        }
    }

    static func run(_ a: ActionID, on urls: [URL]) {
        let store = JobStore.shared
        if a.info.opensWindow {
            JobStore.openWindow(for: a, urls: urls.filter { a.accepts($0) })
            return
        }
        if !a.info.fields.isEmpty {
            store.files = urls
            store.showWindow()
            store.pendingAction = a
            return
        }
        let jobs = store.run(a, options: ActionOptions(), on: urls)
        if jobs.isEmpty {
            ToastController.shared.say(LF("%@ doesn't apply to these files.", a.info.title))
        } else {
            ToastController.shared.track(jobs)
        }
    }

    /// ⌃⌥M: open the wheel for whatever is selected in Finder.
    func showForFinderSelection() {
        if visible { hide(); return }
        let result = FinderSelection.get()
        switch result {
        case .success(let urls) where !urls.isEmpty:
            show(files: urls, mode: .convert, dragMode: false)
        case .success:
            ToastController.shared.say(L("Select files in Finder first, then press Return or ⌃⌥M."))
        case .failure(let message):
            ToastController.shared.say(message)
        }
    }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Wheel drawing & input

final class WheelView: NSView {
    weak var controller: WheelController?
    var items: [WheelItem] = []
    var mode: WheelMode = .convert
    var dragMode = true
    var fileCount = 0
    var hover: Int? { didSet { if hover != oldValue { needsDisplay = true } } }
    var centerHover = false { didSet { if centerHover != oldValue { needsDisplay = true } } }

    let outerR: CGFloat = 180
    let innerR: CGFloat = 64

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    private func isCenter(_ p: NSPoint) -> Bool { hypot(p.x - center.x, p.y - center.y) <= innerR }

    /// Segment under a point (segment 0 is centred at the top, going clockwise).
    private func index(at p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = hypot(dx, dy)
        guard !items.isEmpty, r > innerR, r < outerR + 30 else { return nil }
        var a = atan2(dx, dy)
        if a < 0 { a += 2 * .pi }
        let step = 2 * CGFloat.pi / CGFloat(items.count)
        var shifted = a + step / 2
        if shifted >= 2 * .pi { shifted -= 2 * .pi }
        return Int(shifted / step) % items.count
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        let c = center

        let discRect = NSRect(x: c.x - outerR, y: c.y - outerR, width: outerR * 2, height: outerR * 2)
        let disc = NSBezierPath(ovalIn: discRect)

        // Graphite over the blur behind it, then a single hairline rim.
        NSColor(calibratedWhite: 0.07, alpha: 0.82).setFill()
        disc.fill()
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        let rim = NSBezierPath(ovalIn: discRect.insetBy(dx: 0.5, dy: 0.5))
        rim.lineWidth = 1
        rim.stroke()

        let n = items.count
        if n > 0 {
            let step = 360.0 / CGFloat(n)
            let gap: CGFloat = n > 1 ? 1.2 : 0
            let labelR = (outerR + innerR) / 2 + 4
            let arcLen = 2 * .pi * labelR / CGFloat(n)
            let maxW = min(104, arcLen * 0.86)
            for i in 0..<n {
                let mid = CGFloat(i) * step
                let a0 = mid - step / 2 + gap / 2
                let a1 = mid + step / 2 - gap / 2
                let path = NSBezierPath()
                if n == 1 {
                    path.appendOval(in: NSRect(x: c.x - outerR + 6, y: c.y - outerR + 6, width: (outerR - 6) * 2, height: (outerR - 6) * 2))
                    path.appendOval(in: NSRect(x: c.x - innerR - 4, y: c.y - innerR - 4, width: (innerR + 4) * 2, height: (innerR + 4) * 2))
                    path.windingRule = .evenOdd
                } else {
                    path.appendArc(withCenter: c, radius: outerR - 6, startAngle: 90 - a0, endAngle: 90 - a1, clockwise: true)
                    path.appendArc(withCenter: c, radius: innerR + 4, startAngle: 90 - a1, endAngle: 90 - a0, clockwise: false)
                    path.close()
                }
                let lit = i == hover
                (lit ? Brand.nsSignal : NSColor(calibratedWhite: 1, alpha: 0.04)).setFill()
                path.fill()
                if !lit {
                    NSColor(calibratedWhite: 1, alpha: 0.07).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }

                let rad = mid * .pi / 180
                let p = NSPoint(x: c.x + labelR * sin(rad), y: c.y + labelR * cos(rad))
                drawLabel(items[i], at: p, maxW: maxW, number: i + 1, lit: lit)
            }
        }

        // Centre: which wheel this is, how many files, and how to get out.
        let cr = innerR - 3
        let centerDisc = NSBezierPath(ovalIn: NSRect(x: c.x - cr, y: c.y - cr, width: cr * 2, height: cr * 2))
        NSColor(calibratedWhite: 1, alpha: centerHover ? 0.12 : 0.05).setFill()
        centerDisc.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        centerDisc.lineWidth = 1
        centerDisc.stroke()

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                          .foregroundColor: NSColor.white, .paragraphStyle: para]
        let countText = LF("%d files", fileCount)
        let countFont = AppLanguage.isRTL ? NSFont.systemFont(ofSize: 10.5, weight: .semibold)
                                          : NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let countAttrs: [NSAttributedString.Key: Any] = [.font: countFont,
                                                          .foregroundColor: Brand.nsSignal, .paragraphStyle: para]
        let hintAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                                                         .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.5), .paragraphStyle: para]
        (mode.title as NSString).draw(in: NSRect(x: c.x - 55, y: c.y + 4, width: 110, height: 20), withAttributes: titleAttrs)
        (countText as NSString).draw(in: NSRect(x: c.x - 55, y: c.y - 10, width: 110, height: 14), withAttributes: countAttrs)
        let hint = dragMode ? L("drop here to cancel") : L("click to switch")
        (hint as NSString).draw(in: NSRect(x: c.x - 55, y: c.y - 24, width: 110, height: 14), withAttributes: hintAttrs)

        // Which of the three wheels is showing.
        for (i, m) in WheelMode.allCases.enumerated() {
            let x = c.x - 12 + CGFloat(i) * 12
            let on = m == mode
            (on ? Brand.nsSignal : NSColor(calibratedWhite: 1, alpha: 0.25)).setFill()
            let w: CGFloat = on ? 10 : 4
            NSBezierPath(roundedRect: NSRect(x: x - w / 2, y: c.y - 42, width: w, height: 4), xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawLabel(_ item: WheelItem, at p: NSPoint, maxW: CGFloat, number: Int, lit: Bool) {
        let color = lit ? Brand.nsInk : NSColor(calibratedWhite: 1, alpha: 0.92)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let arabic = item.title.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
        let font: NSFont = item.big
            ? (arabic ? NSFont.systemFont(ofSize: 12.5, weight: .semibold)
                      : NSFont.monospacedSystemFont(ofSize: item.title.count > 6 ? 11.5 : 14, weight: .semibold))
            : NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let str = item.title as NSString
        let tb = str.boundingRect(with: NSSize(width: maxW, height: 60), options: [.usesLineFragmentOrigin], attributes: attrs)
        let textH = ceil(tb.height)

        var icon: NSImage? = nil
        if !item.big {
            let tint = lit ? Brand.nsInk : Brand.nsSignal
            let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            icon = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        let iconH = icon.map { $0.size.height + 5 } ?? 0
        var top = p.y + (textH + iconH) / 2
        if let icon = icon {
            let s = icon.size
            icon.draw(in: NSRect(x: p.x - s.width / 2, y: top - s.height, width: s.width, height: s.height))
            top -= iconH
        }
        str.draw(in: NSRect(x: p.x - maxW / 2, y: top - textH, width: maxW, height: textH), withAttributes: attrs)

        if !dragMode && number <= 9 {
            let numAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold),
                                                            .foregroundColor: color.withAlphaComponent(0.5), .paragraphStyle: para]
            ("\(number)" as NSString).draw(in: NSRect(x: p.x - 10, y: top - textH - 13, width: 20, height: 11), withAttributes: numAttrs)
        }
    }

    // MARK: Click mode

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = index(at: p)
        centerHover = isCenter(p)
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        centerHover = false
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if isCenter(p) {
            if dragMode { controller?.hide() } else { controller?.cycleMode() }
            return
        }
        if let i = index(at: p) { controller?.perform(i, urls: nil) } else { controller?.hide() }
    }

    override func keyDown(with event: NSEvent) {
        let n = items.count
        switch event.keyCode {
        case 124, 125: // right, down → next slice clockwise
            if n > 0 { hover = ((hover ?? -1) + 1) % n }
            return
        case 123, 126: // left, up → previous slice
            if n > 0 { hover = ((hover ?? 0) - 1 + n) % n }
            return
        case 36, 76: // Return / Enter
            if let h = hover { controller?.perform(h, urls: nil) }
            return
        default:
            break
        }
        if event.keyCode == 53 { controller?.hide(); return }          // Escape
        if event.keyCode == 48 { controller?.cycleMode(); return }     // Tab
        if let ch = event.charactersIgnoringModifiers, let n = Int(ch), n >= 1, n <= items.count {
            controller?.perform(n - 1, urls: nil)
        }
    }

    // MARK: Drag mode (drop a file on a segment)

    private func dragOp(_ info: NSDraggingInfo) -> NSDragOperation {
        let p = convert(info.draggingLocation, from: nil)
        hover = index(at: p)
        centerHover = isCenter(p)
        guard hover != nil else { return [] }
        let mask = info.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.link) { return .link }
        return mask.contains(.move) ? .move : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOp(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOp(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        hover = nil
        centerHover = false
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        guard let i = index(at: p) else {
            controller?.hide()
            return false
        }
        let urls = WheelController.fileURLs(sender.draggingPasteboard)
        controller?.perform(i, urls: urls)
        return true
    }
}

// MARK: - Actions wheel utilities

@MainActor
enum Utilities {
    static func perform(_ u: Utility, _ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch u {
        case .airdrop:
            NSApp.activate(ignoringOtherApps: true)
            if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) {
                service.perform(withItems: urls)
            } else {
                ToastController.shared.say(L("AirDrop isn't available right now."))
            }
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls.map { $0 as NSURL })
            ToastController.shared.say(LF("Copied %d files. Paste them anywhere in Finder.", urls.count))
        case .copyPath:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(urls.map { $0.path }.joined(separator: "\n"), forType: .string)
            ToastController.shared.say(urls.count == 1 ? L("Copied path.") : L("Copied paths."))
        case .terminal:
            let first = urls[0]
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            let folder = isDir.boolValue ? first : first.deletingLastPathComponent()
            if let term = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open([folder], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
            }
        case .float:
            FloatController.shared.float(urls)
        case .zip:
            let jobs = JobStore.shared.run(.anyZIP, options: ActionOptions(), on: urls)
            ToastController.shared.track(jobs)
        case .move:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = L("Move Here")
            panel.message = LF("Move %d items to…", urls.count)
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            var moved: [URL] = []
            for u in urls {
                let target = Paths.unique(folder: dest, name: u.deletingPathExtension().lastPathComponent, ext: u.pathExtension)
                do {
                    try FileManager.default.moveItem(at: u, to: target)
                    moved.append(target)
                } catch {
                    ToastController.shared.say(LF("Couldn't move %@: %@", u.lastPathComponent, error.localizedDescription))
                }
            }
            if !moved.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(moved)
                ToastController.shared.say(LF("Moved %d items to %@.", moved.count, dest.lastPathComponent))
            }
        case .openInBremorph:
            JobStore.shared.add(urls)
            JobStore.shared.showWindow()
        }
    }
}

// MARK: - Finder selection (for the ⌃⌥M hotkey)

enum SelectionResult {
    case success([URL])
    case failure(String)
}

@MainActor
enum FinderSelection {
    static func get() -> SelectionResult {
        let source = """
        tell application "Finder"
            set sel to selection
            set out to {}
            repeat with i in sel
                set end of out to POSIX path of (i as alias)
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(L("Couldn't talk to Finder.")) }
        let res = script.executeAndReturnError(&err)
        if let err = err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 || code == -1744 {
                return .failure(L("Allow Bremorph to control Finder: System Settings → Privacy & Security → Automation → Bremorph → Finder."))
            }
            return .failure(L("Couldn't read Finder's selection."))
        }
        if res.numberOfItems == 0 {
            if let s = res.stringValue, !s.isEmpty { return .success([URL(fileURLWithPath: s)]) }
            return .success([])
        }
        var urls: [URL] = []
        for i in 1...res.numberOfItems {
            if let s = res.atIndex(i)?.stringValue { urls.append(URL(fileURLWithPath: s)) }
        }
        return .success(urls)
    }
}

// MARK: - Global hotkey (⌃⌥M) — uses the classic hotkey API, so no extra permissions

enum HotKey {
    static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ handler: @escaping () -> Void) {
        self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D52_5048), id: 1) // "MRPH"
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Float shelf (park files on screen, drag them out later)

@MainActor
final class FloatController {
    static let shared = FloatController()
    private var panels: [NSPanel] = []

    func float(_ urls: [URL]) {
        let size = NSSize(width: 128, height: 138)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = ShelfView(frame: NSRect(origin: .zero, size: size), urls: urls)
        v.onClose = { [weak self, weak p] in
            p?.orderOut(nil)
            self?.panels.removeAll { $0 === p }
        }
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let glass = NSVisualEffectView(frame: container.bounds)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 18, yRadius: 18).fill()
            return true
        }
        container.addSubview(glass)
        container.addSubview(v)
        p.contentView = container
        let loc = NSEvent.mouseLocation
        let offset = CGFloat(panels.count % 6) * 18
        p.setFrameOrigin(NSPoint(x: loc.x + 40 + offset, y: loc.y - size.height / 2 - offset))
        p.orderFrontRegardless()
        panels.append(p)
    }
}

final class ShelfView: NSView, NSDraggingSource {
    let urls: [URL]
    let icon: NSImage
    var onClose: (() -> Void)?
    private var downPoint: NSPoint?

    init(frame: NSRect, urls: [URL]) {
        self.urls = urls
        self.icon = NSWorkspace.shared.icon(forFiles: urls.map { $0.path }) ?? NSWorkspace.shared.icon(forFile: urls.first?.path ?? "/")
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var closeRect: NSRect { NSRect(x: 9, y: bounds.height - 25, width: 16, height: 16) }
    private var iconRect: NSRect { NSRect(x: bounds.midX - 34, y: 34, width: 68, height: 68) }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 0.07, alpha: 0.82).setFill()
        bg.fill()
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSBezierPath(ovalIn: closeRect).fill()
        let x = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white])))
        if let x = x {
            x.draw(in: NSRect(x: closeRect.midX - x.size.width / 2, y: closeRect.midY - x.size.height / 2,
                              width: x.size.width, height: x.size.height))
        }

        icon.draw(in: iconRect)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        let name = urls.count == 1 ? urls[0].lastPathComponent : LF("%d files", urls.count)
        (name as NSString).draw(in: NSRect(x: 8, y: 12, width: bounds.width - 16, height: 16),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                 .foregroundColor: NSColor.white, .paragraphStyle: para])
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -5, dy: -5).contains(p) {
            onClose?()
            return
        }
        if !iconRect.insetBy(dx: -16, dy: -16).contains(p) {
            window?.performDrag(with: event) // move the shelf
            return
        }
        downPoint = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard downPoint != nil else { return }
        downPoint = nil
        WheelController.shared.ownDrag = true
        let items: [NSDraggingItem] = urls.enumerated().map { pair in
            let item = NSDraggingItem(pasteboardWriter: pair.element as NSURL)
            item.setDraggingFrame(iconRect.offsetBy(dx: CGFloat(pair.offset) * 3, dy: CGFloat(-pair.offset) * 3), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        WheelController.shared.ownDrag = false
        if operation != [] { onClose?() }
    }
}

// MARK: - Progress toast (top-right corner)

@MainActor
final class ToastModel: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var message: String?
}

struct ToastView: View {
    @ObservedObject var model: ToastModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16, height: 16)
                Text("Bremorph").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    ToastController.shared.hide()
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if let m = model.message {
                Text(m).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.jobs) { job in
                JobRow(job: job)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .floatingCard(cornerRadius: 18)
        .padding(10)
        .tint(Brand.accent)
        .localizedLayout()
    }
}

@MainActor
final class ToastController {
    static let shared = ToastController()
    let model = ToastModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<ToastView>?
    private var timer: Timer?
    private var finishedAt: Date?

    func track(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        model.message = nil
        let running = model.jobs.filter { !$0.isFinished }
        model.jobs = Array((jobs + running).prefix(4))
        present()
    }

    func say(_ text: String) {
        model.jobs = []
        model.message = text
        present()
    }

    private func present() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let h = NSHostingView(rootView: ToastView(model: model))
            p.contentView = h
            panel = p
            hosting = h
        }
        finishedAt = nil
        layout()
        panel?.orderFrontRegardless()
        timer?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func layout() {
        guard let p = panel, let h = hosting else { return }
        let size = h.fittingSize
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let f = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        p.setFrame(NSRect(x: f.maxX - size.width - 14, y: f.maxY - size.height - 10, width: size.width, height: size.height), display: true)
    }

    private func check() {
        layout()
        let allDone = model.jobs.allSatisfy { $0.isFinished }
        guard allDone else { finishedAt = nil; return }
        if finishedAt == nil { finishedAt = Date(); return }
        let failed = model.jobs.contains { if case .failed = $0.state { return true }; return false }
        let linger: TimeInterval = (failed || model.message != nil) ? 6 : 3.5
        if let f = finishedAt, Date().timeIntervalSince(f) > linger,
           let p = panel, !NSMouseInRect(NSEvent.mouseLocation, p.frame, false) {
            hide()
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }
}
