import Foundation
import Quartz
import UniformTypeIdentifiers

enum PDFOps {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw BremorphError(LF("Couldn't open %@", url.lastPathComponent)) }
        if doc.isLocked { throw BremorphError(LF("%@ is password-protected", url.lastPathComponent)) }
        return doc
    }

    static func save(_ doc: PDFDocument, to url: URL) throws {
        guard doc.write(to: url) else { throw BremorphError(LF("Couldn't save %@", url.lastPathComponent)) }
    }

    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let rotated = abs(page.rotation) % 180 == 90
        let pw = rotated ? bounds.height : bounds.width
        let ph = rotated ? bounds.width : bounds.height
        let w = max(1, Int(pw * scale)), h = max(1, Int(ph * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        page.transform(ctx, for: .mediaBox)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    static func toImages(_ input: URL, jpeg: Bool, nameFrom: URL? = nil, progress: ProgressHandler) throws -> URL {
        let doc = try open(input)
        let named = nameFrom ?? input
        let folder = try Paths.newFolder(for: named, suffix: "images")
        let base = named.deletingPathExtension().lastPathComponent
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let img = render(page, dpi: 300) else { continue }
            let num = String(format: "%0\(digits)d", i + 1)
            let out = folder.appendingPathComponent("\(base) \(num)").appendingPathExtension(jpeg ? "jpg" : "png")
            try ImageOps.write(img, to: out, type: jpeg ? .jpeg : .png, quality: jpeg ? 0.9 : nil)
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        return folder
    }

    static func toText(_ input: URL) throws -> URL {
        let doc = try open(input)
        let out = Paths.output(for: input, ext: "txt")
        try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func merge(_ inputs: [URL]) throws -> URL {
        let merged = PDFDocument()
        for url in inputs {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        let out = Paths.unique(folder: Paths.folder(for: inputs[0]), name: "Merged", ext: "pdf")
        try save(merged, to: out)
        return out
    }

    static func split(_ input: URL, progress: ProgressHandler) throws -> URL {
        let doc = try open(input)
        let folder = try Paths.newFolder(for: input, suffix: "pages")
        let base = input.deletingPathExtension().lastPathComponent
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let num = String(format: "%0\(digits)d", i + 1)
            try save(single, to: folder.appendingPathComponent("\(base) page \(num).pdf"))
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        return folder
    }

    /// "1-3, 5, 8-" → zero-based indexes.
    static func parseRange(_ text: String, count: Int) -> [Int] {
        var result: [Int] = []
        for part in text.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if let dash = p.firstIndex(of: "-") {
                let a = Int(p[..<dash].trimmingCharacters(in: .whitespaces)) ?? 1
                let b = Int(p[p.index(after: dash)...].trimmingCharacters(in: .whitespaces)) ?? count
                if a <= b {
                    for n in a...b where n >= 1 && n <= count { result.append(n - 1) }
                }
            } else if let n = Int(p), n >= 1, n <= count {
                result.append(n - 1)
            }
        }
        return result
    }

    static func extract(_ input: URL, range: String) throws -> URL {
        let doc = try open(input)
        let idx = parseRange(range, count: doc.pageCount)
        guard !idx.isEmpty else { throw BremorphError(LF("No pages match “%@” (this PDF has %d pages)", range, doc.pageCount)) }
        let outDoc = PDFDocument()
        for i in idx {
            if let page = doc.page(at: i)?.copy() as? PDFPage { outDoc.insert(page, at: outDoc.pageCount) }
        }
        let safe = range.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/", with: "-")
        let out = Paths.output(for: input, suffix: "pages \(safe)", ext: "pdf")
        try save(outDoc, to: out)
        return out
    }

    static func rotate(_ input: URL, degrees: Int) throws -> URL {
        let doc = try open(input)
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { page.rotation = (page.rotation + degrees) % 360 }
        }
        let out = Paths.output(for: input, suffix: "rotated", ext: "pdf")
        try save(doc, to: out)
        return out
    }

    static func stripMetadata(_ input: URL) throws -> URL {
        let doc = try open(input)
        doc.documentAttributes = [:]
        let out = Paths.output(for: input, suffix: "clean", ext: "pdf")
        try save(doc, to: out)
        return out
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static func compress(_ input: URL, strong: Bool, quality: Double, progress: ProgressHandler) throws -> EngineResult {
        let doc = try open(input)
        let out = Paths.output(for: input, suffix: "compressed", ext: "pdf")
        if strong {
            try rasterize(doc, to: out, quality: quality, progress: progress)
        } else {
            let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
            let filter: QuartzFilter? = QuartzFilter(url: filterURL)
            var ok = false
            if let filter = filter {
                ok = doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
            }
            if !ok { try rasterize(doc, to: out, quality: quality, progress: progress) }
        }
        let before = fileSize(input), after = fileSize(out)
        let f = ByteCountFormatter()
        var msg = ltr("\(f.string(fromByteCount: before)) → \(f.string(fromByteCount: after))")
        if after >= before { msg += "\n" + L("This PDF is already well compressed. Try Strong mode.") }
        return EngineResult(outputs: [out], message: msg)
    }

    /// Tries progressively stronger compression until the PDF is under the target.
    static func fitSize(_ input: URL, targetBytes: Int64, progress: ProgressHandler) throws -> EngineResult {
        let doc = try open(input)
        let before = fileSize(input)
        let f = ByteCountFormatter()
        let out = Paths.output(for: input, suffix: Paths.sizeTag(targetBytes), ext: "pdf")
        let tmpDir = try Helpers.tempDir()
        // 1) Quartz "Reduce File Size" keeps text selectable.
        let quartzOut = tmpDir.appendingPathComponent("q.pdf")
        let qf: QuartzFilter? = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter"))
        if let filter = qf,
           doc.write(to: quartzOut, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]),
           fileSize(quartzOut) <= targetBytes {
            try Helpers.place(quartzOut, at: out)
            return EngineResult(outputs: [out], message: ltr("\(f.string(fromByteCount: before)) → \(f.string(fromByteCount: fileSize(out)))") + " " + L("(text kept)"))
        }
        // 2) Re-draw pages as JPEG at decreasing resolution/quality.
        let steps: [(CGFloat, Double)] = [(150, 0.75), (130, 0.65), (110, 0.55), (96, 0.5), (85, 0.42), (72, 0.36), (60, 0.3), (50, 0.25)]
        var last: URL? = nil
        for (i, step) in steps.enumerated() {
            let attempt = tmpDir.appendingPathComponent("r\(i).pdf")
            try rasterize(doc, to: attempt, quality: step.1, dpi: step.0, progress: { p in progress((Double(i) + p) / Double(steps.count)) })
            last = attempt
            if fileSize(attempt) <= targetBytes { break }
        }
        guard let result = last else { throw BremorphError("Couldn't compress this PDF") }
        try Helpers.place(result, at: out)
        let after = fileSize(out)
        var msg = ltr("\(f.string(fromByteCount: before)) → \(f.string(fromByteCount: after))")
        if after > targetBytes { msg += "\n" + L("This is as small as it gets while staying readable.") }
        return EngineResult(outputs: [out], message: msg)
    }

    /// Re-draws every page as a JPEG (smallest files; text is no longer selectable).
    static func rasterize(_ doc: PDFDocument, to out: URL, quality: Double, dpi forcedDPI: CGFloat? = nil, progress: ProgressHandler) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw BremorphError("Couldn't create PDF") }
        let dpi: CGFloat = forcedDPI ?? (quality > 0.75 ? 150 : (quality > 0.45 ? 120 : 96))
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let img = render(page, dpi: dpi) else { continue }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            CGImageDestinationFinalize(dest)
            guard let provider = CGDataProvider(data: data),
                  let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { continue }
            var r = CGRect(x: 0, y: 0, width: CGFloat(img.width) * 72 / dpi, height: CGFloat(img.height) * 72 / dpi)
            ctx.beginPage(mediaBox: &r)
            ctx.draw(jpeg, in: r)
            ctx.endPage()
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        ctx.closePDF()
    }
}
