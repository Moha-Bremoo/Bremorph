import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Quartz

struct MetaFields {
    var title = ""
    var artist = ""      // Artist / Author / Creator
    var album = ""
    var comment = ""     // Description / Comment / Subject
    var copyright = ""
    var date = ""
    var keywords = ""
    var hasLocation = false
}

@MainActor
final class MetadataModel: ObservableObject {
    let url: URL
    let kind: FileKind
    @Published var fields = MetaFields()
    @Published var removeLocation = false
    @Published var replaceOriginal = false
    @Published var status: String?
    @Published var busy = false
    private var original = MetaFields()

    init(url: URL) {
        self.url = url
        self.kind = FileKind.detect(url)
    }

    func load() async {
        let f = await MetadataIO.read(url, kind: kind)
        fields = f
        original = f
    }

    func save() {
        busy = true
        status = nil
        let url = self.url, kind = self.kind, fields = self.fields, original = self.original
        let removeLoc = removeLocation, replace = replaceOriginal
        Task.detached {
            do {
                let out = try await MetadataIO.write(url, kind: kind, fields: fields, original: original,
                                                     removeLocation: removeLoc, replaceOriginal: replace)
                await MainActor.run {
                    self.busy = false
                    self.status = LF("Saved %@", out.lastPathComponent)
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }
}

enum MetadataIO {
    // MARK: Read

    static func read(_ url: URL, kind: FileKind) async -> MetaFields {
        var f = MetaFields()
        switch kind {
        case .image:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return f }
            let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            f.title = iptc[kCGImagePropertyIPTCObjectName] as? String ?? ""
            f.comment = tiff[kCGImagePropertyTIFFImageDescription] as? String ?? (iptc[kCGImagePropertyIPTCCaptionAbstract] as? String ?? "")
            f.artist = tiff[kCGImagePropertyTIFFArtist] as? String ?? (iptc[kCGImagePropertyIPTCByline] as? [String])?.first ?? ""
            f.copyright = tiff[kCGImagePropertyTIFFCopyright] as? String ?? (iptc[kCGImagePropertyIPTCCopyrightNotice] as? String ?? "")
            f.date = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? ""
            f.keywords = (iptc[kCGImagePropertyIPTCKeywords] as? [String])?.joined(separator: ", ") ?? ""
            f.hasLocation = p[kCGImagePropertyGPSDictionary] != nil
        case .pdf:
            let a = PDFDocument(url: url)?.documentAttributes ?? [:]
            f.title = a[PDFDocumentAttribute.titleAttribute] as? String ?? ""
            f.artist = a[PDFDocumentAttribute.authorAttribute] as? String ?? ""
            f.comment = a[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
            if let k = a[PDFDocumentAttribute.keywordsAttribute] as? [String] { f.keywords = k.joined(separator: ", ") }
            else if let k = a[PDFDocumentAttribute.keywordsAttribute] as? String { f.keywords = k }
            f.copyright = a[PDFDocumentAttribute.creatorAttribute] as? String ?? ""
        case .video, .audio:
            if Helpers.ffprobe != nil {
                let t = FF.tags(url)
                f.title = t["title"] ?? ""
                f.artist = t["artist"] ?? t["author"] ?? ""
                f.album = t["album"] ?? ""
                f.comment = t["comment"] ?? t["description"] ?? ""
                f.copyright = t["copyright"] ?? ""
                f.date = t["date"] ?? t["creation_time"] ?? ""
                f.keywords = t["keywords"] ?? t["genre"] ?? ""
                f.hasLocation = t.keys.contains { $0.contains("location") }
            } else {
                let asset = AVURLAsset(url: url)
                let items = (try? await asset.load(.commonMetadata)) ?? []
                func value(_ id: AVMetadataIdentifier) async -> String {
                    guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return "" }
                    return (try? await item.load(.stringValue)) ?? ""
                }
                f.title = await value(.commonIdentifierTitle)
                f.artist = await value(.commonIdentifierArtist)
                f.album = await value(.commonIdentifierAlbumName)
                f.comment = await value(.commonIdentifierDescription)
                f.copyright = await value(.commonIdentifierCopyrights)
                f.date = await value(.commonIdentifierCreationDate)
            }
        default:
            break
        }
        return f
    }

    // MARK: Write

    static func write(_ url: URL, kind: FileKind, fields f: MetaFields, original: MetaFields,
                      removeLocation: Bool, replaceOriginal: Bool) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let tmp = try Helpers.tempDir().appendingPathComponent(url.lastPathComponent)
        switch kind {
        case .image: try writeImage(url, to: tmp, fields: f, removeLocation: removeLocation)
        case .pdf: try writePDF(url, to: tmp, fields: f)
        case .video, .audio:
            if Helpers.ffmpeg != nil {
                var args = ["-i", url.path, "-map", "0", "-map_metadata", "0", "-c", "copy"]
                let pairs: [(String, String)] = [("title", f.title), ("artist", f.artist), ("album", f.album),
                                                 ("comment", f.comment), ("copyright", f.copyright), ("date", f.date),
                                                 ("keywords", f.keywords)]
                for (k, v) in pairs { args += ["-metadata", "\(k)=\(v)"] }
                if removeLocation { args += ["-metadata", "location=", "-metadata", "location-eng=", "-metadata", "com.apple.quicktime.location.ISO6709="] }
                if ["mp4", "m4v", "mov", "m4a"].contains(ext) { args += ["-movflags", "use_metadata_tags"] }
                try FF.run(args + [tmp.path])
            } else {
                try await writeAV(url, to: tmp, fields: f)
            }
        default:
            throw BremorphError("Metadata editing isn't available for this file type")
        }
        let final: URL
        if replaceOriginal {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            final = url
        } else {
            final = Paths.output(for: url, suffix: "edited", ext: ext)
            try Helpers.place(tmp, at: final)
        }
        return final
    }

    static func writeImage(_ url: URL, to out: URL, fields f: MetaFields, removeLocation: Bool) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw BremorphError("Couldn't read the image")
        }
        let meta: CGMutableImageMetadata = CGImageSourceCopyMetadataAtIndex(src, 0, nil)
            .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()

