import AVFoundation

/// Turns raw CAF parts into 16 kHz mono AAC tracks on the pause-free timeline, and mixes them for listening.
enum Render {
    static let rate: Double = 16000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    struct TrackResult {
        let url: URL
        let seconds: Double
        /// Loudest 1 s window, dBFS. Very low means the track is silence.
        let loudestDB: Double
    }

    static func aacSettings(bitrate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate,
        ]
    }

    private struct Meter {
        var sum = 0.0
        var count = 0
        var maxDB = -120.0
        mutating func feed(_ p: UnsafePointer<Float>, _ n: Int) {
            for i in 0..<n {
                sum += Double(p[i] * p[i])
                count += 1
                if count == Int(Render.rate) { flush() }
            }
        }
        mutating func flush() {
            guard count > 0 else { return }
            let db = 10 * log10(max(sum / Double(count), 1e-12))
            maxDB = max(maxDB, db)
            sum = 0
            count = 0
        }
    }

    static func renderTrack(parts: [PartInfo], dir: URL, timeline: Timeline, out: URL) throws -> TrackResult {
        try? FileManager.default.removeItem(at: out)
        let outFile = try AVAudioFile(forWriting: out, settings: aacSettings(bitrate: 32000),
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        var written: Int64 = 0
        var meter = Meter()

        func write(_ src: AVAudioPCMBuffer, from offset: Int, count: Int) throws {
            guard count > 0, let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
            chunk.frameLength = AVAudioFrameCount(count)
            chunk.floatChannelData![0].update(from: src.floatChannelData![0] + offset, count: count)
            try outFile.write(from: chunk)
            meter.feed(chunk.floatChannelData![0], count)
            written += Int64(count)
        }

        func silence(_ frames: Int64) throws {
            var left = frames
            while left > 0 {
                let n = Int(min(left, Int64(rate)))
                guard let z = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
                z.frameLength = AVAudioFrameCount(n)
                memset(z.floatChannelData![0], 0, n * MemoryLayout<Float>.size)
                try outFile.write(from: z)
                meter.feed(z.floatChannelData![0], n)
                written += Int64(n)
                left -= Int64(n)
            }
        }

        for part in parts.sorted(by: { $0.startHost < $1.startHost }) {
            guard let inFile = try? AVAudioFile(forReading: dir.appendingPathComponent(part.file)) else {
                Log.info("render: cannot read \(part.file)")
                continue
            }
            let startFrame = Int64((timeline.position(part.startHost) * rate).rounded())
            if startFrame > written { try silence(startFrame - written) }
            var skip = max(0, written - startFrame)
            var allowed = Int64.max
            if let end = timeline.intervalEnd(containing: part.startHost) {
                allowed = Int64((HostTime.diff(end, part.startHost) * rate).rounded()) - skip
                if allowed <= 0 { continue }
            }
            guard let converter = AVAudioConverter(from: inFile.processingFormat, to: format),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { continue }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            var inputDone = false
            while allowed > 0 {
                var error: NSError?
                let status = converter.convert(to: outBuf, error: &error) { packets, inputStatus in
                    if inputDone {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    guard let ib = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: packets) else {
                        inputDone = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    do { try inFile.read(into: ib, frameCount: packets) } catch {
                        inputDone = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    if ib.frameLength == 0 {
                        inputDone = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return ib
                }
                if status == .error { throw error ?? CaptureError(message: "conversion failed: \(part.file)") }
                let n = Int64(outBuf.frameLength)
                if n > 0 {
                    let drop = min(skip, n)
                    skip -= drop
                    let count = min(n - drop, allowed)
                    if count > 0 {
                        try write(outBuf, from: Int(drop), count: Int(count))
                        allowed -= count
                    }
                }
                if status == .endOfStream || status == .inputRanDry { break }
            }
        }
        meter.flush()
        if #available(macOS 15.0, *) { outFile.close() }
        return TrackResult(url: out, seconds: Double(written) / rate, loudestDB: meter.maxDB)
    }

    /// Raises a quiet track so its loudest second sits near `targetDB` (at most +`maxGainDB`).
    /// A quiet remote voice is transcribed better and is easier to listen to. Returns the gain applied.
    @discardableResult
    static func normalize(_ url: URL, loudestDB: Double, targetDB: Double = -20, maxGainDB: Double = 30) throws -> Double {
        guard loudestDB > -100, loudestDB < targetDB - 6 else { return 0 }
        let gainDB = min(targetDB - loudestDB, maxGainDB)
        let gain = Float(pow(10, gainDB / 20))
        let input = try AVAudioFile(forReading: url)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("norm-" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        let output = try AVAudioFile(forWriting: tmp, settings: aacSettings(bitrate: 32000),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioFrameCount(rate)
        while true {
            guard let b = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else { break }
            try? input.read(into: b, frameCount: chunk)
            guard b.frameLength > 0, let d = b.floatChannelData?[0] else { break }
            for i in 0..<Int(b.frameLength) {
                let v = d[i] * gain
                d[i] = abs(v) > 0.95 ? tanh(v) : v
            }
            try output.write(from: b)
        }
        if #available(macOS 15.0, *) { output.close() }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        return gainDB
    }

    /// Mono mix of the rendered tracks for listening in Obsidian. Returns its length in seconds.
    @discardableResult
    static func mix(_ inputs: [URL], out: URL) throws -> Double {
        try? FileManager.default.removeItem(at: out)
        let files = inputs.compactMap { try? AVAudioFile(forReading: $0) }
        let outFile = try AVAudioFile(forWriting: out, settings: aacSettings(bitrate: 48000),
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioFrameCount(rate)
        var total: Int64 = 0
        let gain: Float = files.count > 1 ? 0.8 : 1.0
        while true {
            guard let mixBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            let m = mixBuf.floatChannelData![0]
            memset(m, 0, Int(chunk) * MemoryLayout<Float>.size)
            var longest: AVAudioFrameCount = 0
            for f in files {
                guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: chunk) else { continue }
                try? f.read(into: b, frameCount: chunk)
                guard b.frameLength > 0, let src = b.floatChannelData?[0] else { continue }
                longest = max(longest, b.frameLength)
                for i in 0..<Int(b.frameLength) { m[i] += src[i] * gain }
            }
            if longest == 0 { break }
            for i in 0..<Int(longest) where abs(m[i]) > 0.95 { m[i] = tanh(m[i]) }
            mixBuf.frameLength = longest
            try outFile.write(from: mixBuf)
            total += Int64(longest)
        }
        if #available(macOS 15.0, *) { outFile.close() }
        return Double(total) / rate
    }
}
