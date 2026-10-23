import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ s: AVAssetExportSession) { session = s }
}

enum VideoOps {
    static func fileType(for ext: String) -> AVFileType {
        switch ext.lowercased() {
        case "mp4": return .mp4
        case "m4v": return .m4v
        case "m4a": return .m4a
        default: return .mov
        }
    }

    static func outExt(for input: URL) -> String {
        let e = input.pathExtension.lowercased()
        return (e == "mp4" || e == "m4v") ? e : "mov"
    }

    static func seconds(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 600) }

    // MARK: Export helper

    static func export(_ asset: AVAsset, preset: String, to out: URL, type: AVFileType,
                       progress: @escaping ProgressHandler,
                       configure: (AVAssetExportSession) -> Void = { _ in }) async throws {
        try? FileManager.default.removeItem(at: out)
        guard let s = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw BremorphError("This video can't be exported with that setting")
        }
        guard s.supportedFileTypes.contains(type) else {
            throw BremorphError("That output format isn't supported for this video")
        }
        s.outputURL = out
        s.outputFileType = type
        s.shouldOptimizeForNetworkUse = true
        configure(s)
        let box = SessionBox(s)
        let poller = Task.detached {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            s.exportAsynchronously { c.resume() }
        }
        poller.cancel()
        if s.status != .completed {
            try? FileManager.default.removeItem(at: out)
            throw BremorphError(s.error?.localizedDescription ?? "Export failed")
        }
        progress(1)
    }

    /// Tries a fast lossless remux first, then a full re-encode.
    static func exportBest(_ asset: AVAsset, to out: URL, type: AVFileType, progress: @escaping ProgressHandler,
                           configure: @escaping (AVAssetExportSession) -> Void = { _ in }) async throws {
        do {
            try await export(asset, preset: AVAssetExportPresetPassthrough, to: out, type: type, progress: progress, configure: configure)
        } catch {
            try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, type: type, progress: progress, configure: configure)
        }
    }

    // MARK: Actions

    static func convert(_ input: URL, ext: String, progress: @escaping ProgressHandler) async throws -> URL {
        if !(await MediaFF.isNativeVideo(input)) { return try MediaFF.convertVideo(input, ext: ext, progress: progress) }
        let asset = AVURLAsset(url: input)
        let out = Paths.output(for: input, suffix: input.pathExtension.lowercased() == ext ? "converted" : nil, ext: ext)
        try await exportBest(asset, to: out, type: fileType(for: ext), progress: progress)
        return out
    }

    static func compress(_ input: URL, quality: VideoQuality, progress: @escaping ProgressHandler) async throws -> URL {
        if !(await MediaFF.isNativeVideo(input)) { return try MediaFF.compress(input, quality: quality, progress: progress) }
        let asset = AVURLAsset(url: input)
        let out = Paths.output(for: input, suffix: "compressed", ext: "mp4")
        try await export(asset, preset: quality.preset, to: out, type: .mp4, progress: progress)
        return out
    }

    static func trim(_ input: URL, start: Double, end: Double, progress: @escaping ProgressHandler) async throws -> URL {
        guard end > start else { throw BremorphError("End time must be after start time") }
        if !(await MediaFF.isNativeVideo(input)) { return try MediaFF.trim(input, start: start, end: end, progress: progress) }
        let asset = AVURLAsset(url: input)
        let ext = outExt(for: input)
        let out = Paths.output(for: input, suffix: "trimmed", ext: ext)
        let range = CMTimeRange(start: seconds(start), end: seconds(end))
        try await exportBest(asset, to: out, type: fileType(for: ext), progress: progress) { $0.timeRange = range }
        return out
    }

    static func extractAudio(_ input: URL, progress: @escaping ProgressHandler) async throws -> URL {
        if !(await MediaFF.isNativeVideo(input)) { return try MediaFF.extractAudio(input, progress: progress) }
        let asset = AVURLAsset(url: input)
        let out = Paths.output(for: input, ext: "m4a")
        try await export(asset, preset: AVAssetExportPresetAppleM4A, to: out, type: .m4a, progress: progress)
        return out
    }

    static func stripMetadata(_ input: URL, progress: @escaping ProgressHandler) async throws -> URL {
        if !(await MediaFF.isNativeVideo(input)) { return try MediaFF.stripMetadata(input, progress: progress) }
        let asset = AVURLAsset(url: input)
        let ext = outExt(for: input)
        let out = Paths.output(for: input, suffix: "clean", ext: ext)
        try await exportBest(asset, to: out, type: fileType(for: ext), progress: progress) { s in
            s.metadata = []
            s.metadataItemFilter = AVMetadataItemFilter.forSharing()
        }
        return out
    }

    /// Builds one composition from several assets played back to back.
    static func composition(_ assets: [AVAsset], includeAudio: Bool) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let aTrack = includeAudio ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var cursor = CMTime.zero
        var transform: CGAffineTransform? = nil
        for asset in assets {
            let dur = try await asset.load(.duration)
            let full = CMTimeRange(start: .zero, duration: dur)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                let tr = try await v.load(.timeRange)
                try vTrack?.insertTimeRange(CMTimeRangeGetIntersection(full, otherRange: tr), of: v, at: cursor)
                if transform == nil { transform = try await v.load(.preferredTransform) }
            }
            if let aTrack = aTrack, let a = try await asset.loadTracks(withMediaType: .audio).first {
                let tr = try await a.load(.timeRange)
                try aTrack.insertTimeRange(CMTimeRangeGetIntersection(full, otherRange: tr), of: a, at: cursor)
            }
            cursor = CMTimeAdd(cursor, dur)
        }
        if let t = transform { vTrack?.preferredTransform = t }
        if let aTrack = aTrack, aTrack.segments.isEmpty { comp.removeTrack(aTrack) }
        return comp
    }

    static func mute(_ input: URL, progress: @escaping ProgressHandler) async throws -> URL {
        if !(await MediaFF.isNativeVideo(input)) { return try MediaFF.mute(input, progress: progress) }
        let comp = try await composition([AVURLAsset(url: input)], includeAudio: false)
        let ext = outExt(for: input)
        let out = Paths.output(for: input, suffix: "no audio", ext: ext)
        try await exportBest(comp, to: out, type: fileType(for: ext), progress: progress)
        return out
    }

    static func join(_ inputs: [URL], progress: @escaping ProgressHandler) async throws -> URL {
        var sources: [URL] = []
        for u in inputs {
            if await MediaFF.isNativeVideo(u) { sources.append(u) } else { sources.append(try MediaFF.toTempMP4(u)) }
        }
        let comp = try await composition(sources.map { AVURLAsset(url: $0) }, includeAudio: true)
        let out = Paths.unique(folder: Paths.folder(for: inputs[0]), name: "Joined", ext: "mp4")
        try await export(comp, preset: AVAssetExportPresetHighestQuality, to: out, type: .mp4, progress: progress)
        return out
    }

    static func speed(_ input: URL, factor: Double, progress: @escaping ProgressHandler) async throws -> URL {
        guard factor > 0 else { throw BremorphError("Speed must be above 0") }
        if !(await MediaFF.isNativeVideo(input)) { return try MediaFF.speed(input, factor: factor, progress: progress) }
        let comp = try await composition([AVURLAsset(url: input)], includeAudio: true)
        let total = comp.duration
        comp.scaleTimeRange(CMTimeRange(start: .zero, duration: total), toDuration: CMTimeMultiplyByFloat64(total, multiplier: 1.0 / factor))
        let label = factor == floor(factor) ? "\(Int(factor))x" : String(format: "%.2gx", factor)
        let out = Paths.output(for: input, suffix: label, ext: "mp4")
        try await export(comp, preset: AVAssetExportPresetHighestQuality, to: out, type: .mp4, progress: progress) { s in
            s.audioTimePitchAlgorithm = .spectral
        }
        return out
    }

    static func snapshot(_ input: URL, at t: Double) async throws -> URL {
        if !(await MediaFF.isNativeVideo(input)) {
            let out = Paths.output(for: input, suffix: String(format: "%.1fs", t), ext: "png")
            try MediaFF.snapshot(input, at: t, to: out)
            return out
        }
        let asset = AVURLAsset(url: input)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let img = try await gen.image(at: seconds(t)).image
        let out = Paths.output(for: input, suffix: String(format: "%.1fs", t), ext: "png")
        try ImageOps.write(img, to: out, type: .png)
        return out
    }

    static func gif(_ input: URL, start: Double, end: Double, fps: Int, width: Int, progress: @escaping ProgressHandler) async throws -> URL {
        if !(await MediaFF.isNativeVideo(input)) {
            return try MediaFF.gif(input, start: start, end: end, fps: fps, width: width, progress: progress)
        }
        let asset = AVURLAsset(url: input)
        let dur = try await asset.load(.duration).seconds
        let s = max(0, start), e = min(end, dur)
        guard e > s else { throw BremorphError("End time must be after start time") }
        let frameCount = min(900, max(1, Int((e - s) * Double(fps))))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: width, height: width * 4)
        let tol = seconds(0.5 / Double(fps))
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let out = Paths.output(for: input, ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw BremorphError("Couldn't create GIF")
        }
        let fileProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let frameProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]]
        for i in 0..<frameCount {
            let t = s + Double(i) / Double(fps)
            let img = try await gen.image(at: seconds(t)).image
            CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
            progress(Double(i + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(dest) else { throw BremorphError("Couldn't save GIF") }
        return out
    }

    // MARK: Split

    static func split(_ input: URL, mode: SplitMode, value: Double, progress: @escaping ProgressHandler) async throws -> URL {
        let native = await MediaFF.isNativeVideo(input)
        let dur: Double
        if native {
            dur = try await AVURLAsset(url: input).load(.duration).seconds
        } else {
            dur = FF.duration(input) ?? 0
        }
        guard dur > 0 else { throw BremorphError("Couldn't read video duration") }
        var ranges: [(Double, Double)] = []
        if mode == .parts {
            let n = max(2, min(50, Int(value.rounded())))
            let len = dur / Double(n)
            for i in 0..<n { ranges.append((Double(i) * len, min(dur, Double(i + 1) * len))) }
        } else {
            let len = max(1, value)
            var t = 0.0
            while t < dur - 0.05 { ranges.append((t, min(dur, t + len))); t += len }
        }
        if Helpers.ffmpeg != nil { return try MediaFF.split(input, ranges: ranges, progress: progress) }
        if !native { throw BremorphError(Helpers.ffmpegMissing) }
        let folder = try Paths.newFolder(for: input, suffix: "parts")
        let ext = outExt(for: input)
        let base = input.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: input)
        for (i, r) in ranges.enumerated() {
            let out = folder.appendingPathComponent(String(format: "%@ part %02d", base, i + 1)).appendingPathExtension(ext)
            let range = CMTimeRange(start: seconds(r.0), end: seconds(r.1))
            try await exportBest(asset, to: out, type: fileType(for: ext), progress: { p in
                progress((Double(i) + p) / Double(ranges.count))
            }) { $0.timeRange = range }
        }
        return folder
    }

    // MARK: Target-size re-encode

    static func fitSize(_ input: URL, targetBytes: Int64, progress: @escaping ProgressHandler) async throws -> URL {
        if !(await MediaFF.isNativeVideo(input)) { return try MediaFF.fitSize(input, targetBytes: targetBytes, progress: progress) }
        let asset = AVURLAsset(url: input)
        let dur = try await asset.load(.duration).seconds
        guard dur > 0 else { throw BremorphError("Couldn't read video duration") }
        let totalBits = Double(targetBytes) * 8 * 0.94 // leave room for container overhead
        let budget = totalBits / dur
        let audioBits = budget < 400_000 ? 48_000.0 : (budget < 1_000_000 ? 96_000.0 : 128_000.0)
        let videoBits = Int(max(60_000, budget - audioBits))
        // Pick a resolution that suits the bitrate.
        let maxDim: Int
        switch videoBits {
        case ..<250_000: maxDim = 426
        case ..<600_000: maxDim = 640
        case ..<1_500_000: maxDim = 960
        case ..<4_000_000: maxDim = 1280
        default: maxDim = 1920
        }
        let label = ByteCountFormatter().string(fromByteCount: targetBytes)
        let out = Paths.output(for: input, suffix: label, ext: "mp4")
        try await reencode(asset, to: out, videoBitrate: videoBits, audioBitrate: Int(audioBits), maxDimension: maxDim, progress: progress)
        return out
    }

    static func reencode(_ asset: AVAsset, to out: URL, videoBitrate: Int, audioBitrate: Int = 128_000, maxDimension: Int, progress: @escaping ProgressHandler) async throws {
        try? FileManager.default.removeItem(at: out)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let duration = try await asset.load(.duration).seconds

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)] = []

        if let vt = try await asset.loadTracks(withMediaType: .video).first {
            let natural = try await vt.load(.naturalSize)
            let transform = try await vt.load(.preferredTransform)
            var w = abs(natural.width), h = abs(natural.height)
            let longest = max(w, h)
            if longest > CGFloat(maxDimension) {
                let s = CGFloat(maxDimension) / longest
                w *= s; h *= s
            }
            let W = max(2, Int(w / 2) * 2), H = max(2, Int(h / 2) * 2)
            let rOut = AVAssetReaderTrackOutput(track: vt, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            rOut.alwaysCopiesSampleData = false
            let wIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: W,
                AVVideoHeightKey: H,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoBitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
            wIn.transform = transform
            wIn.expectsMediaDataInRealTime = false
            if reader.canAdd(rOut) && writer.canAdd(wIn) {
                reader.add(rOut); writer.add(wIn)
                pairs.append((rOut, wIn, true))
            }
        }

        if let at = try await asset.loadTracks(withMediaType: .audio).first {
            var channels = 2
            if let fd = try await at.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
            }
            let rOut = AVAssetReaderTrackOutput(track: at, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: channels,
            ])
            let wIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: audioBitrate,
            ])
            wIn.expectsMediaDataInRealTime = false
            if reader.canAdd(rOut) && writer.canAdd(wIn) {
                reader.add(rOut); writer.add(wIn)
                pairs.append((rOut, wIn, false))
            }
        }

        guard !pairs.isEmpty else { throw BremorphError("No video or audio found") }
        guard writer.startWriting() else { throw BremorphError(writer.error?.localizedDescription ?? "Couldn't start writing") }
        guard reader.startReading() else { throw BremorphError(reader.error?.localizedDescription ?? "Couldn't read the video") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        for (rOut, wIn, isVideo) in pairs {
            group.enter()
            let queue = DispatchQueue(label: "bremorph.reencode.\(isVideo ? "v" : "a")")
            var finished = false
            wIn.requestMediaDataWhenReady(on: queue) {
                while wIn.isReadyForMoreMediaData && !finished {
                    if let sb = rOut.copyNextSampleBuffer() {
                        if isVideo, duration > 0 {
                            progress(min(0.99, CMSampleBufferGetPresentationTimeStamp(sb).seconds / duration))
                        }
                        if !wIn.append(sb) {
                            finished = true
                            wIn.markAsFinished()
                            group.leave()
                        }
                    } else {
                        finished = true
                        wIn.markAsFinished()
                        group.leave()
                    }
                }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw BremorphError(reader.error?.localizedDescription ?? "Reading failed")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw BremorphError(writer.error?.localizedDescription ?? "Writing failed")
        }
        progress(1)
    }
}
