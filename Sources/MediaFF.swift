import Foundation
import AVFoundation

enum AudioFormat {
    case mp3, ogg, opus, wma

    var ext: String {
        switch self {
        case .mp3: return "mp3"
        case .ogg: return "ogg"
        case .opus: return "opus"
        case .wma: return "wma"
        }
    }

    var codecArgs: [String] {
        switch self {
        case .mp3: return ["-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3"]
        case .ogg: return ["-c:a", "libvorbis", "-q:a", "6"]
        case .opus: return ["-c:a", "libopus", "-b:a", "128k"]
        case .wma: return ["-c:a", "wmav2", "-b:a", "192k"]
        }
    }

    /// Fallbacks for ffmpeg builds without libvorbis.
    var alternativeArgs: [[String]] {
        switch self {
        case .ogg: return [["-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-q:a", "6"], ["-c:a", "libopus", "-b:a", "160k"]]
        default: return []
        }
    }
}

/// Video/audio work done with ffmpeg: extra formats, and files AVFoundation can't open (MKV, WebM, AVI, WMV, OGG…).
enum MediaFF {
    static func isNativeVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { return false }
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }

    static func isNativeAudio(_ url: URL) -> Bool {
        (try? AVAudioFile(forReading: url)) != nil
    }

    // MARK: Conversions

    static func convertVideo(_ input: URL, ext: String, progress: @escaping ProgressHandler) throws -> URL {
        let same = input.pathExtension.lowercased() == ext
        let out = Paths.output(for: input, suffix: same ? "converted" : nil, ext: ext)
        let d = FF.duration(input)
        let (v, a) = FF.codecs(input)
        // Fast path: copy streams when the target container supports them.
        let mp4Friendly = ["h264", "hevc"].contains(v ?? "") && (a == nil || ["aac", "mp3", "alac"].contains(a ?? ""))
        if (ext == "mkv") || (["mp4", "mov", "m4v"].contains(ext) && mp4Friendly) {
            do {
                var args = ["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy"]
                if ext != "mkv" { args += ["-movflags", "+faststart"] }
                if v == "hevc" && ext != "mkv" { args += ["-tag:v", "hvc1"] }
                try FF.run(args + [out.path], duration: d, progress: progress)
                return out
            } catch {
                try? FileManager.default.removeItem(at: out)
            }
        }
        var args = ["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?"]
        if ext != "avi" && ext != "wmv" { args += ["-vf", FF.evenScale] }
        try FF.run(args + FF.videoCodecArgs(for: ext) + [out.path], duration: d, progress: progress)
        return out
    }

    static func convertAudio(_ input: URL, format: AudioFormat, progress: @escaping ProgressHandler) throws -> URL {
        let out = Paths.output(for: input, ext: format.ext)
        let d = FF.duration(input)
        var attempts = [format.codecArgs] + format.alternativeArgs
        var lastError: Error = BremorphError("Conversion failed")
        while !attempts.isEmpty {
            let codec = attempts.removeFirst()
            do {
                try FF.run(["-i", input.path, "-vn", "-map_metadata", "0"] + codec + [out.path], duration: d, progress: progress)
                return out
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: out)
            }
        }
        throw lastError
    }

    /// For the built-in audio formats when afconvert can't read the source (OGG, Opus, WMA…).
    static func convertAudio(_ input: URL, spec: AudioSpec, suffix: String?, channels: Int? = nil) throws -> URL {
        let out = Paths.output(for: input, suffix: suffix, ext: spec.ext)
        var codec: [String]
        switch (spec.file, spec.data) {
        case ("m4af", "aac"): codec = ["-c:a", "aac", "-b:a", "256k"]
        case ("m4af", "alac"): codec = ["-c:a", "alac"]
        case ("WAVE", _): codec = ["-c:a", "pcm_s16le"]
        case ("AIFF", _): codec = ["-c:a", "pcm_s16be"]
        case ("caff", _): codec = ["-c:a", "pcm_s16le"]
        case ("flac", _): codec = ["-c:a", "flac"]
        default: codec = ["-c:a", "aac", "-b:a", "256k"]
        }
        if let ch = channels { codec += ["-ac", String(ch)] }
        try FF.run(["-i", input.path, "-vn", "-map_metadata", "0"] + codec + [out.path], duration: FF.duration(input))
        return out
    }

    // MARK: Video tools for files AVFoundation can't open

    static func trim(_ input: URL, start: Double, end: Double, progress: @escaping ProgressHandler) throws -> URL {
        let out = Paths.output(for: input, suffix: "trimmed", ext: input.pathExtension.lowercased())
        try FF.run(["-ss", String(start), "-i", input.path, "-t", String(end - start), "-map", "0", "-c", "copy"] + [out.path],
                   duration: end - start, progress: progress)
        return out
    }

    static func compress(_ input: URL, quality: VideoQuality, progress: @escaping ProgressHandler) throws -> URL {
        let out = Paths.output(for: input, suffix: "compressed", ext: "mp4")
        var codec = ["-c:v", "libx264", "-crf", "25", "-preset", "medium"]
        if quality == .hevc { codec = ["-c:v", "libx265", "-crf", "28", "-preset", "medium", "-tag:v", "hvc1"] }
        try FF.run(["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-vf", FF.scaleLongSide(quality.longSide)] + codec +
                   ["-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", out.path],
                   duration: FF.duration(input), progress: progress)
        return out
    }

    static func fitSize(_ input: URL, targetBytes: Int64, progress: @escaping ProgressHandler) throws -> URL {
        guard let dur = FF.duration(input), dur > 0 else { throw BremorphError("Couldn't read video duration") }
        let budget = Double(targetBytes) * 8 * 0.94 / dur
        let audioBits = budget < 400_000 ? 48_000.0 : (budget < 1_000_000 ? 96_000.0 : 128_000.0)
        let videoBits = Int(max(60_000, budget - audioBits))
        let longSide = videoBits < 250_000 ? 426 : videoBits < 600_000 ? 640 : videoBits < 1_500_000 ? 960 : videoBits < 4_000_000 ? 1280 : 1920
        let out = Paths.output(for: input, suffix: Paths.sizeTag(targetBytes), ext: "mp4")
        let kb = "\(videoBits / 1000)k"
        try FF.run(["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-vf", FF.scaleLongSide(longSide),
                    "-c:v", "libx264", "-preset", "medium", "-b:v", kb, "-maxrate", kb, "-bufsize", "\(videoBits / 500)k",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(Int(audioBits) / 1000)k", "-movflags", "+faststart", out.path],
                   duration: dur, progress: progress)
        return out
    }

    static func atempoChain(_ f: Double) -> String {
        var parts: [String] = []
        var r = f
        while r > 2.0 { parts.append("atempo=2.0"); r /= 2.0 }
        while r < 0.5 { parts.append("atempo=0.5"); r /= 0.5 }
        parts.append("atempo=\(r)")
        return parts.joined(separator: ",")
    }

    static func speed(_ input: URL, factor: Double, progress: @escaping ProgressHandler) throws -> URL {
        let label = factor == floor(factor) ? "\(Int(factor))x" : String(format: "%.2gx", factor)
        let out = Paths.output(for: input, suffix: label, ext: "mp4")
        let hasAudio = FF.codecs(input).audio != nil
        var args = ["-i", input.path]
        if hasAudio {
            args += ["-filter_complex", "[0:v]setpts=PTS/\(factor),\(FF.evenScale)[v];[0:a]\(atempoChain(factor))[a]", "-map", "[v]", "-map", "[a]"]
        } else {
            args += ["-vf", "setpts=PTS/\(factor),\(FF.evenScale)", "-an"]
        }
        args += ["-c:v", "libx264", "-crf", "21", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", out.path]
        try FF.run(args, duration: (FF.duration(input) ?? 0) / factor, progress: progress)
        return out
    }

    static func mute(_ input: URL, progress: @escaping ProgressHandler) throws -> URL {
        let out = Paths.output(for: input, suffix: "no audio", ext: FF.outVideoExt(input))
        try FF.run(["-i", input.path, "-map", "0:v:0", "-c:v", "copy", "-an", out.path], duration: FF.duration(input), progress: progress)
        return out
    }

    static func extractAudio(_ input: URL, progress: @escaping ProgressHandler) throws -> URL {
        let out = Paths.output(for: input, ext: "m4a")
        try FF.run(["-i", input.path, "-vn", "-c:a", "aac", "-b:a", "192k", out.path], duration: FF.duration(input), progress: progress)
        return out
    }

    static func snapshot(_ input: URL, at t: Double, to out: URL) throws {
        try FF.run(["-ss", String(t), "-i", input.path, "-frames:v", "1", "-update", "1", out.path])
    }

    static func gif(_ input: URL, start: Double, end: Double, fps: Int, width: Int, progress: @escaping ProgressHandler) throws -> URL {
        let out = Paths.output(for: input, ext: "gif")
        let filter = "fps=\(fps),scale=\(width):-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
        try FF.run(["-ss", String(start), "-t", String(max(0.1, end - start)), "-i", input.path, "-vf", filter, "-loop", "0", out.path],
                   duration: end - start, progress: progress)
        return out
    }

    static func stripMetadata(_ input: URL, progress: @escaping ProgressHandler) throws -> URL {
        let out = Paths.output(for: input, suffix: "clean", ext: input.pathExtension.lowercased())
        try FF.run(["-i", input.path, "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy", out.path],
                   duration: FF.duration(input), progress: progress)
        return out
    }

    /// Re-encodes into a temporary MP4 so AVFoundation tools can work on it.
    static func toTempMP4(_ input: URL) throws -> URL {
        let dir = try Helpers.tempDir()
        let out = dir.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".mp4")
        try FF.run(["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-vf", FF.evenScale] + FF.videoCodecArgs(for: "mp4") + [out.path])
        return out
    }

    static func crop(_ input: URL, rect: CGRect, progress: @escaping ProgressHandler) throws -> URL {
        let w = max(2, Int(rect.width) / 2 * 2), h = max(2, Int(rect.height) / 2 * 2)
        let x = max(0, Int(rect.minX)), y = max(0, Int(rect.minY))
        let ext = FF.outVideoExt(input)
        let out = Paths.output(for: input, suffix: "cropped", ext: ext)
        var codec = FF.videoCodecArgs(for: ext)
        if ["mp4", "mov", "m4v", "mkv"].contains(ext) {
            codec = ["-c:v", "libx264", "-crf", "19", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
            if ext != "mkv" { codec += ["-movflags", "+faststart"] }
        }
        try FF.run(["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-vf", "crop=\(w):\(h):\(x):\(y)"] + codec + [out.path],
                   duration: FF.duration(input), progress: progress)
        return out
    }

    static func split(_ input: URL, ranges: [(Double, Double)], progress: @escaping ProgressHandler) throws -> URL {
        let folder = try Paths.newFolder(for: input, suffix: "parts")
        let base = input.deletingPathExtension().lastPathComponent
        let ext = input.pathExtension.lowercased()
        for (i, r) in ranges.enumerated() {
            let out = folder.appendingPathComponent(String(format: "%@ part %02d", base, i + 1)).appendingPathExtension(ext)
            try FF.run(["-ss", String(r.0), "-i", input.path, "-t", String(r.1 - r.0), "-map", "0", "-c", "copy",
                        "-avoid_negative_ts", "make_zero", out.path])
            progress(Double(i + 1) / Double(ranges.count))
        }
        return folder
    }

    // MARK: Audio tools for files AVAudioFile can't open

    static func audioTool(_ input: URL, suffix: String, filter: String?, channels: Int? = nil, trim: (Double, Double)? = nil) throws -> URL {
        let ext = ["mp3", "ogg", "opus", "wma", "flac", "wav", "m4a"].contains(input.pathExtension.lowercased()) ? input.pathExtension.lowercased() : "m4a"
        let out = Paths.output(for: input, suffix: suffix, ext: ext)
        var args: [String] = []
        if let t = trim { args += ["-ss", String(t.0)] }
        args += ["-i", input.path]
        if let t = trim { args += ["-t", String(t.1 - t.0)] }
        args += ["-vn", "-map_metadata", "0"]
        if let f = filter { args += ["-af", f] }
        if let ch = channels { args += ["-ac", String(ch)] }
        switch ext {
        case "mp3": args += ["-c:a", "libmp3lame", "-q:a", "2"]
        case "opus", "ogg": args += ["-c:a", "libopus", "-b:a", "160k"]
        case "wma": args += ["-c:a", "wmav2", "-b:a", "192k"]
        case "flac": args += ["-c:a", "flac"]
        case "wav": args += ["-c:a", "pcm_s16le"]
        default: args += ["-c:a", "aac", "-b:a", "256k"]
        }
        try FF.run(args + [out.path], duration: FF.duration(input))
        return out
    }

    static func bleep(_ input: URL, start: Double, end: Double) throws -> URL {
        let ext = ["mp3", "flac", "wav", "m4a"].contains(input.pathExtension.lowercased()) ? input.pathExtension.lowercased() : "m4a"
        let out = Paths.output(for: input, suffix: "bleeped", ext: ext)
        let ms = Int(start * 1000)
        let graph = "[0:a]volume=enable='between(t,\(start),\(end))':volume=0[m];" +
            "sine=frequency=1000:sample_rate=44100:duration=\(end - start),volume=0.3,adelay=\(ms):all=1[b];" +
            "[m][b]amix=inputs=2:duration=first:normalize=0[out]"
        var codec: [String]
        switch ext {
        case "mp3": codec = ["-c:a", "libmp3lame", "-q:a", "2"]
        case "flac": codec = ["-c:a", "flac"]
        case "wav": codec = ["-c:a", "pcm_s16le"]
        default: codec = ["-c:a", "aac", "-b:a", "256k"]
        }
        try FF.run(["-i", input.path, "-filter_complex", graph, "-map", "[out]"] + codec + [out.path], duration: FF.duration(input))
        return out
    }
}
