import Foundation
import AppKit
import Quartz

enum DocFormat {
    case pdf, docx, pages, markdown, epub, rtf, txt, html, odt

    var ext: String {
        switch self {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .pages: return "pages"
        case .markdown: return "md"
        case .epub: return "epub"
        case .rtf: return "rtf"
        case .txt: return "txt"
        case .html: return "html"
        case .odt: return "odt"
        }
    }
}

// MARK: - Simple document model (used for Markdown & EPUB)

struct DocRun {
    var text: String
    var bold = false
    var italic = false
    var link: String? = nil
}

struct DocBlock {
    enum Kind: Equatable { case heading(Int), paragraph, bullet, numbered }
    var kind: Kind
    var runs: [DocRun]
    var plain: String { runs.map(\.text).joined() }
}

enum DocConvert {
    // MARK: Documents

    static func document(_ input: URL, to format: DocFormat) async throws -> URL {
        let ext = input.pathExtension.lowercased()
        let out = Paths.output(for: input, suffix: ext == format.ext ? "converted" : nil, ext: format.ext)

        // Pages files: let Pages do the export when it can.
        if ext == "pages" {
            guard Helpers.hasPages else { throw BremorphError(Helpers.pagesMissing) }
            let direct: String?
            switch format {
            case .pdf: direct = "PDF"
            case .docx: direct = "Microsoft Word"
            case .epub: direct = "EPUB"
            case .txt: direct = "unformatted text"
            case .rtf: direct = "formatted text"
            default: direct = nil
            }
            if let d = direct {
                try IWork.convert(app: "Pages", input: input, output: out, exportAs: d)
                return out
            }
        }

        // LibreOffice keeps page layout best for Word ⇄ PDF/ODT.
        if Helpers.soffice != nil {
            let officeIn: Set<String> = ["doc", "docx", "odt", "rtf", "wordml"]
            if officeIn.contains(ext), [.pdf, .docx, .odt].contains(format), ext != format.ext {
                let produced = try Office.convert(input, to: format.ext)
                try Helpers.place(produced, at: out)
                return out
            }
        }

        let a = try await load(input)
        try await write(a, title: input.deletingPathExtension().lastPathComponent, to: out, format: format)
        return out
    }

