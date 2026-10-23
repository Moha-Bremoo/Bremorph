import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct BremorphError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { L(message) }
}

struct EngineResult {
    var outputs: [URL] = []
    var message: String? = nil
}

typealias ProgressHandler = @Sendable (Double) -> Void

// MARK: - Output paths

enum Paths {
    /// A size for file names, always in English digits and units ("65 KB", "1.5 MB") whatever the app language.
    static func sizeTag(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1_000_000_000 { return String(format: "%.1f GB", b / 1_000_000_000).replacingOccurrences(of: ".0 ", with: " ") }
        if b >= 1_000_000 { return String(format: "%.1f MB", b / 1_000_000).replacingOccurrences(of: ".0 ", with: " ") }
        return String(format: "%.0f KB", max(1, b / 1_000))
    }

    /// Where results go: next to the original, or the folder chosen in Settings.
    static func folder(for input: URL) -> URL {
        AppSettings.outputFolderOverride ?? input.deletingLastPathComponent()
    }

    /// A new, non-clashing file for `input`'s result.
    static func output(for input: URL, suffix: String? = nil, ext: String, in dir: URL? = nil) -> URL {
        let folder = dir ?? folder(for: input)
        var base = input.deletingPathExtension().lastPathComponent
        if let s = suffix, !s.isEmpty { base += " " + s }
        return unique(folder: folder, name: base, ext: ext)
    }

