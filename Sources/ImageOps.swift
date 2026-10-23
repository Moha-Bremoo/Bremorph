import Foundation
import AppKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers

enum ImageOps {
    static let writable: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    // MARK: Loading

    /// Loads frame `index` with EXIF orientation applied, optionally downscaled.
    static func orientedImage(_ src: CGImageSource, index: Int, maxDim: Int?) throws -> CGImage {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        var size = max(w, h)
        if let m = maxDim, m > 0 { size = size > 0 ? min(size, m) : m }
        if size <= 0 { size = 8192 }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) else {
            throw BremorphError("Couldn't read this image")
        }
        return img
    }

    /// Loads any image file (falls back to NSImage for formats like SVG).
    static func loadImage(_ url: URL, maxDim: Int? = nil) throws -> CGImage {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
           let img = try? orientedImage(src, index: 0, maxDim: maxDim) {
            return img
        }
        if let ns = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: ns.size)
            if let m = maxDim, max(rect.width, rect.height) > CGFloat(m) {
                let s = CGFloat(m) / max(rect.width, rect.height)
                rect.size = CGSize(width: rect.width * s, height: rect.height * s)
            }
            if let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return cg }
        }
        throw BremorphError(LF("Couldn't read %@ as an image", url.lastPathComponent))
    }

    /// Draws the image onto white (for formats without transparency).
    static func flatten(_ img: CGImage) -> CGImage {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    // MARK: Converting

    static func convert(_ input: URL, type: UTType, ext: String, quality: Double? = nil, maxDim: Int? = nil,
                        stripMeta: Bool = false, suffix: String? = nil) throws -> URL {
        guard writable.contains(type.identifier) else { throw BremorphError(LF("This Mac can't write %@ images", ext.uppercased())) }
        let out = Paths.output(for: input, suffix: suffix, ext: ext)
        let flattenNeeded = (type == .jpeg || type == .bmp)

        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            // Fallback path (e.g. SVG): no metadata to carry over.
            var img = try loadImage(input, maxDim: maxDim)
            if flattenNeeded { img = flatten(img) }
            try write(img, to: out, type: type, quality: quality)
            return out
        }

        let srcType = CGImageSourceGetType(src) as String?
        let animated = type == .gif && srcType == UTType.gif.identifier
        let count = animated ? CGImageSourceGetCount(src) : 1
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, count, nil) else {
            throw BremorphError(LF("Couldn't create %@", out.lastPathComponent))
        }
        if type == .gif {
            let gifProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
            CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
        }
        for i in 0..<count {
            var img = try orientedImage(src, index: i, maxDim: maxDim)
            if flattenNeeded { img = flatten(img) }
            var p: [CFString: Any] = [:]
            let sp = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
            if !stripMeta {
                for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                            kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                    if let v = sp[key] { p[key] = v }
                }
                if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    p[kCGImagePropertyTIFFDictionary] = tiff
                }
            }
            if animated, let g = sp[kCGImagePropertyGIFDictionary] { p[kCGImagePropertyGIFDictionary] = g }
            p[kCGImagePropertyOrientation] = 1
            if let q = quality { p[kCGImageDestinationLossyCompressionQuality] = q }
            CGImageDestinationAddImage(dest, img, p as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw BremorphError(LF("Couldn't save %@", out.lastPathComponent)) }
        return out
    }

    static func write(_ img: CGImage, to out: URL, type: UTType, quality: Double? = nil) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw BremorphError(LF("Couldn't create %@", out.lastPathComponent))
        }
        var p: [CFString: Any] = [:]
        if let q = quality { p[kCGImageDestinationLossyCompressionQuality] = q }
        CGImageDestinationAddImage(dest, img, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw BremorphError(LF("Couldn't save %@", out.lastPathComponent)) }
    }

    static func sameFormat(_ input: URL) -> (UTType, String) {
        let ext = input.pathExtension.lowercased()
        if let t = UTType(filenameExtension: ext), writable.contains(t.identifier) { return (t, ext) }
        return (.png, "png")
    }

    static func compress(_ input: URL, quality: Double) throws -> URL {
        let ext = input.pathExtension.lowercased()
        if ext == "heic" || ext == "heif" {
            return try convert(input, type: .heic, ext: ext, quality: quality, suffix: "compressed")
        }
        return try convert(input, type: .jpeg, ext: "jpg", quality: quality, suffix: "compressed")
    }

    static func resize(_ input: URL, maxDim: Int) throws -> URL {
        let (type, ext) = sameFormat(input)
        return try convert(input, type: type, ext: ext, quality: 0.9, maxDim: maxDim, suffix: "\(maxDim)px")
    }

    static func stripMetadata(_ input: URL) throws -> URL {
        let (type, ext) = sameFormat(input)
        return try convert(input, type: type, ext: ext, quality: 0.95, stripMeta: true, suffix: "clean")
    }

    // MARK: PDF & collage

    static func makePDF(_ inputs: [URL], output: URL, progress: ProgressHandler? = nil) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(output as CFURL, mediaBox: &box, nil) else { throw BremorphError("Couldn't create PDF") }
        for (i, url) in inputs.enumerated() {
            let img = try loadImage(url)
            let w = CGFloat(img.width), h = CGFloat(img.height)
            let scale = min(1, 842 / max(w, h)) // page long side ≈ A4, image stays full resolution
            var page = CGRect(x: 0, y: 0, width: w * scale, height: h * scale)
            ctx.beginPage(mediaBox: &page)
            ctx.draw(img, in: page)
            ctx.endPage()
            progress?(Double(i + 1) / Double(inputs.count))
        }
        ctx.closePDF()
    }

    static func collage(_ inputs: [URL], columns: Int, output: URL) throws {
        let cols = max(1, min(columns, inputs.count))
        let rows = Int(ceil(Double(inputs.count) / Double(cols)))
        let cell = 900, pad = 24
        let W = cols * cell + (cols + 1) * pad
        let H = rows * cell + (rows + 1) * pad
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw BremorphError("Out of memory") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .high
        for (i, url) in inputs.enumerated() {
            let img = try loadImage(url, maxDim: cell * 2)
            let col = i % cols, row = i / cols
            let x = pad + col * (cell + pad)
            let y = H - (row + 1) * (cell + pad) // flip so first image is top-left
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let s = min(CGFloat(cell) / iw, CGFloat(cell) / ih)
            let dw = iw * s, dh = ih * s
            let r = CGRect(x: CGFloat(x) + (CGFloat(cell) - dw) / 2, y: CGFloat(y) + (CGFloat(cell) - dh) / 2, width: dw, height: dh)
            ctx.draw(img, in: r)
        }
        guard let result = ctx.makeImage() else { throw BremorphError("Couldn't build collage") }
        try write(result, to: output, type: .jpeg, quality: 0.9)
    }

    // MARK: QR

    static func readQR(_ input: URL) throws -> [String] {
        let cg = try loadImage(input, maxDim: 3000)
        let ci = CIImage(cgImage: cg)
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: ci) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    // MARK: WebP / AVIF (built in when macOS can write them, otherwise via helpers)

    static func toWebP(_ input: URL) throws -> URL {
        if writable.contains(UTType.webP.identifier) {
            return try convert(input, type: .webP, ext: "webp", quality: 0.85)
        }
        guard let cwebp = Helpers.cwebp else { throw BremorphError("Saving WebP needs the encoder. Install it with: brew install webp") }
        let tmp = try Helpers.tempDir().appendingPathComponent("in.png")
        try write(try loadImage(input), to: tmp, type: .png)
        let out = Paths.output(for: input, ext: "webp")
        try Shell.run(cwebp, ["-quiet", "-q", "85", "-metadata", "icc", tmp.path, "-o", out.path])
        return out
    }

    static func toAVIF(_ input: URL, progress: ProgressHandler? = nil) throws -> URL {
        let avif = "public.avif"
        if writable.contains(avif), let t = UTType(avif) {
            return try convert(input, type: t, ext: "avif", quality: 0.8)
        }
        guard Helpers.ffmpeg != nil else { throw BremorphError("Saving AVIF needs ffmpeg. Install it with: brew install ffmpeg") }
        let tmp = try Helpers.tempDir().appendingPathComponent("in.png")
        try write(flatten(try loadImage(input)), to: tmp, type: .png)
        let out = Paths.output(for: input, ext: "avif")
        try FF.run(["-i", tmp.path, "-vf", FF.evenScale + ",format=yuv420p", "-c:v", "libsvtav1", "-crf", "30",
                    "-still-picture", "1", "-frames:v", "1", out.path])
        return out
    }

    // MARK: Fit to size (exact target or percentage)

    static func encode(_ img: CGImage, type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func fitSize(_ input: URL, targetBytes: Int64) throws -> EngineResult {
        let ext = input.pathExtension.lowercased()
        let useHEIC = (ext == "heic" || ext == "heif")
        let type: UTType = useHEIC ? .heic : .jpeg
        var img = flatten(try loadImage(input))
        var best: Data? = nil
        for _ in 0..<8 {
            // Binary search the quality for this resolution.
            var lo = 0.05, hi = 0.95
            var found: Data? = nil
            for _ in 0..<7 {
                let q = (lo + hi) / 2
                guard let d = encode(img, type: type, quality: q) else { break }
                if Int64(d.count) <= targetBytes { found = d; lo = q } else { hi = q }
            }
            if let f = found { best = f; break }
            // Still too big at the lowest quality: shrink the picture and try again.
            let w = Int(Double(img.width) * 0.8), h = Int(Double(img.height) * 0.8)
            guard w > 32, h > 32, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { break }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let smaller = ctx.makeImage() else { break }
            img = smaller
        }
        guard let data = best else { throw BremorphError("Couldn't get the image that small") }
        let out = Paths.output(for: input, suffix: Paths.sizeTag(targetBytes), ext: useHEIC ? ext : "jpg")
        try data.write(to: out)
        let before = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int64) ?? 0
        let f = ByteCountFormatter()
        return EngineResult(outputs: [out], message: ltr("\(f.string(fromByteCount: before)) → \(f.string(fromByteCount: Int64(data.count))) (\(img.width)×\(img.height) px)"))
    }
}
