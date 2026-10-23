import Foundation
import AVFoundation
import UniformTypeIdentifiers

// MARK: - File kinds

enum FileKind: String, CaseIterable, Identifiable {
    case image, video, audio, pdf, document, slides, spreadsheet, subtitle, archive, folder, other

    var id: String { rawValue }

    var title: String { L(englishTitle) }

    var englishTitle: String {
        switch self {
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Documents"
        case .slides: return "Slides"
        case .spreadsheet: return "Spreadsheets"
        case .subtitle: return "Subtitles"
        case .archive: return "Archives"
        case .folder: return "Folders"
        case .other: return "Other files"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .slides: return "rectangle.on.rectangle.angled"
        case .spreadsheet: return "tablecells"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        case .folder: return "folder"
        case .other: return "doc"
        }
    }

    static let documentExts: Set<String> = ["txt", "text", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive",
                                            "wordml", "md", "markdown", "epub", "pages", "textclipping"]
    static let slideExts: Set<String> = ["ppt", "pptx", "pps", "ppsx", "odp", "key"]
    static let sheetExts: Set<String> = ["xls", "xlsx", "ods", "csv", "tsv", "numbers"]
    static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "rar", "7z"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "mts", "m2ts", "3gp", "ogv", "vob"]
    static let audioExts: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "caf", "flac", "ogg", "oga", "opus", "wma", "aac", "m4b", "amr", "ac3"]
    static let packageExts: Set<String> = ["rtfd", "pages", "key", "numbers"]

    static func detect(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, !packageExts.contains(ext) {
            return .folder
        }
        if ext == "srt" || ext == "vtt" { return .subtitle }
        if archiveExts.contains(ext) { return .archive }
        if documentExts.contains(ext) { return .document }
        if slideExts.contains(ext) { return .slides }
        if sheetExts.contains(ext) { return .spreadsheet }
        if ext == "pdf" { return .pdf }
        if videoExts.contains(ext) { return .video }
        if audioExts.contains(ext) { return .audio }
        if let t = UTType(filenameExtension: ext) {
            if t.conforms(to: .image) { return .image }
            if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
            if t.conforms(to: .audio) { return .audio }
        }
        return .other
    }
}

// MARK: - Options

enum ActionGroup: String {
    case convert = "Convert to"
    case tools = "Tools"
    var title: String { L(rawValue) }
}

enum OptionField: Hashable {
    case quality, maxDimension, trim, speed, sizeTarget, snapshotTime, pageRange, rotation, videoQuality, gif, collage,
         pdfStrength, split
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case high, medium, small, hevc
    var id: String { rawValue }
    var title: String { L(englishTitle) }
    var englishTitle: String {
        switch self {
        case .high: return "High (1080p)"
        case .medium: return "Medium (720p)"
        case .small: return "Small (540p)"
        case .hevc: return "Efficient HEVC (1080p)"
        }
    }
    var preset: String {
        switch self {
        case .high: return AVAssetExportPreset1920x1080
        case .medium: return AVAssetExportPreset1280x720
        case .small: return AVAssetExportPreset960x540
        case .hevc: return AVAssetExportPresetHEVC1920x1080
        }
    }
    var longSide: Int {
        switch self {
        case .high, .hevc: return 1920
        case .medium: return 1280
        case .small: return 960
        }
    }
}

enum SplitMode: String, CaseIterable, Identifiable {
    case parts, seconds
    var id: String { rawValue }
}

struct ActionOptions {
    var quality: Double = 0.7
    var maxDimension: Int = 1920
    var start: Double = 0
    var end: Double = 10
    var speed: Double = 2.0
    var sizeByPercent = true
    var sizePercent: Double = 50
    var targetMB: Double = 10
    var snapshotTime: Double = 0
    var pageRange: String = "1"
    var rotation: Int = 90
    var videoQuality: VideoQuality = .medium
    var gifFPS: Int = 12
    var gifWidth: Int = 480
    var columns: Int = 2
    var pdfStrong: Bool = false
    var splitMode: SplitMode = .parts
    var splitValue: Double = 2

    /// Byte target for "Fit to Size" tools.
    func targetBytes(for url: URL) -> Int64 {
        if sizeByPercent {
            let original = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return Int64(Double(original) * max(1, min(99, sizePercent)) / 100)
        }
        return Int64(max(0.01, targetMB) * 1_000_000)
    }
}

// MARK: - Actions

enum Requirement {
    case none, ffmpeg, office, pages, keynote, numbers, webpEncoder
}