    static func unique(folder: URL, name: String, ext: String) -> URL {
        let fm = FileManager.default
        func make(_ n: String) -> URL {
            let u = folder.appendingPathComponent(n)
            return ext.isEmpty ? u : u.appendingPathExtension(ext)
        }
        var url = make(name)
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = make("\(name) \(i)")
            i += 1
        }
        return url
    }

    /// Creates a new folder for results, e.g. "Report pages".
    static func newFolder(for input: URL, suffix: String) throws -> URL {
        let base = input.deletingPathExtension().lastPathComponent + " " + suffix
        let url = unique(folder: folder(for: input), name: base, ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Running command-line tools

enum Shell {
    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, stdoutTo: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd = cwd { p.currentDirectoryURL = cwd }
        let errPipe = Pipe()
        p.standardError = errPipe
        var outPipe: Pipe? = nil
        var outHandle: FileHandle? = nil
        if let stdoutTo = stdoutTo {
            FileManager.default.createFile(atPath: stdoutTo.path, contents: nil)
            outHandle = try FileHandle(forWritingTo: stdoutTo)
            p.standardOutput = outHandle
        } else {
            outPipe = Pipe()
            p.standardOutput = outPipe
        }
        let errBox = DataBox()
        errPipe.fileHandleForReading.readabilityHandler = { h in errBox.append(h.availableData) }
        try p.run()
        let outData = outPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        p.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        errBox.append(errPipe.fileHandleForReading.availableData)
        try? outHandle?.close()
        if p.terminationStatus != 0 {
            let msg = String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BremorphError(msg.isEmpty ? LF("%@ failed (code %d)", (tool as NSString).lastPathComponent, Int(p.terminationStatus)) : msg)
        }
        return String(decoding: outData, as: UTF8.self)
    }
}

// MARK: - Dispatcher

enum Engine {
    static func run(_ action: ActionID, inputs: [URL], options o: ActionOptions,
                    progress: @escaping ProgressHandler) async throws -> EngineResult {
        guard let input = inputs.first else { throw BremorphError("No files") }
        switch action {
        // Images
        case .imgJPEG: return one(try ImageOps.convert(input, type: .jpeg, ext: "jpg", quality: 0.92))
        case .imgPNG: return one(try ImageOps.convert(input, type: .png, ext: "png"))
        case .imgHEIC: return one(try ImageOps.convert(input, type: .heic, ext: "heic", quality: 0.85))
        case .imgWEBP: return one(try ImageOps.toWebP(input))
        case .imgAVIF: return one(try ImageOps.toAVIF(input, progress: progress))
        case .imgTIFF: return one(try ImageOps.convert(input, type: .tiff, ext: "tiff"))
        case .imgGIF: return one(try ImageOps.convert(input, type: .gif, ext: "gif"))
        case .imgBMP: return one(try ImageOps.convert(input, type: .bmp, ext: "bmp"))
        case .imgPDF:
            let out = Paths.output(for: input, ext: "pdf")
            try ImageOps.makePDF([input], output: out)
            return one(out)
        case .imgEdit: throw BremorphError("Crop & Edit opens in its own window")
        case .imgCompress: return one(try ImageOps.compress(input, quality: o.quality))
        case .imgFitSize: return try ImageOps.fitSize(input, targetBytes: o.targetBytes(for: input))
        case .imgResize: return one(try ImageOps.resize(input, maxDim: o.maxDimension))
        case .imgStripMeta: return one(try ImageOps.stripMetadata(input))
        case .imgReadQR:
            let codes = try ImageOps.readQR(input)
            if codes.isEmpty { return EngineResult(message: LF("No QR code found in %@.", input.lastPathComponent)) }
            let text = codes.joined(separator: "\n")
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return EngineResult(message: LF("QR code: %@\n(copied to clipboard)", text))
        case .imgCombinePDF:
            let out = Paths.unique(folder: Paths.folder(for: input), name: "Combined", ext: "pdf")
            try ImageOps.makePDF(inputs, output: out, progress: progress)
            return one(out)
        case .imgCollage:
            let out = Paths.unique(folder: Paths.folder(for: input), name: "Collage", ext: "jpg")
            try ImageOps.collage(inputs, columns: o.columns, output: out)
            return one(out)

        // Video
        case .vidMP4: return one(try await VideoOps.convert(input, ext: "mp4", progress: progress))
        case .vidMOV: return one(try await VideoOps.convert(input, ext: "mov", progress: progress))
        case .vidM4V: return one(try await VideoOps.convert(input, ext: "m4v", progress: progress))
        case .vidMKV: return one(try MediaFF.convertVideo(input, ext: "mkv", progress: progress))
        case .vidWEBM: return one(try MediaFF.convertVideo(input, ext: "webm", progress: progress))
        case .vidAVI: return one(try MediaFF.convertVideo(input, ext: "avi", progress: progress))
        case .vidWMV: return one(try MediaFF.convertVideo(input, ext: "wmv", progress: progress))
        case .vidGIF: return one(try await VideoOps.gif(input, start: o.start, end: o.end, fps: o.gifFPS, width: o.gifWidth, progress: progress))
        case .vidAudio: return one(try await VideoOps.extractAudio(input, progress: progress))
        case .vidMP3: return one(try MediaFF.convertAudio(input, format: .mp3, progress: progress))
        case .vidCompress: return one(try await VideoOps.compress(input, quality: o.videoQuality, progress: progress))
        case .vidFitSize: return one(try await VideoOps.fitSize(input, targetBytes: o.targetBytes(for: input), progress: progress))
        case .vidTrim: return one(try await VideoOps.trim(input, start: o.start, end: o.end, progress: progress))
        case .vidCrop: throw BremorphError("Crop Video opens in its own window")
        case .vidSplit: return one(try await VideoOps.split(input, mode: o.splitMode, value: o.splitValue, progress: progress))
        case .vidSpeed: return one(try await VideoOps.speed(input, factor: o.speed, progress: progress))
        case .vidMute: return one(try await VideoOps.mute(input, progress: progress))
        case .vidSnapshot: return one(try await VideoOps.snapshot(input, at: o.snapshotTime))
        case .vidJoin: return one(try await VideoOps.join(inputs, progress: progress))
        case .vidStripMeta: return one(try await VideoOps.stripMetadata(input, progress: progress))

        // Audio
        case .audMP3: return one(try MediaFF.convertAudio(input, format: .mp3, progress: progress))
        case .audOGG: return one(try MediaFF.convertAudio(input, format: .ogg, progress: progress))
        case .audOPUS: return one(try MediaFF.convertAudio(input, format: .opus, progress: progress))
        case .audWMA: return one(try MediaFF.convertAudio(input, format: .wma, progress: progress))
        case .audM4A: return one(try AudioOps.convert(input, spec: .aac))
        case .audALAC: return one(try AudioOps.convert(input, spec: .alac, suffix: "lossless"))
        case .audWAV: return one(try AudioOps.convert(input, spec: .wav))
        case .audAIFF: return one(try AudioOps.convert(input, spec: .aiff))
        case .audCAF: return one(try AudioOps.convert(input, spec: .caf))
        case .audFLAC: return one(try AudioOps.convert(input, spec: .flac))
        case .audTrim: return one(try await AudioOps.trim(input, start: o.start, end: o.end, progress: progress))
        case .audNormalize: return one(try AudioOps.normalize(input))
        case .audBleep: return one(try AudioOps.bleep(input, start: o.start, end: o.end))
        case .audMono: return one(try AudioOps.channels(input, count: 1))
        case .audStereo: return one(try AudioOps.channels(input, count: 2))

        // PDF
        case .pdfDOCX: return one(try await DocConvert.pdfTo(input, format: .docx))
        case .pdfPPTX: return one(try DocConvert.pdfToPPTX(input))
        case .pdfXLSX: return one(try DocConvert.pdfToXLSX(input))
        case .pdfPages: return one(try await DocConvert.pdfTo(input, format: .pages))
        case .pdfEPUB: return one(try await DocConvert.pdfTo(input, format: .epub))
        case .pdfMD: return one(try await DocConvert.pdfTo(input, format: .markdown))
        case .pdfPNG: return EngineResult(outputs: [try PDFOps.toImages(input, jpeg: false, progress: progress)])
        case .pdfJPEG: return EngineResult(outputs: [try PDFOps.toImages(input, jpeg: true, progress: progress)])
        case .pdfText: return one(try PDFOps.toText(input))
        case .pdfOrganize: throw BremorphError("Organize Pages opens in its own window")
        case .pdfMerge: return one(try PDFOps.merge(inputs))
        case .pdfSplit: return one(try PDFOps.split(input, progress: progress))
        case .pdfExtract: return one(try PDFOps.extract(input, range: o.pageRange))
        case .pdfCompress: return try PDFOps.compress(input, strong: o.pdfStrong, quality: o.quality, progress: progress)
        case .pdfFitSize: return try PDFOps.fitSize(input, targetBytes: o.targetBytes(for: input), progress: progress)
        case .pdfRotate: return one(try PDFOps.rotate(input, degrees: o.rotation))
        case .pdfStripMeta: return one(try PDFOps.stripMetadata(input))

        // Documents
        case .docPDF: return one(try await DocConvert.document(input, to: .pdf))
        case .docDOCX: return one(try await DocConvert.document(input, to: .docx))
        case .docPages: return one(try await DocConvert.document(input, to: .pages))
        case .docMD: return one(try await DocConvert.document(input, to: .markdown))
        case .docEPUB: return one(try await DocConvert.document(input, to: .epub))
        case .docRTF: return one(try await DocConvert.document(input, to: .rtf))
        case .docTXT: return one(try await DocConvert.document(input, to: .txt))
        case .docHTML: return one(try await DocConvert.document(input, to: .html))
        case .docODT: return one(try await DocConvert.document(input, to: .odt))

        // Slides
        case .slPDF: return one(try DocConvert.slides(input, to: "pdf"))
        case .slPPTX: return one(try DocConvert.slides(input, to: "pptx"))
        case .slPNG: return one(try DocConvert.slidesToImages(input, jpeg: false, progress: progress))
        case .slJPEG: return one(try DocConvert.slidesToImages(input, jpeg: true, progress: progress))

        // Spreadsheets
        case .shXLSX: return one(try DocConvert.sheet(input, to: "xlsx"))
        case .shODS: return one(try DocConvert.sheet(input, to: "ods"))
        case .shCSV: return one(try DocConvert.sheet(input, to: "csv"))
        case .shTSV: return one(try DocConvert.sheet(input, to: "tsv"))
        case .shPDF: return one(try DocConvert.sheet(input, to: "pdf"))

        // Subtitles
        case .subSRT: return one(try DocOps.vttToSrt(input))
        case .subVTT: return one(try DocOps.srtToVtt(input))
        case .subTXT: return one(try DocOps.subtitleToText(input))

        // Archives
        case .arcExtract: return one(try DocOps.extract(input))
        case .anyZIP: return one(try DocOps.zip(inputs))
        case .anyTarGz: return one(try DocOps.tarGz(inputs))

        // Info
        case .editMeta: throw BremorphError("Edit Metadata opens in its own window")
        case .showInfo: return EngineResult(message: try await InfoOps.describe(input))
        }
    }

    private static func one(_ url: URL) -> EngineResult { EngineResult(outputs: [url]) }
}
