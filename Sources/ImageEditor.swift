import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Options

enum EditorTool: String, CaseIterable, Identifiable {
    case crop = "Crop", adjust = "Adjust", markup = "Markup", redact = "Hide"
    var id: String { rawValue }
    var title: String { L(rawValue) }
}

enum AspectChoice: String, CaseIterable, Identifiable {
    case free = "Free"
    case original = "Original"
    case square = "Square (1:1)"
    case r43 = "4:3"
    case r34 = "3:4"
    case r32 = "3:2"
    case r23 = "2:3"
    case r169 = "16:9 (wide)"
    case r916 = "9:16 (story)"
    var id: String { rawValue }
    var title: String { L(rawValue) }

    func ratio(original: CGFloat) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return original
        case .square: return 1
        case .r43: return 4.0 / 3.0
        case .r34: return 3.0 / 4.0
        case .r32: return 3.0 / 2.0
        case .r23: return 2.0 / 3.0
        case .r169: return 16.0 / 9.0
        case .r916: return 9.0 / 16.0
        }
    }
}

enum RedactStyle: String, CaseIterable, Identifiable {
    case black = "Black box", pixelate = "Pixelate", blur = "Blur"
    var id: String { rawValue }
    var title: String { L(rawValue) }
}

struct Redaction {
    var rect: CGRect     // normalized, top-left origin
    var style: RedactStyle
}

enum MarkupKind: String, CaseIterable, Identifiable {
    case arrow, line, rect, ellipse, pen, highlight, text
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        }
    }
    var title: String { L(englishTitle) }
    var englishTitle: String {
        switch self {
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlight: return "Highlight"
        case .text: return "Text"
        }
    }
}

struct Annotation {
    var kind: MarkupKind
    var points: [CGPoint]          // normalized, top-left origin
    var color: CGColor
    var width: CGFloat             // relative to the image's long side
    var text: String = ""
    var fontSize: CGFloat = 0.05   // relative to image height

    func transformed(_ f: (CGPoint) -> CGPoint) -> Annotation {
        var a = self
        a.points = points.map(f)
        return a
    }
}

// MARK: - Model

@MainActor
final class EditorModel: ObservableObject {
    let url: URL
    private let original: CGImage
    @Published private(set) var base: CGImage
    @Published private(set) var preview: CGImage
    @Published private(set) var display: CGImage

    /// Crop rectangle, normalized 0…1 with a top-left origin.
    @Published var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var aspect: AspectChoice = .free { didSet { if !suppressAspect { applyAspect() } } }
    @Published var tool: EditorTool = .crop
    @Published var brightness = 0.0 { didSet { refresh() } }
    @Published var contrast = 1.0 { didSet { refresh() } }
    @Published var saturation = 1.0 { didSet { refresh() } }
    @Published var autoEnhance = false { didSet { refresh() } }
    @Published var redactions: [Redaction] = [] { didSet { refresh() } }
    @Published var redactStyle: RedactStyle = .black
    @Published var status: String?

    @Published var annotations: [Annotation] = [] { didSet { redrawAnnotations() } }
    @Published var draft: Annotation? { didSet { redrawAnnotations() } }
    @Published var markupKind: MarkupKind = .arrow
    @Published var markupColor: Color = .red
    @Published var markupWidth: Double = 0.006
    @Published var markupText: String = ""
    @Published var markupFontSize: Double = 0.05

    /// Set when cropping a video (the editor shows one frame of it).
    let videoURL: URL?

    private var adjusted: CGImage
    private var suppressAspect = false
    private let context = CIContext()

    init(url: URL) throws {
        self.url = url
        self.videoURL = nil
        let img = try ImageOps.loadImage(url)
        original = img
        base = img
        let p = EditorModel.downscale(img, 1600)
        preview = p
        display = p
        adjusted = p
    }

    init(videoFrame: CGImage, video: URL) {
        self.url = video
        self.videoURL = video
        original = videoFrame
        base = videoFrame
        let p = EditorModel.downscale(videoFrame, 1600)
        preview = p
        display = p
        adjusted = p
    }

