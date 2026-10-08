import Foundation
import AVFoundation

struct Interval: Codable {
    var start: UInt64
    var end: UInt64   // 0 while this interval is still being recorded
}

enum JobStatus: String, Codable {
    case recording, finalizing, pending, done, failed, discarded
}

/// recordings/<id>/manifest.json: everything needed to finish a recording, even after a crash.
struct Manifest: Codable {
    var id: String
    var app: String
    var startDate: Date
    var intervals: [Interval] = []
    var status: JobStatus = .recording
    var voiceModeAtStart = true
    var noteFile: String?
    var audioFile: String?
    var durationSec: Double?
    var micSilent: Bool?
    var sysSilent: Bool?
    var sysNoCallbacks: Bool?
    var attempts = 0
    var lastError: String?

    static func load(_ dir: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(Manifest.self, from: data)
    }

    func save(_ dir: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(self) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }
}

/// Recording time without pauses. Host times inside an interval map onto one continuous timeline.
struct Timeline {
    let intervals: [Interval]

    init(_ intervals: [Interval]) {
        self.intervals = intervals.filter { $0.end > $0.start }
    }

    var total: Double { intervals.reduce(0) { $0 + HostTime.diff($1.end, $1.start) } }

    private func index(for host: UInt64) -> Int? {
        guard !intervals.isEmpty else { return nil }
        // The first samples of a part may carry a host time slightly before the interval start.
        let tolerance = HostTime.ticks(1.0)
        for (i, iv) in intervals.enumerated() where host <= iv.end + tolerance {
            if i + 1 < intervals.count, host >= intervals[i + 1].start { continue }
            return i
        }
        return intervals.count - 1
    }

    /// Timeline position (seconds) of a host time. Can be slightly negative at an interval start.
    func position(_ host: UInt64) -> Double {
        guard let i = index(for: host) else { return 0 }
        let before = intervals[..<i].reduce(0) { $0 + HostTime.diff($1.end, $1.start) }
        return before + HostTime.diff(host, intervals[i].start)
    }

    /// Host time at which the interval containing `host` ended (to clip trailing samples).
    func intervalEnd(containing host: UInt64) -> UInt64? {
        guard let i = index(for: host) else { return nil }
        return intervals[i].end
    }

    /// Where pauses sit on the timeline and how long they lasted in real time.
    var pauses: [(at: Double, length: Double)] {
        var result: [(Double, Double)] = []
        var acc = 0.0
        for i in 0..<intervals.count {
            acc += HostTime.diff(intervals[i].end, intervals[i].start)
            if i + 1 < intervals.count {
                result.append((acc, HostTime.diff(intervals[i + 1].start, intervals[i].end)))
            }
        }
        return result
    }
}

enum Parts {
    /// Parts of one track ("mic"/"sys") found on disk via their sidecars, oldest first.
    static func scan(_ dir: URL, track: String) -> [PartInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var parts: [PartInfo] = []
        for n in names where n.hasPrefix("\(track)_") && n.hasSuffix(".caf.json") {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(n)),
               let info = try? JSONDecoder().decode(PartInfo.self, from: data) {
                parts.append(info)
            }
        }
        return parts.sorted { $0.startHost < $1.startHost }
    }

    /// Host time of the last sample written in any part (used when the app died mid-recording).
    static func lastSampleHost(_ dir: URL) -> UInt64 {
        var last: UInt64 = 0
        for track in ["mic", "sys"] {
            for p in scan(dir, track: track) {
                guard let f = try? AVAudioFile(forReading: dir.appendingPathComponent(p.file)) else { continue }
                let end = p.startHost + HostTime.ticks(Double(f.length) / p.sampleRate)
                last = max(last, end)
            }
        }
        return last
    }

    static func removeRaw(_ dir: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names where n.hasSuffix(".caf") || n.hasSuffix(".caf.json") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }
}