    /// Loads any supported document as styled text.
    static func load(_ url: URL) async throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            let html = Markdown.toHTML(try String(contentsOf: url, encoding: .utf8))
            return try await fromHTML(html)
        case "epub":
            return try await fromHTML(try EPUB.extractHTML(url))
        case "textclipping":
            return try clipping(url)
        case "pages":
            guard Helpers.hasPages else { throw BremorphError(Helpers.pagesMissing) }
            let tmp = try Helpers.tempDir().appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".docx")
            try IWork.convert(app: "Pages", input: url, output: tmp, exportAs: "Microsoft Word")
            return try await load(tmp)
        case "pdf":
            return try pdfText(url)
        default:
            return try await MainActor.run {
                try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            }
        }
    }

    static func fromHTML(_ html: String) async throws -> NSAttributedString {
        try await MainActor.run {
            guard let data = html.data(using: .utf8) else { throw BremorphError("Couldn't read the text") }
            return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                .characterEncoding: String.Encoding.utf8.rawValue],
                                          documentAttributes: nil)
        }
    }

    static func clipping(_ url: URL) throws -> NSAttributedString {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let utis = plist["UTI-Data"] as? [String: Any] else {
            throw BremorphError("Couldn't read this text clipping")
        }
        if let rtf = utis["public.rtf"] as? Data, let a = NSAttributedString(rtf: rtf, documentAttributes: nil) { return a }
        for key in ["public.utf8-plain-text", "public.utf16-plain-text", "public.plain-text"] {
            if let s = utis[key] as? String { return NSAttributedString(string: s) }
            if let d = utis[key] as? Data, let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .utf16) {
                return NSAttributedString(string: s)
            }
        }
        throw BremorphError("This clipping has no text")
    }

    static func data(_ a: NSAttributedString, _ type: NSAttributedString.DocumentType) throws -> Data {
        try a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: type])
    }

    static func write(_ a: NSAttributedString, title: String, to out: URL, format: DocFormat) async throws {
        switch format {
        case .pdf:
            try await MainActor.run { try attributedToPDF(a, output: out) }
        case .docx:
            try await MainActor.run { try data(a, .officeOpenXML).write(to: out) }
        case .odt:
            try await MainActor.run { try data(a, .openDocument).write(to: out) }
        case .rtf:
            try await MainActor.run { try data(a, .rtf).write(to: out) }
        case .html:
            try await MainActor.run { try data(a, .html).write(to: out) }
        case .txt:
            try a.string.write(to: out, atomically: true, encoding: .utf8)
        case .markdown:
            try markdown(blocks(from: a)).write(to: out, atomically: true, encoding: .utf8)
        case .epub:
            try EPUB.write(title: title, blocks: blocks(from: a), to: out)
        case .pages:
            guard Helpers.hasPages else { throw BremorphError(Helpers.pagesMissing) }
            let tmp = try Helpers.tempDir().appendingPathComponent(title + ".docx")
            try await MainActor.run { try data(a, .officeOpenXML).write(to: tmp) }
            try IWork.convert(app: "Pages", input: tmp, output: out, exportAs: nil)
        }
    }

    @MainActor
    static func attributedToPDF(_ attr: NSAttributedString, output: URL) throws {
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
            tv.frame = NSRect(x: 0, y: 0, width: width, height: max(lm.usedRect(for: tc).height + 20, 100))
        }
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw BremorphError("Couldn't create the PDF") }
    }

    // MARK: PDF → other formats

    /// PDF text with lines joined back into paragraphs.
    static func pdfText(_ url: URL) throws -> NSAttributedString {
        let doc = try PDFOps.open(url)
        let all = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.attributedString else { continue }
            all.append(page)
            all.append(NSAttributedString(string: "\n\n"))
        }
        // Join soft line breaks: a line that doesn't end a sentence followed by a lowercase letter.
        let s = all.string as NSString
        var joins: [Int] = []
        if s.length > 2 {
            for i in 1..<(s.length - 1) where s.character(at: i) == 10 {
                let prev = s.character(at: i - 1), next = s.character(at: i + 1)
                let prevEnds = [46, 33, 63, 58, 10].contains(Int(prev)) // . ! ? : newline
                if !prevEnds, let scalar = UnicodeScalar(next), CharacterSet.lowercaseLetters.contains(scalar) {
                    joins.append(i)
                }
            }
        }
        for i in joins.reversed() { all.replaceCharacters(in: NSRange(location: i, length: 1), with: " ") }
        return all
    }

    static func pdfTo(_ input: URL, format: DocFormat) async throws -> URL {
        let out = Paths.output(for: input, ext: format.ext)
        let a = try pdfText(input)
        guard a.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else {
            throw BremorphError("This PDF has no selectable text (it may be scanned images).")
        }
        try await write(a, title: input.deletingPathExtension().lastPathComponent, to: out, format: format)
        return out
    }

    static func pdfToPPTX(_ input: URL) throws -> URL {
        let produced = try Office.convert(input, to: "pptx", infilter: "impress_pdf_import")
        let out = Paths.output(for: input, ext: "pptx")
        try Helpers.place(produced, at: out)
        return out
    }

    /// Lines become rows; runs of 2+ spaces or tabs become columns.
    static func pdfToXLSX(_ input: URL) throws -> URL {
        let doc = try PDFOps.open(input)
        var rows: [String] = []
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string ?? ""
            for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let cells = line.replacingOccurrences(of: "\t", with: "  ")
                    .components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                rows.append(cells.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
            }
        }
        let tmp = try Helpers.tempDir().appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".csv")
        try rows.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        let produced = try Office.convert(tmp, to: "xlsx", infilter: "CSV:44,34,76")
        let out = Paths.output(for: input, ext: "xlsx")
        try Helpers.place(produced, at: out)
        return out
    }

    // MARK: Slides

    /// Returns a PDF (temp) of a presentation.
    static func slidesPDF(_ input: URL) throws -> URL {
        if input.pathExtension.lowercased() == "key" {
            guard Helpers.hasKeynote else { throw BremorphError("Keynote files need Apple's Keynote app.") }
            let tmp = try Helpers.tempDir().appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".pdf")
            try IWork.convert(app: "Keynote", input: input, output: tmp, exportAs: "PDF")
            return tmp
        }
        return try Office.convert(input, to: "pdf")
    }

    static func slides(_ input: URL, to format: String) throws -> URL {
        let out = Paths.output(for: input, ext: format)
        if format == "pdf" {
            try Helpers.place(try slidesPDF(input), at: out)
        } else if input.pathExtension.lowercased() == "key" {
            guard Helpers.hasKeynote else { throw BremorphError("Keynote files need Apple's Keynote app.") }
            try IWork.convert(app: "Keynote", input: input, output: out, exportAs: "Microsoft PowerPoint")
        } else {
            try Helpers.place(try Office.convert(input, to: format), at: out)
        }
        return out
    }

    static func slidesToImages(_ input: URL, jpeg: Bool, progress: @escaping ProgressHandler) throws -> URL {
        let pdf = try slidesPDF(input)
        return try PDFOps.toImages(pdf, jpeg: jpeg, nameFrom: input, progress: progress)
    }

    // MARK: Spreadsheets

    static func sheet(_ input: URL, to format: String) throws -> URL {
        let ext = input.pathExtension.lowercased()
        let out = Paths.output(for: input, ext: format)
        var source = input

        if ext == "numbers" {
            guard Helpers.hasNumbers else { throw BremorphError("Numbers files need Apple's Numbers app.") }
            switch format {
            case "xlsx": try IWork.convert(app: "Numbers", input: input, output: out, exportAs: "Microsoft Excel"); return out
            case "csv": try IWork.convert(app: "Numbers", input: input, output: out, exportAs: "CSV"); return out
            case "pdf": try IWork.convert(app: "Numbers", input: input, output: out, exportAs: "PDF"); return out
            default:
                let tmp = try Helpers.tempDir().appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".xlsx")
                try IWork.convert(app: "Numbers", input: input, output: tmp, exportAs: "Microsoft Excel")
                source = tmp
            }
        }

        let srcExt = source.pathExtension.lowercased()
        let infilter: String? = srcExt == "csv" ? "CSV:44,34,76" : (srcExt == "tsv" ? "CSV:9,34,76" : nil)
        let produced: URL
        switch format {
        case "csv": produced = try Office.convert(source, to: "csv", filter: "Text - txt - csv (StarCalc):44,34,76", infilter: infilter)
        case "tsv": produced = try Office.convert(source, to: "csv", filter: "Text - txt - csv (StarCalc):9,34,76", infilter: infilter)
        default: produced = try Office.convert(source, to: format, infilter: infilter)
        }
        try Helpers.place(produced, at: out)
        return out
    }

    // MARK: Styled text → blocks

    static func blocks(from a: NSAttributedString) -> [DocBlock] {
        let full = a.string as NSString
        var sizeCounts: [CGFloat: Int] = [:]
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            if let f = v as? NSFont { sizeCounts[f.pointSize.rounded(), default: 0] += r.length }
        }
        let base = sizeCounts.max { $0.value < $1.value }?.key ?? 12
        let bulletRx = try? NSRegularExpression(pattern: "^\\s*[•◦▪●■–\\-*]\\s+")
        let numberRx = try? NSRegularExpression(pattern: "^\\s*\\d{1,3}(?:[.)]\\s+|\\t)")

        var out: [DocBlock] = []
        full.enumerateSubstrings(in: NSRange(location: 0, length: full.length), options: .byParagraphs) { sub, range, _, _ in
            guard let sub = sub, !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            var runs: [DocRun] = []
            var maxSize: CGFloat = 0
            var allBold = true
            a.enumerateAttributes(in: range) { attrs, r, _ in
                let t = full.substring(with: r)
                let f = attrs[.font] as? NSFont
                let traits = f.map { NSFontManager.shared.traits(of: $0) } ?? []
                let bold = traits.contains(.boldFontMask)
                let italic = traits.contains(.italicFontMask)
                if let f = f { maxSize = max(maxSize, f.pointSize) }
                if !bold && !t.trimmingCharacters(in: .whitespaces).isEmpty { allBold = false }
                var link: String? = nil
                if let l = attrs[.link] as? URL { link = l.absoluteString } else if let s = attrs[.link] as? String { link = s }
                if var last = runs.last, last.bold == bold, last.italic == italic, last.link == link {
                    last.text += t
                    runs[runs.count - 1] = last
                } else {
                    runs.append(DocRun(text: t, bold: bold, italic: italic, link: link))
                }
            }
            var kind: DocBlock.Kind = .paragraph
            let plain = sub.trimmingCharacters(in: .whitespaces)
            if maxSize >= base * 1.6 { kind = .heading(1) }
            else if maxSize >= base * 1.3 { kind = .heading(2) }
            else if maxSize >= base * 1.08 && allBold && plain.count < 120 { kind = .heading(3) }
            let ns = plain as NSString
            let whole = NSRange(location: 0, length: ns.length)
            if kind == .paragraph, let rx = bulletRx, rx.firstMatch(in: plain, range: whole) != nil {
                kind = .bullet
                runs = stripPrefix(runs, rx)
            } else if kind == .paragraph, let rx = numberRx, rx.firstMatch(in: plain, range: whole) != nil {
                kind = .numbered
                runs = stripPrefix(runs, rx)
            }
            out.append(DocBlock(kind: kind, runs: runs))
        }
        return out
    }

    private static func stripPrefix(_ runs: [DocRun], _ rx: NSRegularExpression) -> [DocRun] {
        guard var first = runs.first else { return runs }
        let t = first.text as NSString
        if let m = rx.firstMatch(in: first.text, range: NSRange(location: 0, length: t.length)) {
            first.text = t.substring(from: m.range.upperBound)
        }
        var r = runs
        r[0] = first
        return r
    }

    // MARK: Markdown output

    static func markdown(_ blocks: [DocBlock]) -> String {
        func wrap(_ text: String, _ marker: String) -> String {
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return text }
            let lead = String(text.prefix(while: { $0 == " " }))
            let trail = String(text.reversed().prefix(while: { $0 == " " }))
            return lead + marker + core + marker + trail
        }
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "`", with: "\\`")
        }
        var lines: [String] = []
        var number = 0
        for b in blocks {
            let isHeading: Bool
            if case .heading = b.kind { isHeading = true } else { isHeading = false }
            var inline = b.runs.map { r -> String in
                var t = escape(r.text.replacingOccurrences(of: "\n", with: " "))
                if !isHeading {
                    if r.bold && r.italic { t = wrap(t, "***") } else if r.bold { t = wrap(t, "**") } else if r.italic { t = wrap(t, "_") }
                }
                if let l = r.link, !t.trimmingCharacters(in: .whitespaces).isEmpty { t = "[\(t)](\(l))" }
                return t
            }.joined()
            inline = inline.trimmingCharacters(in: .whitespaces)
            switch b.kind {
            case .heading(let n):
                number = 0
                lines.append(String(repeating: "#", count: n) + " " + inline)
            case .bullet:
                number = 0
                lines.append("- " + inline)
            case .numbered:
                number += 1
                lines.append("\(number). " + inline)
            case .paragraph:
                number = 0
                lines.append(inline)
            }
        }
        // Keep list items together, blank lines elsewhere.
        var result = ""
        for (i, line) in lines.enumerated() {
            if i > 0 {
                let prevList = blocks[i - 1].kind == .bullet || blocks[i - 1].kind == .numbered
                let thisList = blocks[i].kind == .bullet || blocks[i].kind == .numbered
                result += (prevList && thisList) ? "\n" : "\n\n"
            }
            result += line
        }
        return result + "\n"
    }

    // MARK: XHTML output (for EPUB)

    static func xhtmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func xhtmlBody(_ blocks: [DocBlock]) -> String {
        var html = ""
        var openList: String? = nil
        func closeList() { if let l = openList { html += "</\(l)>\n"; openList = nil } }
        for b in blocks {
            let inline = b.runs.map { r -> String in
                var t = xhtmlEscape(r.text.replacingOccurrences(of: "\n", with: " "))
                if r.bold { t = "<strong>\(t)</strong>" }
                if r.italic { t = "<em>\(t)</em>" }
                if let l = r.link { t = "<a href=\"\(xhtmlEscape(l))\">\(t)</a>" }
                return t
            }.joined()
            switch b.kind {
            case .heading(let n):
                closeList()
                html += "<h\(n)>\(inline)</h\(n)>\n"
            case .bullet, .numbered:
                let tag = b.kind == .bullet ? "ul" : "ol"
                if openList != tag { closeList(); html += "<\(tag)>\n"; openList = tag }
                html += "<li>\(inline)</li>\n"
            case .paragraph:
                closeList()
                html += "<p>\(inline)</p>\n"
            }
        }
        closeList()
        return html
    }
}