    var cgMarkupColor: CGColor {
        NSColor(markupColor).usingColorSpace(.sRGB)?.cgColor ?? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    }

    func newAnnotation(at p: CGPoint) -> Annotation {
        Annotation(kind: markupKind, points: [p], color: cgMarkupColor, width: CGFloat(markupWidth),
                   text: markupText, fontSize: CGFloat(markupFontSize))
    }

    func placeText(at p: CGPoint) {
        let t = markupText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            status = L("Type your text in the sidebar first, then click where it should go.")
            return
        }
        var a = newAnnotation(at: p)
        a.text = t
        annotations.append(a)
    }

    func undoAnnotation() { if !annotations.isEmpty { annotations.removeLast() } }

    private func redrawAnnotations() {
        var list = annotations
        if let d = draft { list.append(d) }
        display = list.isEmpty ? adjusted : Self.drawAnnotations(list, on: adjusted)
    }

    var pixelWidth: Int { base.width }
    var pixelHeight: Int { base.height }

    var cropPixelSize: String {
        "\(Int((crop.width * CGFloat(base.width)).rounded())) × \(Int((crop.height * CGFloat(base.height)).rounded())) px"
    }

    /// Required normalized width/height ratio for the chosen aspect, if any.
    var aspectK: CGFloat? {
        guard let r = aspect.ratio(original: CGFloat(base.width) / CGFloat(base.height)) else { return nil }
        return r * CGFloat(base.height) / CGFloat(base.width)
    }

    private func applyAspect() {
        guard let k = aspectK else { return }
        var w: CGFloat = 1, h: CGFloat = 1
        if k >= 1 { h = 1 / k } else { w = k }
        crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    func resetCrop() {
        suppressAspect = true
        aspect = .free
        suppressAspect = false
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func resetAdjustments() {
        brightness = 0
        contrast = 1
        saturation = 1
        autoEnhance = false
    }

    func resetAll() {
        base = original
        preview = Self.downscale(original, 1600)
        redactions = []
        annotations = []
        resetAdjustments()
        resetCrop()
        refresh()
        status = nil
    }

    func addRedaction(_ r: CGRect) { redactions.append(Redaction(rect: r, style: redactStyle)) }
    func undoRedaction() { if !redactions.isEmpty { redactions.removeLast() } }

    // MARK: Rotate / flip

    func rotate(clockwise: Bool) {
        base = Self.rotated(base, clockwise: clockwise)
        crop = Self.rotateRect(crop, clockwise: clockwise)
        redactions = redactions.map { Redaction(rect: Self.rotateRect($0.rect, clockwise: clockwise), style: $0.style) }
        annotations = annotations.map { $0.transformed { p in clockwise ? CGPoint(x: 1 - p.y, y: p.x) : CGPoint(x: p.y, y: 1 - p.x) } }
        afterGeometryChange()
    }

    func flip(horizontal: Bool) {
        base = Self.flipped(base, horizontal: horizontal)
        func f(_ r: CGRect) -> CGRect {
            horizontal ? CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height)
                       : CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        }
        crop = f(crop)
        redactions = redactions.map { Redaction(rect: f($0.rect), style: $0.style) }
        annotations = annotations.map { $0.transformed { p in horizontal ? CGPoint(x: 1 - p.x, y: p.y) : CGPoint(x: p.x, y: 1 - p.y) } }
        afterGeometryChange()
    }

    private func afterGeometryChange() {
        preview = Self.downscale(base, 1600)
        if aspect != .free {
            suppressAspect = true
            aspect = .free
            suppressAspect = false
        }
        refresh()
    }

    // MARK: Rendering

    func refresh() {
        adjusted = render(source: preview, cropping: false, annotate: false) ?? preview
        redrawAnnotations()
    }

    func render(source: CGImage, cropping: Bool, annotate: Bool = true) -> CGImage? {
        let W = CGFloat(source.width), H = CGFloat(source.height)
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        var img = CIImage(cgImage: source)
        if autoEnhance {
            for f in img.autoAdjustmentFilters(options: [.redEye: false]) {
                f.setValue(img, forKey: kCIInputImageKey)
                if let o = f.outputImage { img = o }
            }
        }
        if brightness != 0 || contrast != 1 || saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness,
                kCIInputContrastKey: contrast,
                kCIInputSaturationKey: saturation,
            ])
        }
        for r in redactions {
            let rect = CGRect(x: r.rect.minX * W, y: (1 - r.rect.maxY) * H, width: r.rect.width * W, height: r.rect.height * H)
            let patch: CIImage
            switch r.style {
            case .black:
                patch = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
            case .pixelate:
                patch = img.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, max(W, H) / 55),
                                                                kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY)])
                    .cropped(to: rect)
            case .blur:
                patch = img.clampedToExtent().applyingGaussianBlur(sigma: Double(max(8, max(W, H) / 60))).cropped(to: rect)
            }
            img = patch.composited(over: img)
        }
        img = img.cropped(to: full)
        guard var result = context.createCGImage(img, from: full) else { return nil }
        if annotate && !annotations.isEmpty { result = Self.drawAnnotations(annotations, on: result) }
        if cropping {
            // CGImage cropping uses a top-left origin, like our crop rectangle.
            let w = max(1, (crop.width * W).rounded()), h = max(1, (crop.height * H).rounded())
            let x = min(max(0, (crop.minX * W).rounded()), W - w)
            let y = min(max(0, (crop.minY * H).rounded()), H - h)
            result = result.cropping(to: CGRect(x: x, y: y, width: w, height: h)) ?? result
        }
        return result
    }

    // MARK: Markup drawing

    static func drawAnnotations(_ list: [Annotation], on img: CGImage) -> CGImage {
        let W = img.width, H = img.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        let w = CGFloat(W), h = CGFloat(H)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        for a in list { draw(a, in: ctx, w, h) }
        return ctx.makeImage() ?? img
    }

    static func draw(_ a: Annotation, in ctx: CGContext, _ W: CGFloat, _ H: CGFloat) {
        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * W, y: (1 - q.y) * H) }
        guard let first = a.points.first else { return }
        let last = a.points.last ?? first
        let lw = max(1, a.width * max(W, H))
        ctx.saveGState()
        ctx.setStrokeColor(a.color)
        ctx.setFillColor(a.color)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let s = p(first), e = p(last)
        let r = CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y))
        switch a.kind {
        case .pen:
            ctx.beginPath()
            ctx.move(to: s)
            for q in a.points.dropFirst() { ctx.addLine(to: p(q)) }
            ctx.strokePath()
        case .line:
            ctx.beginPath()
            ctx.move(to: s)
            ctx.addLine(to: e)
            ctx.strokePath()
        case .arrow:
            let ang = atan2(e.y - s.y, e.x - s.x)
            let head = lw * 4.5
            let neck = CGPoint(x: e.x - cos(ang) * head * 0.8, y: e.y - sin(ang) * head * 0.8)
            ctx.beginPath()
            ctx.move(to: s)
            ctx.addLine(to: neck)
            ctx.strokePath()
            ctx.beginPath()
            ctx.move(to: e)
            ctx.addLine(to: CGPoint(x: e.x - cos(ang - 0.45) * head, y: e.y - sin(ang - 0.45) * head))
            ctx.addLine(to: CGPoint(x: e.x - cos(ang + 0.45) * head, y: e.y - sin(ang + 0.45) * head))
            ctx.closePath()
            ctx.fillPath()
        case .rect:
            ctx.stroke(r)
        case .ellipse:
            ctx.strokeEllipse(in: r)
        case .highlight:
            ctx.setFillColor(a.color.copy(alpha: 0.35) ?? a.color)
            ctx.fill(r)
        case .text:
            let size = max(8, a.fontSize * H)
            let color = NSColor(cgColor: a.color) ?? .red
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = size * 0.08
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.03)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold),
                                                        .foregroundColor: color, .shadow: shadow]
            let str = a.text as NSString
            let ts = str.size(withAttributes: attrs)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            str.draw(at: CGPoint(x: s.x, y: s.y - ts.height), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
    }

    // MARK: Video crop

    func cropVideo() {
        guard let video = videoURL else { return }
        let W = CGFloat(base.width), H = CGFloat(base.height)
        let rect = CGRect(x: crop.minX * W, y: crop.minY * H, width: crop.width * W, height: crop.height * H)
        let job = JobStore.shared.runCustom(title: L("Crop Video") + " · " + video.lastPathComponent) { progress in
            EngineResult(outputs: [try MediaFF.crop(video, rect: rect, progress: progress)])
        }
        ToastController.shared.track([job])
        status = L("Cropping in the background. You can close this window.")
    }

    // MARK: Saving

    func save(to chosen: URL?) {
        guard let img = render(source: base, cropping: true) else {
            status = L("Couldn't render the image.")
            return
        }
        let (srcType, srcExt) = ImageOps.sameFormat(url)
        let out = chosen ?? Paths.output(for: url, suffix: "edited", ext: srcExt)
        var type = srcType
        if let t = UTType(filenameExtension: out.pathExtension.lowercased()), ImageOps.writable.contains(t.identifier) { type = t }
        do {
            let final = (type == .jpeg || type == .bmp) ? ImageOps.flatten(img) : img
            try ImageOps.write(final, to: out, type: type, quality: 0.92)
            status = LF("Saved %@", out.lastPathComponent) + " " + ltr("(\(img.width) × \(img.height) px)")
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch {
            status = error.localizedDescription
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.canCreateDirectories = true
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " edited." + ImageOps.sameFormat(url).1
        if panel.runModal() == .OK, let u = panel.url { save(to: u) }
    }

    func copyToClipboard() {
        guard let img = render(source: base, cropping: true) else { return }
        let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([ns])
        status = L("Copied to clipboard") + " " + ltr("(\(img.width) × \(img.height) px)")
    }

    // MARK: Image helpers

    static func downscale(_ img: CGImage, _ maxDim: Int) -> CGImage {
        let w = img.width, h = img.height
        guard max(w, h) > maxDim else { return img }
        let s = CGFloat(maxDim) / CGFloat(max(w, h))
        let nw = max(1, Int(CGFloat(w) * s)), nh = max(1, Int(CGFloat(h) * s))
        return draw(width: nw, height: nh) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        } ?? img
    }

    static func rotated(_ img: CGImage, clockwise: Bool) -> CGImage {
        let w = img.width, h = img.height
        return draw(width: h, height: w) { ctx in
            if clockwise {
                ctx.translateBy(x: 0, y: CGFloat(w))
                ctx.rotate(by: -.pi / 2)
            } else {
                ctx.translateBy(x: CGFloat(h), y: 0)
                ctx.rotate(by: .pi / 2)
            }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        } ?? img
    }

    static func flipped(_ img: CGImage, horizontal: Bool) -> CGImage {
        let w = img.width, h = img.height
        return draw(width: w, height: h) { ctx in
            if horizontal {
                ctx.translateBy(x: CGFloat(w), y: 0)
                ctx.scaleBy(x: -1, y: 1)
            } else {
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1, y: -1)
            }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        } ?? img
    }

    static func rotateRect(_ r: CGRect, clockwise: Bool) -> CGRect {
        clockwise ? CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
                  : CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        body(ctx)
        return ctx.makeImage()
    }
}

