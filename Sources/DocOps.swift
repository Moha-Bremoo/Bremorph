import Foundation
import AppKit
import AVFoundation
import ImageIO
import Quartz

enum DocOps {
    // MARK: Documents (textutil ships with macOS)

    static func textutil(_ input: URL, format: String) throws -> URL {
        let same = input.pathExtension.lowercased() == format
        let out = Paths.output(for: input, suffix: same ? "converted" : nil, ext: format)
        try Shell.run("/usr/bin/textutil", ["-convert", format, "-output", out.path, input.path])
        return out
    }

    @MainActor
    static func toPDF(_ input: URL, output: URL) throws {
        let attr = try NSAttributedString(url: input, options: [:], documentAttributes: nil)
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { throw BremorphError("Printing unavailable") }
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = output

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.appearance = NSAppearance(named: .aqua)
        tv.backgroundColor = .white
        tv.textContainer?.widthTracksTextView = true
        tv.textStorage?.setAttributedString(attr)
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height
            tv.frame = NSRect(x: 0, y: 0, width: width, height: max(h + 20, 100))
        }
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw BremorphError("Couldn't create the PDF") }
    }

    // MARK: Subtitles

    static func srtToVtt(_ input: URL) throws -> URL {
        let text = try String(contentsOf: input, encoding: .utf8)
        var lines: [String] = ["WEBVTT", ""]
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            if line.contains("-->") { line = line.replacingOccurrences(of: ",", with: ".") }
            lines.append(line)
        }
        let out = Paths.output(for: input, ext: "vtt")
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func vttToSrt(_ input: URL) throws -> URL {
        let text = try String(contentsOf: input, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let blocks = text.components(separatedBy: "\n\n")
        var cues: [String] = []
        for block in blocks {
            var lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timeIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timeIdx].components(separatedBy: "-->")
            guard timing.count == 2 else { continue }
            func fix(_ t: String) -> String {
                var s = t.trimmingCharacters(in: .whitespaces)
                if let space = s.firstIndex(of: " ") { s = String(s[..<space]) } // drop cue settings
                if s.components(separatedBy: ":").count == 2 { s = "00:" + s }
                return s.replacingOccurrences(of: ".", with: ",")
            }
            let body = Array(lines[(timeIdx + 1)...])
            lines = ["\(cues.count + 1)", "\(fix(timing[0])) --> \(fix(timing[1]))"] + body
            cues.append(lines.joined(separator: "\n"))
        }
        let out = Paths.output(for: input, ext: "srt")
        try (cues.joined(separator: "\n\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func subtitleToText(_ input: URL) throws -> URL {
        let text = try String(contentsOf: input, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        var lines: [String] = []
        var last = ""
        for block in text.components(separatedBy: "\n\n") {
            let rows = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let i = rows.firstIndex(where: { $0.contains("-->") }) else { continue }
            for row in rows[(i + 1)...] {
                // Drop simple tags like <i> and {\an8}
                var clean = row.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                clean = clean.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                clean = clean.trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty && clean != last { lines.append(clean); last = clean }
            }
        }
        let out = Paths.output(for: input, ext: "txt")
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    // MARK: Archives

    static func zip(_ inputs: [URL]) throws -> URL {
        let dir = inputs[0].deletingLastPathComponent()
        if inputs.count == 1 {
            let out = Paths.output(for: inputs[0], ext: "zip")
            try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", inputs[0].path, out.path])
            return out
        }
        let out = Paths.unique(folder: Paths.folder(for: inputs[0]), name: "Archive", ext: "zip")
        try Shell.run("/usr/bin/zip", ["-r", "-q", "-y", out.path] + relativeNames(inputs, base: dir), cwd: dir)
        return out
    }

    static func tarGz(_ inputs: [URL]) throws -> URL {
        let dir = inputs[0].deletingLastPathComponent()
        let out = inputs.count == 1
            ? Paths.output(for: inputs[0], ext: "tar.gz")
            : Paths.unique(folder: Paths.folder(for: inputs[0]), name: "Archive", ext: "tar.gz")
        try Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", dir.path] + relativeNames(inputs, base: dir))
        return out
    }

    /// Paths relative to `base` when possible (files from other folders keep absolute paths).
    static func relativeNames(_ inputs: [URL], base: URL) -> [String] {
        inputs.map { u in
            u.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path ? u.lastPathComponent : u.path
        }
    }

    static func extract(_ input: URL) throws -> URL {
        let name = input.lastPathComponent.lowercased()
        let ext = input.pathExtension.lowercased()
        var base = input.deletingPathExtension()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.xz") { base = base.deletingPathExtension() }

        // A single compressed file (not a tarball)
        if (ext == "gz" || ext == "bz2") && !name.hasSuffix(".tar.gz") && !name.hasSuffix(".tar.bz2") {
            let out = Paths.unique(folder: Paths.folder(for: input), name: base.lastPathComponent, ext: "")
            let tool = ext == "gz" ? "/usr/bin/gunzip" : "/usr/bin/bunzip2"
            do { try Shell.run(tool, ["-c", input.path], stdoutTo: out) } catch {
                try? FileManager.default.removeItem(at: out); throw error
            }
            return out
        }

        let dest = Paths.unique(folder: Paths.folder(for: input), name: base.lastPathComponent, ext: "")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            if ext == "zip" {
                try Shell.run("/usr/bin/ditto", ["-x", "-k", input.path, dest.path])
            } else {
                try Shell.run("/usr/bin/tar", ["-xf", input.path, "-C", dest.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        // If the archive held a single folder, return that instead of wrapping it twice.
        if let items = try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }),
           items.count == 1 {
            return items[0]
        }
        return dest
    }
}

// MARK: - File info

enum InfoOps {
    static func describe(_ url: URL) async throws -> String {
        var lines: [String] = [url.lastPathComponent]
        let size = PDFOps.fileSize(url)
        lines.append(L("Size:") + " " + ByteCountFormatter().string(fromByteCount: size))
        switch FileKind.detect(url) {
        case .image:
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
                    lines.append(L("Dimensions:") + " " + ltr("\(w) × \(h) px"))
                }
                if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    let make = tiff[kCGImagePropertyTIFFMake] as? String ?? ""
                    let model = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
                    if !(make + model).isEmpty { lines.append(L("Camera:") + " " + "\(make) \(model)".trimmingCharacters(in: .whitespaces)) }
                }
                if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any],
                   let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    lines.append(L("Taken:") + " \(date)")
                }
                lines.append(p[kCGImagePropertyGPSDictionary] != nil ? L("Location: ⚠️ GPS location is embedded") : L("Location: none"))
            }
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            let dur = try await asset.load(.duration).seconds
            if dur.isFinite { lines.append(L("Duration:") + String(format: " %d:%02d", Int(dur) / 60, Int(dur) % 60)) }
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                let s = try await v.load(.naturalSize)
                let fps = try await v.load(.nominalFrameRate)
                lines.append(L("Video:") + " \(Int(abs(s.width))) × \(Int(abs(s.height))), \(String(format: "%.0f", fps)) fps")
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first,
               let fd = try await a.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                lines.append(L("Audio:") + " \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch")
            }
            let meta = try await asset.load(.metadata)
            let hasLocation = meta.contains { ($0.identifier?.rawValue ?? "").lowercased().contains("location") }
            lines.append(hasLocation ? L("Location: ⚠️ GPS location is embedded") : L("Location: none"))
        case .pdf:
            if let doc = PDFDocument(url: url) {
                lines.append(L("Pages:") + " \(doc.pageCount)")
                let a = doc.documentAttributes ?? [:]
                for (key, label) in [(PDFDocumentAttribute.titleAttribute, "Title"), (.authorAttribute, "Author"),
                                     (.creatorAttribute, "Creator"), (.producerAttribute, "Producer")] {
                    if let v = a[key] as? String, !v.isEmpty { lines.append(L(label) + ": \(v)") }
                }
            }
        default: break
        }
        return lines.joined(separator: "\n")
    }
}