struct ActionInfo {
    let title: String
    let symbol: String
    let group: ActionGroup
    let kinds: [FileKind]
    var combines = false
    var minFiles = 1
    var fields: [OptionField] = []
    var universal = false
    var needs: Requirement = .none
    var opensWindow = false

    init(title: String, symbol: String, group: ActionGroup, kinds: [FileKind], combines: Bool = false, minFiles: Int = 1,
         fields: [OptionField] = [], universal: Bool = false, needs: Requirement = .none, opensWindow: Bool = false) {
        self.title = L(title)
        self.symbol = symbol
        self.group = group
        self.kinds = kinds
        self.combines = combines
        self.minFiles = minFiles
        self.fields = fields
        self.universal = universal
        self.needs = needs
        self.opensWindow = opensWindow
    }
}

enum ActionID: String, CaseIterable, Identifiable {
    // Images
    case imgJPEG, imgPNG, imgHEIC, imgWEBP, imgAVIF, imgTIFF, imgGIF, imgBMP, imgPDF
    case imgEdit, imgCompress, imgFitSize, imgResize, imgStripMeta, imgReadQR, imgCombinePDF, imgCollage
    // Video
    case vidMP4, vidMOV, vidM4V, vidMKV, vidWEBM, vidAVI, vidWMV, vidGIF, vidAudio, vidMP3
    case vidCompress, vidFitSize, vidTrim, vidCrop, vidSplit, vidSpeed, vidMute, vidSnapshot, vidJoin, vidStripMeta
    // Audio
    case audMP3, audM4A, audALAC, audWAV, audAIFF, audCAF, audFLAC, audOGG, audOPUS, audWMA
    case audTrim, audNormalize, audBleep, audMono, audStereo
    // PDF
    case pdfDOCX, pdfPPTX, pdfXLSX, pdfPages, pdfEPUB, pdfMD, pdfPNG, pdfJPEG, pdfText
    case pdfOrganize, pdfMerge, pdfSplit, pdfExtract, pdfCompress, pdfFitSize, pdfRotate, pdfStripMeta
    // Documents
    case docPDF, docDOCX, docPages, docMD, docEPUB, docRTF, docTXT, docHTML, docODT
    // Slides
    case slPDF, slPPTX, slPNG, slJPEG
    // Spreadsheets
    case shXLSX, shODS, shCSV, shTSV, shPDF
    // Subtitles
    case subSRT, subVTT, subTXT
    // Archives
    case arcExtract
    // Shared
    case editMeta, showInfo
    case anyZIP, anyTarGz

    var id: String { rawValue }