// MARK: - Windows

@MainActor
enum ImageEditorWindows {
    private static var windows: [NSWindow] = []

    static func open(_ url: URL) {
        let model: EditorModel
        do {
            model = try EditorModel(url: url)
        } catch {
            ToastController.shared.say(LF("Couldn't open %@: %@", url.lastPathComponent, error.localizedDescription))
            return
        }
        open(model: model, title: L("Edit") + " — " + url.lastPathComponent)
    }

    /// Crop Video: shows one frame of the video with the crop tool.
    static func openVideo(_ url: URL) {
        Task {
            do {
                let frame: CGImage
                if await MediaFF.isNativeVideo(url) {
                    let asset = AVURLAsset(url: url)
                    let dur = try await asset.load(.duration).seconds
                    let gen = AVAssetImageGenerator(asset: asset)
                    gen.appliesPreferredTrackTransform = true
                    frame = try await gen.image(at: CMTime(seconds: min(1, dur / 2), preferredTimescale: 600)).image
                } else {
                    let tmp = try Helpers.tempDir().appendingPathComponent("frame.png")
                    try MediaFF.snapshot(url, at: 1, to: tmp)
                    frame = try ImageOps.loadImage(tmp)
                }
                open(model: EditorModel(videoFrame: frame, video: url), title: L("Crop Video") + " — " + url.lastPathComponent)
            } catch {
                ToastController.shared.say(LF("Couldn't open %@: %@", url.lastPathComponent, error.localizedDescription))
            }
        }
    }