        func set(_ dict: CFString, _ key: CFString, _ value: String, xmp: [String]) {
            if value.isEmpty {
                for path in xmp { CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString) }
            } else {
                CGImageMetadataSetValueMatchingImageProperty(meta, dict, key, value as CFString)
            }
        }
        set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName, f.title, xmp: ["dc:title", "photoshop:Headline"])
        set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, f.comment, xmp: ["dc:description", "tiff:ImageDescription"])
        set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, f.artist, xmp: ["dc:creator", "tiff:Artist"])
        set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright, f.copyright, xmp: ["dc:rights", "tiff:Copyright"])
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, f.date, xmp: ["exif:DateTimeOriginal", "photoshop:DateCreated"])
        let keywords = f.keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if keywords.isEmpty {
            CGImageMetadataRemoveTagWithPath(meta, nil, "dc:subject" as CFString)
        } else {
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords, keywords as CFArray)
        }

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw BremorphError("Couldn't write the image") }
        var opts: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: false]
        if removeLocation { opts[kCGImageMetadataShouldExcludeGPS] = true }
        var err: Unmanaged<CFError>?
        if CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) { return }

        // Fallback: re-encode with the new properties (tiny quality cost for JPEG/HEIC).
        try? FileManager.default.removeItem(at: out)
        guard let dest2 = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw BremorphError("Couldn't write the image") }
        var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFImageDescription] = f.comment
        tiff[kCGImagePropertyTIFFArtist] = f.artist
        tiff[kCGImagePropertyTIFFCopyright] = f.copyright
        props[kCGImagePropertyTIFFDictionary] = tiff
        var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        iptc[kCGImagePropertyIPTCObjectName] = f.title
        iptc[kCGImagePropertyIPTCKeywords] = keywords
        props[kCGImagePropertyIPTCDictionary] = iptc
        if removeLocation { props.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        props[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(dest2, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest2) else { throw BremorphError("Couldn't write the image") }
    }

    static func writePDF(_ url: URL, to out: URL, fields f: MetaFields) throws {
        let doc = try PDFOps.open(url)
        var a = doc.documentAttributes ?? [:]
        a[PDFDocumentAttribute.titleAttribute] = f.title
        a[PDFDocumentAttribute.authorAttribute] = f.artist
        a[PDFDocumentAttribute.subjectAttribute] = f.comment
        a[PDFDocumentAttribute.creatorAttribute] = f.copyright
        a[PDFDocumentAttribute.keywordsAttribute] = f.keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        doc.documentAttributes = a
        try PDFOps.save(doc, to: out)
    }

    static func writeAV(_ url: URL, to out: URL, fields f: MetaFields) async throws {
        let asset = AVURLAsset(url: url)
        func item(_ id: AVMetadataIdentifier, _ v: String) -> AVMetadataItem? {
            guard !v.isEmpty else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = v as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        let items = [item(.commonIdentifierTitle, f.title), item(.commonIdentifierArtist, f.artist),
                     item(.commonIdentifierAlbumName, f.album), item(.commonIdentifierDescription, f.comment),
                     item(.commonIdentifierCopyrights, f.copyright), item(.commonIdentifierCreationDate, f.date)].compactMap { $0 }
        let ext = url.pathExtension.lowercased()
        try await VideoOps.export(asset, preset: AVAssetExportPresetPassthrough, to: out,
                                  type: ext == "m4a" ? .m4a : VideoOps.fileType(for: VideoOps.outExt(for: url)),
                                  progress: { _ in }) { s in s.metadata = items }
    }
}

// MARK: - Window

@MainActor
enum MetadataWindows {
    private static var windows: [NSWindow] = []

    static func open(_ url: URL) {
        let model = MetadataModel(url: url)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("Metadata") + " — " + url.lastPathComponent
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: MetadataView(m: model).tint(Brand.accent).background(AppBackground()).localizedLayout())
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

struct MetadataView: View {
    @ObservedObject var m: MetadataModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: m.url.path)).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading) {
                    Text(m.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(m.kind.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Title", text: $m.fields.title)
                TextField(m.kind == .pdf ? L("Author") : L("Artist / Author"), text: $m.fields.artist)
                if m.kind == .audio || m.kind == .video {
                    TextField("Album", text: $m.fields.album)
                }
                TextField(m.kind == .pdf ? L("Subject") : L("Description"), text: $m.fields.comment)
                TextField(m.kind == .pdf ? L("Creator") : L("Copyright"), text: $m.fields.copyright)
                if m.kind != .pdf {
                    TextField("Date", text: $m.fields.date, prompt: Text(m.kind == .image ? "2026:10:21 14:30:00" : "2026-10-21"))
                }
                TextField("Keywords", text: $m.fields.keywords, prompt: Text("comma, separated"))
                if m.kind == .image || m.kind == .video {
                    Toggle(m.fields.hasLocation ? L("Remove GPS location (this file has one)") : L("Remove GPS location"),
                           isOn: $m.removeLocation)
                }
                Toggle("Replace the original file", isOn: $m.replaceOriginal)
            }
            .formStyle(.grouped)
            HStack {
                if let s = m.status {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if m.busy { ProgressView().controlSize(.small) }
                Button("Save") { m.save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(m.busy)
            }
        }
        .padding(18)
        .frame(width: 480)
        .task { await m.load() }
    }
}