// MARK: - EPUB

enum EPUB {
    static func write(title: String, blocks: [DocBlock], to out: URL) throws {
        // Chapters start at top-level headings.
        let topLevel: Int = blocks.contains { $0.kind == .heading(1) } ? 1 : (blocks.contains { $0.kind == .heading(2) } ? 2 : 0)
        var chapters: [(String, [DocBlock])] = []
        for b in blocks {
            if topLevel > 0, b.kind == .heading(topLevel) {
                chapters.append((b.plain.trimmingCharacters(in: .whitespacesAndNewlines), [b]))
            } else if chapters.isEmpty {
                chapters.append((title, [b]))
            } else {
                chapters[chapters.count - 1].1.append(b)
            }
        }
        if chapters.isEmpty { chapters = [(title, [])] }

        let dir = try Helpers.tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: dir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: dir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        body { font-family: serif; line-height: 1.5; margin: 0 5%; }
        h1, h2, h3 { font-family: sans-serif; line-height: 1.2; }
        """.write(to: dir.appendingPathComponent("OEBPS/style.css"), atomically: true, encoding: .utf8)

        let esc = DocConvert.xhtmlEscape
        var manifest = "", spine = "", nav = ""
        for (i, ch) in chapters.enumerated() {
            let name = String(format: "chapter%03d.xhtml", i + 1)
            let page = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>\(esc(ch.0))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
            <body>
            \(DocConvert.xhtmlBody(ch.1))
            </body>
            </html>
            """
            try page.write(to: dir.appendingPathComponent("OEBPS/\(name)"), atomically: true, encoding: .utf8)
            manifest += "    <item id=\"c\(i + 1)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "    <itemref idref=\"c\(i + 1)\"/>\n"
            nav += "      <li><a href=\"\(name)\">\(esc(ch.0.isEmpty ? "Chapter \(i + 1)" : ch.0))</a></li>\n"
        }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Contents</title></head>
        <body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>
        \(nav)    </ol></nav></body>
        </html>
        """.write(to: dir.appendingPathComponent("OEBPS/nav.xhtml"), atomically: true, encoding: .utf8)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(esc(title))</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(iso.string(from: Date()))</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="style.css" media-type="text/css"/>
        \(manifest)  </manifest>
          <spine>
        \(spine)  </spine>
        </package>
        """.write(to: dir.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)