    var info: ActionInfo {
        let conv = "arrow.triangle.2.circlepath"
        switch self {
        // Images
        case .imgJPEG: return ActionInfo(title: "JPEG", symbol: conv, group: .convert, kinds: [.image])
        case .imgPNG: return ActionInfo(title: "PNG", symbol: conv, group: .convert, kinds: [.image])
        case .imgHEIC: return ActionInfo(title: "HEIC", symbol: conv, group: .convert, kinds: [.image])
        case .imgWEBP: return ActionInfo(title: "WebP", symbol: conv, group: .convert, kinds: [.image], needs: .webpEncoder)
        case .imgAVIF: return ActionInfo(title: "AVIF", symbol: conv, group: .convert, kinds: [.image])
        case .imgTIFF: return ActionInfo(title: "TIFF", symbol: conv, group: .convert, kinds: [.image])
        case .imgGIF: return ActionInfo(title: "GIF", symbol: conv, group: .convert, kinds: [.image])
        case .imgBMP: return ActionInfo(title: "BMP", symbol: conv, group: .convert, kinds: [.image])
        case .imgPDF: return ActionInfo(title: "PDF", symbol: conv, group: .convert, kinds: [.image])
        case .imgEdit: return ActionInfo(title: "Crop & Edit", symbol: "crop", group: .tools, kinds: [.image], opensWindow: true)
        case .imgCompress: return ActionInfo(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", group: .tools, kinds: [.image], fields: [.quality])
        case .imgFitSize: return ActionInfo(title: "Fit to Size", symbol: "scalemass", group: .tools, kinds: [.image], fields: [.sizeTarget])
        case .imgResize: return ActionInfo(title: "Resize", symbol: "arrow.up.left.and.arrow.down.right", group: .tools, kinds: [.image], fields: [.maxDimension])
        case .imgStripMeta: return ActionInfo(title: "Remove Metadata", symbol: "eye.slash", group: .tools, kinds: [.image])
        case .imgReadQR: return ActionInfo(title: "Read QR Code", symbol: "qrcode.viewfinder", group: .tools, kinds: [.image])
        case .imgCombinePDF: return ActionInfo(title: "Combine into PDF", symbol: "doc.on.doc", group: .tools, kinds: [.image], combines: true)
        case .imgCollage: return ActionInfo(title: "Collage", symbol: "square.grid.2x2", group: .tools, kinds: [.image], combines: true, minFiles: 2, fields: [.collage])
        // Video
        case .vidMP4: return ActionInfo(title: "MP4", symbol: conv, group: .convert, kinds: [.video])
        case .vidMOV: return ActionInfo(title: "MOV", symbol: conv, group: .convert, kinds: [.video])
        case .vidM4V: return ActionInfo(title: "M4V", symbol: conv, group: .convert, kinds: [.video])
        case .vidMKV: return ActionInfo(title: "MKV", symbol: conv, group: .convert, kinds: [.video], needs: .ffmpeg)
        case .vidWEBM: return ActionInfo(title: "WebM", symbol: conv, group: .convert, kinds: [.video], needs: .ffmpeg)
        case .vidAVI: return ActionInfo(title: "AVI", symbol: conv, group: .convert, kinds: [.video], needs: .ffmpeg)
        case .vidWMV: return ActionInfo(title: "WMV", symbol: conv, group: .convert, kinds: [.video], needs: .ffmpeg)
        case .vidGIF: return ActionInfo(title: "Animated GIF", symbol: conv, group: .convert, kinds: [.video], fields: [.gif])
        case .vidAudio: return ActionInfo(title: "Audio (M4A)", symbol: "waveform", group: .convert, kinds: [.video])
        case .vidMP3: return ActionInfo(title: "MP3", symbol: "waveform", group: .convert, kinds: [.video], needs: .ffmpeg)
        case .vidCompress: return ActionInfo(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", group: .tools, kinds: [.video], fields: [.videoQuality])
        case .vidFitSize: return ActionInfo(title: "Fit to Size", symbol: "scalemass", group: .tools, kinds: [.video], fields: [.sizeTarget])
        case .vidTrim: return ActionInfo(title: "Trim", symbol: "scissors", group: .tools, kinds: [.video], fields: [.trim])
        case .vidCrop: return ActionInfo(title: "Crop Video", symbol: "crop", group: .tools, kinds: [.video], needs: .ffmpeg, opensWindow: true)
        case .vidSplit: return ActionInfo(title: "Split", symbol: "square.split.2x1", group: .tools, kinds: [.video], fields: [.split])
        case .vidSpeed: return ActionInfo(title: "Change Speed", symbol: "hare", group: .tools, kinds: [.video], fields: [.speed])
        case .vidMute: return ActionInfo(title: "Remove Audio", symbol: "speaker.slash", group: .tools, kinds: [.video])
        case .vidSnapshot: return ActionInfo(title: "Snapshot", symbol: "camera", group: .tools, kinds: [.video], fields: [.snapshotTime])
        case .vidJoin: return ActionInfo(title: "Join Videos", symbol: "film.stack", group: .tools, kinds: [.video], combines: true, minFiles: 2)
        case .vidStripMeta: return ActionInfo(title: "Remove Metadata", symbol: "eye.slash", group: .tools, kinds: [.video])
        // Audio
        case .audMP3: return ActionInfo(title: "MP3", symbol: conv, group: .convert, kinds: [.audio], needs: .ffmpeg)
        case .audM4A: return ActionInfo(title: "M4A (AAC)", symbol: conv, group: .convert, kinds: [.audio])
        case .audALAC: return ActionInfo(title: "M4A Lossless", symbol: conv, group: .convert, kinds: [.audio])
        case .audWAV: return ActionInfo(title: "WAV", symbol: conv, group: .convert, kinds: [.audio])
        case .audAIFF: return ActionInfo(title: "AIFF", symbol: conv, group: .convert, kinds: [.audio])
        case .audCAF: return ActionInfo(title: "CAF", symbol: conv, group: .convert, kinds: [.audio])
        case .audFLAC: return ActionInfo(title: "FLAC", symbol: conv, group: .convert, kinds: [.audio])
        case .audOGG: return ActionInfo(title: "OGG", symbol: conv, group: .convert, kinds: [.audio], needs: .ffmpeg)
        case .audOPUS: return ActionInfo(title: "Opus", symbol: conv, group: .convert, kinds: [.audio], needs: .ffmpeg)
        case .audWMA: return ActionInfo(title: "WMA", symbol: conv, group: .convert, kinds: [.audio], needs: .ffmpeg)
        case .audTrim: return ActionInfo(title: "Trim", symbol: "scissors", group: .tools, kinds: [.audio], fields: [.trim])
        case .audNormalize: return ActionInfo(title: "Normalize Volume", symbol: "speaker.wave.3", group: .tools, kinds: [.audio])
        case .audBleep: return ActionInfo(title: "Bleep", symbol: "exclamationmark.bubble", group: .tools, kinds: [.audio], fields: [.trim])
        case .audMono: return ActionInfo(title: "Make Mono", symbol: "speaker", group: .tools, kinds: [.audio])
        case .audStereo: return ActionInfo(title: "Make Stereo", symbol: "speaker.wave.2", group: .tools, kinds: [.audio])
        // PDF
        case .pdfDOCX: return ActionInfo(title: "Word (DOCX)", symbol: conv, group: .convert, kinds: [.pdf])
        case .pdfPPTX: return ActionInfo(title: "PowerPoint", symbol: conv, group: .convert, kinds: [.pdf], needs: .office)
        case .pdfXLSX: return ActionInfo(title: "Excel (XLSX)", symbol: conv, group: .convert, kinds: [.pdf], needs: .office)
        case .pdfPages: return ActionInfo(title: "Pages", symbol: conv, group: .convert, kinds: [.pdf], needs: .pages)
        case .pdfEPUB: return ActionInfo(title: "EPUB", symbol: conv, group: .convert, kinds: [.pdf])
        case .pdfMD: return ActionInfo(title: "Markdown", symbol: conv, group: .convert, kinds: [.pdf])
        case .pdfPNG: return ActionInfo(title: "PNG Images", symbol: conv, group: .convert, kinds: [.pdf])
        case .pdfJPEG: return ActionInfo(title: "JPEG Images", symbol: conv, group: .convert, kinds: [.pdf])
        case .pdfText: return ActionInfo(title: "Plain Text", symbol: conv, group: .convert, kinds: [.pdf])
        case .pdfOrganize: return ActionInfo(title: "Organize Pages", symbol: "square.grid.3x3", group: .tools, kinds: [.pdf], opensWindow: true)
        case .pdfMerge: return ActionInfo(title: "Merge PDFs", symbol: "doc.on.doc", group: .tools, kinds: [.pdf], combines: true, minFiles: 2)
        case .pdfSplit: return ActionInfo(title: "Split Pages", symbol: "rectangle.split.3x1", group: .tools, kinds: [.pdf])
        case .pdfExtract: return ActionInfo(title: "Extract Pages", symbol: "doc.text.magnifyingglass", group: .tools, kinds: [.pdf], fields: [.pageRange])
        case .pdfCompress: return ActionInfo(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", group: .tools, kinds: [.pdf], fields: [.pdfStrength])
        case .pdfFitSize: return ActionInfo(title: "Fit to Size", symbol: "scalemass", group: .tools, kinds: [.pdf], fields: [.sizeTarget])
        case .pdfRotate: return ActionInfo(title: "Rotate Pages", symbol: "rotate.right", group: .tools, kinds: [.pdf], fields: [.rotation])
        case .pdfStripMeta: return ActionInfo(title: "Remove Metadata", symbol: "eye.slash", group: .tools, kinds: [.pdf])
        // Documents
        case .docPDF: return ActionInfo(title: "PDF", symbol: conv, group: .convert, kinds: [.document])
        case .docDOCX: return ActionInfo(title: "Word (DOCX)", symbol: conv, group: .convert, kinds: [.document])
        case .docPages: return ActionInfo(title: "Pages", symbol: conv, group: .convert, kinds: [.document], needs: .pages)
        case .docMD: return ActionInfo(title: "Markdown", symbol: conv, group: .convert, kinds: [.document])
        case .docEPUB: return ActionInfo(title: "EPUB", symbol: conv, group: .convert, kinds: [.document])
        case .docRTF: return ActionInfo(title: "RTF", symbol: conv, group: .convert, kinds: [.document])
        case .docTXT: return ActionInfo(title: "Plain Text", symbol: conv, group: .convert, kinds: [.document])
        case .docHTML: return ActionInfo(title: "HTML", symbol: conv, group: .convert, kinds: [.document])
        case .docODT: return ActionInfo(title: "ODT", symbol: conv, group: .convert, kinds: [.document])
        // Slides
        case .slPDF: return ActionInfo(title: "PDF", symbol: conv, group: .convert, kinds: [.slides], needs: .office)
        case .slPPTX: return ActionInfo(title: "PowerPoint", symbol: conv, group: .convert, kinds: [.slides], needs: .office)
        case .slPNG: return ActionInfo(title: "PNG Images", symbol: conv, group: .convert, kinds: [.slides], needs: .office)
        case .slJPEG: return ActionInfo(title: "JPEG Images", symbol: conv, group: .convert, kinds: [.slides], needs: .office)
        // Spreadsheets
        case .shXLSX: return ActionInfo(title: "Excel (XLSX)", symbol: conv, group: .convert, kinds: [.spreadsheet], needs: .office)
        case .shODS: return ActionInfo(title: "ODS", symbol: conv, group: .convert, kinds: [.spreadsheet], needs: .office)
        case .shCSV: return ActionInfo(title: "CSV", symbol: conv, group: .convert, kinds: [.spreadsheet], needs: .office)
        case .shTSV: return ActionInfo(title: "TSV", symbol: conv, group: .convert, kinds: [.spreadsheet], needs: .office)
        case .shPDF: return ActionInfo(title: "PDF", symbol: conv, group: .convert, kinds: [.spreadsheet], needs: .office)
        // Subtitles
        case .subSRT: return ActionInfo(title: "SRT", symbol: conv, group: .convert, kinds: [.subtitle])
        case .subVTT: return ActionInfo(title: "WebVTT", symbol: conv, group: .convert, kinds: [.subtitle])
        case .subTXT: return ActionInfo(title: "Plain Text", symbol: conv, group: .convert, kinds: [.subtitle])
        // Archives
        case .arcExtract: return ActionInfo(title: "Extract", symbol: "archivebox", group: .tools, kinds: [.archive])
        // Shared
        case .editMeta: return ActionInfo(title: "Edit Metadata", symbol: "tag", group: .tools, kinds: [.image, .video, .audio, .pdf], opensWindow: true)
        case .showInfo: return ActionInfo(title: "Show Info", symbol: "info.circle", group: .tools, kinds: [.image, .video, .audio, .pdf])
        case .anyZIP: return ActionInfo(title: "ZIP Archive", symbol: "doc.zipper", group: .tools, kinds: [], combines: true, universal: true)
        case .anyTarGz: return ActionInfo(title: "TAR.GZ Archive", symbol: "shippingbox", group: .tools, kinds: [], combines: true, universal: true)
        }
    }

    /// Whether the helper this action needs is installed.
    var isAvailable: Bool {
        switch info.needs {
        case .none: return true
        case .ffmpeg: return Helpers.ffmpeg != nil
        case .office: return Helpers.soffice != nil
        case .pages: return Helpers.hasPages
        case .keynote: return Helpers.hasKeynote
        case .numbers: return Helpers.hasNumbers
        case .webpEncoder: return ImageOps.writable.contains(UTType.webP.identifier) || Helpers.cwebp != nil
        }
    }

    var missingHelpText: String {
        switch info.needs {
        case .ffmpeg: return L("Needs ffmpeg. Install it with: brew install ffmpeg")
        case .office: return L("Needs LibreOffice. Install it with: brew install --cask libreoffice")
        case .pages: return L("Needs Apple's Pages app")
        case .keynote: return L("Needs Apple's Keynote app")
        case .numbers: return L("Needs Apple's Numbers app")
        case .webpEncoder: return L("Needs the WebP encoder. Install it with: brew install webp")
        case .none: return ""
        }
    }

    /// Whether this action applies to a given file.
    func accepts(_ url: URL) -> Bool {
        if info.universal { return true }
        let kind = FileKind.detect(url)
        guard info.kinds.contains(kind) else { return false }
        let ext = url.pathExtension.lowercased()
        switch self {
        case .subSRT: return ext != "srt"
        case .subVTT: return ext != "vtt"
        case .slPPTX: return ext != "pptx"
        case .shXLSX: return ext != "xlsx"
        case .shODS: return ext != "ods"
        case .shCSV: return ext != "csv"
        case .shTSV: return ext != "tsv"
        case .docPages: return ext != "pages"
        case .docMD: return ext != "md" && ext != "markdown"
        case .docEPUB: return ext != "epub"
        case .audMP3: return ext != "mp3"
        case .audOGG: return ext != "ogg" && ext != "oga"
        case .audOPUS: return ext != "opus"
        case .audWMA: return ext != "wma"
        case .vidMKV: return ext != "mkv"
        case .vidWEBM: return ext != "webm"
        case .vidAVI: return ext != "avi"
        case .vidWMV: return ext != "wmv"
        default: return true
        }
    }

    static func actions(for kind: FileKind, group: ActionGroup) -> [ActionID] {
        allCases.filter { !$0.info.universal && $0.info.group == group && $0.info.kinds.contains(kind) }
    }

    static var universalActions: [ActionID] { allCases.filter { $0.info.universal } }
}