    static func open(model: EditorModel, title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 520)
        w.contentView = NSHostingView(rootView: ImageEditorView(m: model).tint(Brand.accent).background(AppBackground()).localizedLayout())
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { note in
            let closing = note.object as AnyObject?
            MainActor.assumeIsolated {
                windows.removeAll { $0 === closing }
            }
        }
        windows.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

struct ImageEditorView: View {
    @ObservedObject var m: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if m.videoURL == nil {
                    Picker("", selection: $m.tool) {
                        ForEach(EditorTool.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)

                    Divider().frame(height: 20)
                    Button { m.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                        .help("Rotate left")
                    Button { m.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                        .help("Rotate right")
                    Button { m.flip(horizontal: true) } label: { Image(systemName: "arrow.left.and.right") }
                        .help("Flip horizontally")
                    Button { m.flip(horizontal: false) } label: { Image(systemName: "arrow.up.and.down") }
                        .help("Flip vertically")
                } else {
                    Label("Choose the part of the video to keep", systemImage: "crop")
                        .font(.headline)
                }

                Spacer()
                if m.videoURL != nil {
                    Button {
                        m.cropVideo()
                    } label: {
                        Label("Crop Video", systemImage: "crop")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
                } else {
                editorButtons
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                EditorCanvas(m: m)
                    .environment(\.layoutDirection, .leftToRight)   // the photo is never mirrored
                Divider()
                EditorSidebar(m: m)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder private var editorButtons: some View {
                Button("Reset All") { m.resetAll() }
                Button { m.copyToClipboard() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the edited image to the clipboard")
                Button("Save As…") { m.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button {
                    m.save(to: nil)
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
                .help("Saves a new copy next to the original (⌘S)")
    }
}

struct EditorSidebar: View {
    @ObservedObject var m: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch m.tool {
            case .crop:
                Text("Aspect ratio").font(.headline)
                Picker("", selection: $m.aspect) {
                    ForEach(AspectChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(L("Result:") + " " + ltr(m.cropPixelSize))
                    .font(.callout.monospacedDigit())
                Text("Drag the corners or edges to crop, drag inside the box to move it, or drag anywhere on the photo to draw a new crop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reset Crop") { m.resetCrop() }
            case .adjust:
                slider("Brightness", value: $m.brightness, range: -0.5...0.5)
                slider("Contrast", value: $m.contrast, range: 0.5...1.5)
                slider("Saturation", value: $m.saturation, range: 0...2)
                Toggle("Auto Enhance", isOn: $m.autoEnhance)
                Button("Reset Adjustments") { m.resetAdjustments() }
            case .markup:
                Text("Markup").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(MarkupKind.allCases) { k in
                        Button {
                            m.markupKind = k
                        } label: {
                            Image(systemName: k.symbol)
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(m.markupKind == k ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .help(k.title)
                    }
                }
                ColorPicker("Color", selection: $m.markupColor)
                if m.markupKind == .text {
                    TextField("Your text", text: $m.markupText)
                    slider("Text size", value: $m.markupFontSize, range: 0.02...0.15)
                    Text("Type the text, then click on the photo where it should go.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    slider("Line width", value: $m.markupWidth, range: 0.002...0.025)
                    Text("Drag on the photo to draw.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Undo") { m.undoAnnotation() }.disabled(m.annotations.isEmpty)
                    Button("Clear All") { m.annotations = [] }.disabled(m.annotations.isEmpty)
                }
            case .redact:
                Text("Hide parts of the photo").font(.headline)
                Picker("", selection: $m.redactStyle) {
                    ForEach(RedactStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Drag over faces, names, numbers or anything private.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Undo") { m.undoRedaction() }.disabled(m.redactions.isEmpty)
                    Button("Clear All") { m.redactions = [] }.disabled(m.redactions.isEmpty)
                }
            }
            Spacer()
            Text(L("Original:") + " " + ltr("\(m.pixelWidth) × \(m.pixelHeight) px"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let s = m.status {
                Text(s)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L(label))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

struct EditorCanvas: View {
    @ObservedObject var m: EditorModel
    @State private var drag: DragInfo?
    @State private var drawing: CGRect?

    struct DragInfo {
        var startCrop: CGRect
        var startPoint: CGPoint
        var left = false, right = false, top = false, bottom = false
        var move = false, newRect = false
    }

    var body: some View {
        GeometryReader { geo in
            let fit = fitRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                Image(decorative: m.display, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                CropOverlay(fit: fit, crop: m.crop, active: m.tool == .crop)
                if let d = drawing {
                    let r = toView(d, fit)
                    Rectangle()
                        .fill(Color.red.opacity(0.18))
                        .overlay(Rectangle().stroke(Color.red, style: StrokeStyle(lineWidth: 2, dash: [5, 3])))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in changed(v, fit) }
                    .onEnded { v in ended(v, fit) }
            )
        }
    }

    private func fitRect(in size: CGSize) -> CGRect {
        let pad: CGFloat = 28
        let iw = CGFloat(m.display.width), ih = CGFloat(m.display.height)
        let s = max(0.01, min((size.width - pad * 2) / iw, (size.height - pad * 2) / ih))
        let w = iw * s, h = ih * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func raw(_ p: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(x: (p.x - fit.minX) / fit.width, y: (p.y - fit.minY) / fit.height)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    private func toView(_ r: CGRect, _ fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height,
               width: r.width * fit.width, height: r.height * fit.height)
    }

    private func changed(_ v: DragGesture.Value, _ fit: CGRect) {
        let p = clamp(raw(v.location, fit))
        switch m.tool {
        case .adjust:
            return
        case .markup:
            if m.markupKind == .text { return }
            if m.draft == nil { m.draft = m.newAnnotation(at: clamp(raw(v.startLocation, fit))) }
            if m.markupKind == .pen {
                m.draft?.points.append(p)
            } else if (m.draft?.points.count ?? 0) > 1 {
                m.draft?.points[1] = p
            } else {
                m.draft?.points.append(p)
            }
        case .redact:
            let a = clamp(raw(v.startLocation, fit))
            drawing = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
        case .crop:
            if drag == nil { drag = beginDrag(at: v.startLocation, fit) }
            guard let d = drag else { return }
            if d.newRect && hypot(v.translation.width, v.translation.height) < 4 { return }
            m.crop = updatedCrop(d, rawPoint: raw(v.location, fit))
        }
    }

    private func ended(_ v: DragGesture.Value, _ fit: CGRect) {
        if m.tool == .markup {
            if m.markupKind == .text {
                m.placeText(at: clamp(raw(v.location, fit)))
            } else if let d = m.draft {
                let moved = hypot(v.translation.width, v.translation.height) > 3
                m.draft = nil
                if moved { m.annotations.append(d) }
            }
        }
        if m.tool == .redact, let r = drawing, r.width > 0.004, r.height > 0.004 {
            m.addRedaction(r)
        }
        drawing = nil
        drag = nil
    }

    private func beginDrag(at s: CGPoint, _ fit: CGRect) -> DragInfo {
        let cr = toView(m.crop, fit)
        let t: CGFloat = 14
        var d = DragInfo(startCrop: m.crop, startPoint: raw(s, fit))
        let nearL = abs(s.x - cr.minX) < t, nearR = abs(s.x - cr.maxX) < t
        let nearT = abs(s.y - cr.minY) < t, nearB = abs(s.y - cr.maxY) < t
        let withinX = s.x > cr.minX - t && s.x < cr.maxX + t
        let withinY = s.y > cr.minY - t && s.y < cr.maxY + t
        if withinX && withinY && (nearL || nearR || nearT || nearB) {
            d.left = nearL
            d.right = nearR && !nearL
            d.top = nearT
            d.bottom = nearB && !nearT
        } else if cr.contains(s) {
            d.move = true
        } else {
            d.newRect = true
            d.startPoint = clamp(raw(s, fit))
        }
        return d
    }

    private func updatedCrop(_ d: DragInfo, rawPoint: CGPoint) -> CGRect {
        let minSize: CGFloat = 0.02
        let k = m.aspectK
        let s = d.startCrop
        let p = clamp(rawPoint)

        if d.move {
            var r = s.offsetBy(dx: rawPoint.x - d.startPoint.x, dy: rawPoint.y - d.startPoint.y)
            r.origin.x = min(max(r.minX, 0), 1 - r.width)
            r.origin.y = min(max(r.minY, 0), 1 - r.height)
            return r
        }
        if d.newRect {
            return fromAnchor(d.startPoint, p, k)
        }

        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if d.left { minX = min(p.x, maxX - minSize) }
        if d.right { maxX = max(p.x, minX + minSize) }
        if d.top { minY = min(p.y, maxY - minSize) }
        if d.bottom { maxY = max(p.y, minY + minSize) }

        if let k = k {
            let corner = (d.left || d.right) && (d.top || d.bottom)
            if corner {
                let anchor = CGPoint(x: d.left ? s.maxX : s.minX, y: d.top ? s.maxY : s.minY)
                return fromAnchor(anchor, p, k)
            } else if d.left || d.right {
                var w = maxX - minX
                var h = w / k
                if h > 1 { h = 1; w = h * k }
                var r = CGRect(x: d.left ? s.maxX - w : s.minX, y: s.midY - h / 2, width: w, height: h)
                r.origin.y = min(max(r.minY, 0), 1 - h)
                return r
            } else {
                var h = maxY - minY
                var w = h * k
                if w > 1 { w = 1; h = w / k }
                var r = CGRect(x: s.midX - w / 2, y: d.top ? s.maxY - h : s.minY, width: w, height: h)
                r.origin.x = min(max(r.minX, 0), 1 - w)
                return r
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func fromAnchor(_ a: CGPoint, _ p: CGPoint, _ k: CGFloat?) -> CGRect {
        var w = abs(p.x - a.x), h = abs(p.y - a.y)
        let sx: CGFloat = p.x >= a.x ? 1 : -1
        let sy: CGFloat = p.y >= a.y ? 1 : -1
        if let k = k {
            if h == 0 || w / h > k { w = h * k } else { h = w / k }
            let maxW = sx > 0 ? 1 - a.x : a.x
            let maxH = sy > 0 ? 1 - a.y : a.y
            if w > maxW { w = maxW; h = w / k }
            if h > maxH { h = maxH; w = h * k }
        }
        w = max(w, 0.01)
        h = max(h, 0.01)
        return CGRect(x: sx > 0 ? a.x : a.x - w, y: sy > 0 ? a.y : a.y - h, width: w, height: h)
    }
}

struct CropOverlay: View {
    let fit: CGRect
    let crop: CGRect
    let active: Bool

    var body: some View {
        let r = CGRect(x: fit.minX + crop.minX * fit.width, y: fit.minY + crop.minY * fit.height,
                       width: crop.width * fit.width, height: crop.height * fit.height)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(fit)
                p.addRect(r)
            }
            .fill(Color.black.opacity(active ? 0.55 : 0.75), style: FillStyle(eoFill: true))
            Path { p in p.addRect(r) }
                .stroke(Color.white, lineWidth: 1.5)
            if active {
                Path { p in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY))
                        p.addLine(to: CGPoint(x: x, y: r.maxY))
                        let y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: r.minX, y: y))
                        p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.45), lineWidth: 0.7)
                Path { p in
                    let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                               CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                               CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
                               CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
                    for pt in pts { p.addRect(CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)) }
                }
                .fill(Color.white)
            }
        }
        .allowsHitTesting(false)
    }
}