        let tmpOut = dir.appendingPathComponent("book.epub")
        try Shell.run("/usr/bin/zip", ["-X0", "-q", tmpOut.path, "mimetype"], cwd: dir)
        try Shell.run("/usr/bin/zip", ["-Xr9Dq", tmpOut.path, "META-INF", "OEBPS"], cwd: dir)
        try Helpers.place(tmpOut, at: out)
    }

    /// Joins the book's chapters into one HTML document.
    static func extractHTML(_ url: URL) throws -> String {
        let dir = try Helpers.tempDir()
        try Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, dir.path])
        let container = try String(contentsOf: dir.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfPath = firstMatch("full-path=\"([^\"]+)\"", in: container) else { throw BremorphError("Not a valid EPUB") }
        let opfURL = dir.appendingPathComponent(opfPath)
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        var hrefs: [String: String] = [:]
        for tag in allMatches("<item\\b[^>]*>", in: opf) {
            if let id = firstMatch("\\bid=\"([^\"]+)\"", in: tag), let href = firstMatch("\\bhref=\"([^\"]+)\"", in: tag) {
                hrefs[id] = href.removingPercentEncoding ?? href
            }
        }
        var bodies = ""
        for idref in allMatches("<itemref\\b[^>]*>", in: opf).compactMap({ firstMatch("idref=\"([^\"]+)\"", in: $0) }) {
            guard let href = hrefs[idref] else { continue }
            let file = opfURL.deletingLastPathComponent().appendingPathComponent(href)
            guard let html = try? String(contentsOf: file, encoding: .utf8) else { continue }
            bodies += firstMatch("(?s)<body[^>]*>(.*)</body>", in: html) ?? html
            bodies += "\n"
        }
        return "<html><head><meta charset=\"utf-8\"></head><body>\(bodies)</body></html>"
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func allMatches(_ pattern: String, in s: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        return rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }
}

