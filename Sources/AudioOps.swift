import Foundation
import AVFoundation

struct AudioSpec {
    let file: String   // afconvert file format
    let data: String   // afconvert data format
    let ext: String
    var bitrate: Int? = nil

    static let aac = AudioSpec(file: "m4af", data: "aac", ext: "m4a", bitrate: 256_000)
    static let alac = AudioSpec(file: "m4af", data: "alac", ext: "m4a")
    static let wav = AudioSpec(file: "WAVE", data: "LEI16", ext: "wav")
    static let aiff = AudioSpec(file: "AIFF", data: "BEI16", ext: "aiff")
    static let caf = AudioSpec(file: "caff", data: "LEI16", ext: "caf")
    static let flac = AudioSpec(file: "flac", data: "flac", ext: "flac")
}

enum AudioOps {
    static let afconvert = "/usr/bin/afconvert"

    static func convert(_ input: URL, spec: AudioSpec, suffix: String? = nil, extra: [String] = []) throws -> URL {
        let same = input.pathExtension.lowercased() == spec.ext
        let sfx = suffix ?? (same ? "converted" : nil)
        let out = Paths.output(for: input, suffix: sfx, ext: spec.ext)
        var args = ["-f", spec.file, "-d", spec.data]
        if let b = spec.bitrate { args += ["-b", String(b)] }
        args += extra
        args += [input.path, out.path]
        do {
            try Shell.run(afconvert, args)
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            // afconvert can't read OGG, Opus, WMA, or audio inside videos — let ffmpeg try.
            if Helpers.ffmpeg != nil {
                var channels: Int? = nil
                if let i = extra.firstIndex(of: "-c"), i + 1 < extra.count { channels = Int(extra[i + 1]) }
                return try MediaFF.convertAudio(input, spec: spec, suffix: sfx, channels: channels)
            }
            throw BremorphError(LF("Couldn't convert %@: %@", input.lastPathComponent, error.localizedDescription))
        }
    }

    static func sameFormatSpec(_ input: URL) -> AudioSpec {
        switch input.pathExtension.lowercased() {
        case "wav", "wave": return .wav
        case "aif", "aiff": return .aiff
        case "caf": return .caf
        case "flac": return .flac
        default: return .aac
        }
    }

    static func trim(_ input: URL, start: Double, end: Double, progress: @escaping ProgressHandler) async throws -> URL {
        guard end > start else { throw BremorphError("End time must be after start time") }
        if !MediaFF.isNativeAudio(input) {
            return try MediaFF.audioTool(input, suffix: "trimmed", filter: nil, trim: (start, end))
        }
        let asset = AVURLAsset(url: input)
        let out = Paths.output(for: input, suffix: "trimmed", ext: "m4a")
        let range = CMTimeRange(start: VideoOps.seconds(start), end: VideoOps.seconds(end))
        try await VideoOps.export(asset, preset: AVAssetExportPresetAppleM4A, to: out, type: .m4a, progress: progress) { s in
            s.timeRange = range
        }
        return out
    }

    // MARK: Sample-level processing (native)

    /// Reads the whole file, lets `transform` change the samples, and writes the result.
    private static func process(_ input: URL, suffix: String, channelsOut: Int? = nil,
                                transform: (AVAudioPCMBuffer) throws -> AVAudioPCMBuffer) throws -> URL {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BremorphError("File is too large to process")
        }
        try file.read(into: buffer)
        let result = try transform(buffer)
        let spec = sameFormatSpec(input)
        let out = Paths.output(for: input, suffix: suffix, ext: spec.ext == "flac" ? "wav" : spec.ext)
        var settings: [String: Any] = [
            AVSampleRateKey: result.format.sampleRate,
            AVNumberOfChannelsKey: result.format.channelCount,
        ]
        switch out.pathExtension {
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 256_000
        case "aiff":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsBigEndianKey] = true
            settings[AVLinearPCMIsFloatKey] = false
        default:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsFloatKey] = false
        }
        do {
            let outFile = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try outFile.write(from: result)
        }
        return out
    }

    /// Raises the volume so the loudest peak sits just under 0 dBFS.
    static func normalize(_ input: URL) throws -> URL {
        if !MediaFF.isNativeAudio(input) {
            return try MediaFF.audioTool(input, suffix: "normalized", filter: "loudnorm=I=-14:TP=-1:LRA=11")
        }
        return try process(input, suffix: "normalized") { buffer in
            guard let ch = buffer.floatChannelData else { throw BremorphError("Unsupported audio format") }
            let frames = Int(buffer.frameLength), n = Int(buffer.format.channelCount)
            var peak: Float = 0
            for c in 0..<n { for i in 0..<frames { peak = max(peak, abs(ch[c][i])) } }
            guard peak > 0 else { throw BremorphError("The audio is silent") }
            let gain = 0.98 / peak
            for c in 0..<n { for i in 0..<frames { ch[c][i] *= gain } }
            return buffer
        }
    }

    /// Replaces a stretch of audio with a 1 kHz tone.
    static func bleep(_ input: URL, start: Double, end: Double) throws -> URL {
        guard end > start else { throw BremorphError("End time must be after start time") }
        if !MediaFF.isNativeAudio(input) {
            return try MediaFF.bleep(input, start: start, end: end)
        }
        return try process(input, suffix: "bleeped") { buffer in
            guard let ch = buffer.floatChannelData else { throw BremorphError("Unsupported audio format") }
            let sr = buffer.format.sampleRate
            let frames = Int(buffer.frameLength), n = Int(buffer.format.channelCount)
            let a = max(0, min(frames, Int(start * sr))), b = max(0, min(frames, Int(end * sr)))
            guard b > a else { throw BremorphError("That time range is outside the audio") }
            for i in a..<b {
                let v = Float(0.3 * sin(2 * Double.pi * 1000 * Double(i - a) / sr))
                for c in 0..<n { ch[c][i] = v }
            }
            return buffer
        }
    }

    /// Converts to mono (1) or stereo (2).
    static func channels(_ input: URL, count: Int) throws -> URL {
        let suffix = count == 1 ? "mono" : "stereo"
        if !MediaFF.isNativeAudio(input) {
            return try MediaFF.audioTool(input, suffix: suffix, filter: nil, channels: count)
        }
        return try process(input, suffix: suffix) { buffer in
            guard let src = buffer.floatChannelData else { throw BremorphError("Unsupported audio format") }
            let frames = Int(buffer.frameLength), n = Int(buffer.format.channelCount)
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                          channels: AVAudioChannelCount(count), interleaved: false),
                  let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buffer.frameCapacity),
                  let dst = out.floatChannelData else { throw BremorphError("Couldn't prepare audio") }
            out.frameLength = buffer.frameLength
            for i in 0..<frames {
                var mix: Float = 0
                for c in 0..<n { mix += src[c][i] }
                mix /= Float(n)
                for c in 0..<count {
                    // Stereo from stereo keeps both sides; otherwise use the mix.
                    dst[c][i] = (count == n) ? src[c][i] : mix
                }
            }
            return out
        }
    }
}