// MARK: - Markdown input

enum Markdown {
    static func toHTML(_ md: String) -> String {
        var html = ""
        var paragraph: [String] = []
        var list: String? = nil
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { html += "<p>\(inline(paragraph.joined(separator: " ")))</p>\n"; paragraph = [] }
        }
        func closeList() { if let l = list { html += "</\(l)>\n"; list = nil } }

        for raw in md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inCode {
                    html += "<pre><code>\(DocConvert.xhtmlEscape(code.joined(separator: "\n")))</code></pre>\n"
                    code = []; inCode = false
                } else { flushParagraph(); closeList(); inCode = true }
                continue
            }
            if inCode { code.append(line); continue }
            if t.isEmpty { flushParagraph(); closeList(); continue }
            if let m = EPUB.firstMatch("^(#{1,6})\\s+(.*)$", in: t) {
                flushParagraph(); closeList()
                let level = t.prefix(while: { $0 == "#" }).count
                _ = m
                let text = String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                html += "<h\(level)>\(inline(text))</h\(level)>\n"
                continue
            }
            if t == "---" || t == "***" || t == "___" { flushParagraph(); closeList(); html += "<hr/>\n"; continue }
            if t.hasPrefix(">") {
                flushParagraph(); closeList()
                html += "<blockquote><p>\(inline(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)))</p></blockquote>\n"
                continue
            }
            if let item = EPUB.firstMatch("^[-*+]\\s+(.*)$", in: t) {
                flushParagraph()
                if list != "ul" { closeList(); html += "<ul>\n"; list = "ul" }
                html += "<li>\(inline(item))</li>\n"
                continue
            }
            if let item = EPUB.firstMatch("^\\d+[.)]\\s+(.*)$", in: t) {
                flushParagraph()
                if list != "ol" { closeList(); html += "<ol>\n"; list = "ol" }
                html += "<li>\(inline(item))</li>\n"
                continue
            }
            closeList()
            paragraph.append(t)
        }
        if inCode { html += "<pre><code>\(DocConvert.xhtmlEscape(code.joined(separator: "\n")))</code></pre>\n" }
        flushParagraph()
        closeList()
        return "<html><head><meta charset=\"utf-8\"><style>body{font-family:-apple-system,Helvetica;font-size:13px} code,pre{font-family:Menlo,monospace}</style></head><body>\(html)</body></html>"
    }

    static func inline(_ s: String) -> String {
        var t = DocConvert.xhtmlEscape(s)
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("!\\[([^\\]]*)\\]\\(([^)]+)\\)", "$1"),
            ("\\[([^\\]]+)\\]\\(([^)]+)\\)", "<a href=\"$2\">$1</a>"),
            ("\\*\\*\\*([^*]+)\\*\\*\\*", "<strong><em>$1</em></strong>"),
            ("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"),
            ("__([^_]+)__", "<strong>$1</strong>"),
            ("\\*([^*]+)\\*", "<em>$1</em>"),
            ("(?<![\\w])_([^_]+)_(?![\\w])", "<em>$1</em>"),
        ]
        for (pattern, template) in rules {
            if let rx = try? NSRegularExpression(pattern: pattern) {
                t = rx.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
            }
        }
        return t
    }
}
