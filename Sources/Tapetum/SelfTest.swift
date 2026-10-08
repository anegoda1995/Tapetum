import AVFoundation

/// `Tapetum --selftest`: logic checks that need no microphone, permissions or server.
enum SelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String) {
        print("\(ok ? "PASS" : "FAIL")  \(name)")
        if !ok { failures += 1 }
    }

    static func run() -> Bool {
        failures = 0
        timeline()
        transcript()
        note()
        formatting()
        localization()
        render()
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }

    private static func timeline() {
        let t0: UInt64 = 1_000_000_000
        let s = HostTime.ticks
        let tl = Timeline([Interval(start: t0, end: t0 + s(10)), Interval(start: t0 + s(20), end: t0 + s(30))])
        check(abs(tl.total - 20) < 0.01, "timeline: total excludes the pause")
        check(abs(tl.position(t0 + s(5)) - 5) < 0.01, "timeline: position in first interval")
        check(abs(tl.position(t0 + s(25)) - 15) < 0.01, "timeline: position after the pause")
        check(tl.pauses.count == 1 && abs(tl.pauses[0].at - 10) < 0.01 && abs(tl.pauses[0].length - 10) < 0.01,
              "timeline: pause at 10 s lasting 10 s")
        check(tl.intervalEnd(containing: t0 + s(21)) == t0 + s(30), "timeline: interval end lookup")
        check(tl.position(t0 - s(0.02)) < 0, "timeline: samples just before the start map slightly negative")
    }

    private static func transcript() {
        let me = Transcript.me, them = L.string("Them")
        let mic = [
            Seg(start: 1.0, end: 3.0, text: "We need the report by the end of the week.", speaker: me, doubtful: false, fromMic: true),
            Seg(start: 5.0, end: 6.0, text: "Sure, no problem.", speaker: me, doubtful: false, fromMic: true),
            Seg(start: 6.2, end: 7.0, text: "I will send it on Friday.", speaker: me, doubtful: true, fromMic: true),
        ]
        let remote = [
            Seg(start: 1.2, end: 3.1, text: "We need the report by the end of the week", speaker: them, doubtful: false, fromMic: false),
            Seg(start: 12.0, end: 13.0, text: "Thanks, talk to you soon.", speaker: them, doubtful: false, fromMic: false),
        ]
        let r = Transcript.build(mic: mic, remote: remote, pauses: [(at: 10, length: 125)], languages: ["en": 5, "uk": 2.5, "fr": 0.2])
        check(r.echoDropped == 1, "transcript: echo of the remote phrase dropped from the mic track")
        check(r.markdown.contains("**[00:00:05] \(me):** Sure, no problem. I will send it on Friday. \(L.string("[unclear?]"))"),
              "transcript: consecutive own phrases merged, doubtful marked")
        check(r.markdown.contains(L.format("Paused, %@ not recorded.", Fmt.human(125))), "transcript: pause marker")
        let pauseIdx = r.markdown.range(of: "⏸")!.lowerBound
        let byeIdx = r.markdown.range(of: "Thanks")!.lowerBound
        check(pauseIdx < byeIdx, "transcript: pause marker before later speech")
        check(r.languages == ["en", "uk"], "transcript: languages sorted, tiny ones dropped")
        check(r.speakers == [them, me], "transcript: speakers listed")
        check(!Transcript.isEcho(mic[1], among: remote), "transcript: own speech is not echo")
        let cyrillic = Seg(start: 20, end: 22, text: "Так, я зрозумів.", speaker: me, doubtful: false, fromMic: true)
        let cyrillicRemote = Seg(start: 20.3, end: 22.1, text: "так я зрозумів", speaker: them, doubtful: false, fromMic: false)
        check(Transcript.isEcho(cyrillic, among: [cyrillicRemote]), "transcript: echo found in non-Latin text")
    }

    private static func note() {
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        let n = Note.initial(audioName: "2026-09-28 17-30 Slack.m4a", date: d, duration: 83, app: "Slack", notes: ["⏸ 1"])
        check(n.hasPrefix("---\nsource: \"[[2026-09-28 17-30 Slack.m4a]]\"\n"), "note: frontmatter with source link")
        check(n.contains("duration: \"00:01:23\""), "note: duration")
        check(n.contains("![[2026-09-28 17-30 Slack.m4a]]"), "note: embedded audio")
        check(n.contains(Note.placeholder), "note: placeholder until the transcript arrives")
        let edited = n.replacingOccurrences(of: "app: \"Slack\"", with: "app: \"Slack\"\ntags: [work]") + "\nMy notes after the call.\n"
        let u = Note.update(edited, body: "**[00:00:01] Me:** Hello", languages: ["en", "uk"], speakers: ["Me", "Them"])
        check(u.contains("**[00:00:01] Me:** Hello") && !u.contains(Note.placeholder), "note: transcript replaces the placeholder")
        check(u.contains("languages: [en, uk]") && u.contains("speakers: [\"Me\", \"Them\"]"), "note: frontmatter updated")
        check(u.contains("tags: [work]") && u.contains("My notes after the call."), "note: user edits preserved")
    }

    private static func formatting() {
        check(Fmt.clock(3723.9) == "01:02:03", "fmt: clock")
        let min = { L.format("%ld min", $0) }, sec = { L.format("%ld s", $0) }, hour = { L.format("%ld h", $0) }
        check(Fmt.human(192) == min(3) + " " + sec(12) && Fmt.human(45) == sec(45) && Fmt.human(3600) == hour(1), "fmt: human")
        check(Fmt.fileSafe("Google Chrome: Meet/call") == "Google Chrome Meet call", "fmt: file-safe name")
    }

    /// Every translation must use the same format specifiers as its English key, or String(format:) misreads
    /// its arguments.
    private static func localization() {
        let bundled = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "uk")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/uk.lproj/Localizable.strings").standardizedFileURL.path
        guard let path = bundled ?? (FileManager.default.fileExists(atPath: source) ? source : nil),
              let table = NSDictionary(contentsOfFile: path) as? [String: String] else {
            check(false, "localization: uk.lproj/Localizable.strings found and readable")
            return
        }
        // Argument types in the order String(format:) reads them; "%2$@" names its position explicitly.
        let specifier = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(l{0,2}[@dDuUxXoOfeEgGcCsSp])|%%")
        func specifiers(_ s: String) -> [String] {
            let ns = s as NSString
            let found = specifier.matches(in: s, range: NSRange(location: 0, length: ns.length))
                .filter { $0.range(at: 2).location != NSNotFound }
            return found.enumerated().map { i, m -> (Int, String) in
                let position = m.range(at: 1).location == NSNotFound ? i + 1 : Int(ns.substring(with: m.range(at: 1))) ?? i + 1
                return (position, ns.substring(with: m.range(at: 2)))
            }.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let broken = table.filter { specifiers($0.key) != specifiers($0.value) }.map(\.key).sorted()
        check(!table.isEmpty && broken.isEmpty, "localization: \(table.count) uk strings keep their format specifiers"
              + (broken.isEmpty ? "" : " (broken: \(broken.joined(separator: ", ")))"))
    }

    /// Two synthetic parts with a gap and a pause between intervals must land at the right timeline positions.
    private static func render() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tapetum-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = HostTime.now()
        let s = HostTime.ticks
        let track = TrackRecorder(name: "mic", dir: dir)
        func tone(_ seconds: Double, rate: Double) -> [Float] {
            (0..<Int(seconds * rate)).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
        }
        // Interval 1: 0..3 s, tone at 0.5..1.5 s (48 kHz). Interval 2 after a 5 s pause: 8..10 s, tone 8..9 s (44.1 kHz).
        track.begin()
        track.append(tone(1.0, rate: 48000), host: t0 + s(0.5), rate: 48000)
        track.end()
        track.begin()
        track.append(tone(1.0, rate: 44100), host: t0 + s(8.0), rate: 44100)
        track.end()
        let tl = Timeline([Interval(start: t0, end: t0 + s(3)), Interval(start: t0 + s(8), end: t0 + s(10))])
        let parts = Parts.scan(dir, track: "mic")
        check(parts.count == 2, "render: two parts with sidecars on disk")
        do {
            let out = dir.appendingPathComponent("mic.m4a")
            let r = try Render.renderTrack(parts: parts, dir: dir, timeline: tl, out: out)
            check(abs(r.seconds - 4.0) < 0.05, String(format: "render: track is 4 s on the timeline (got %.2f)", r.seconds))
            check(r.loudestDB > -12, String(format: "render: tone is loud (%.1f dB)", r.loudestDB))
            let rms = windowRMS(out)
            // 0.0-0.5 silence, 0.5-1.5 tone, 1.5-3.0 silence, 3.0-4.0 tone (the second interval starts at 3 s)
            check(rms(0.1, 0.4) < 0.01, "render: silence before the first tone")
            check(rms(0.7, 1.3) > 0.2, "render: first tone at 0.5-1.5 s")
            check(rms(1.8, 2.8) < 0.01, "render: silence between tone and pause")
            check(rms(3.2, 3.8) > 0.2, "render: second tone right after the pause cut")
            // A quiet copy (-40 dB) must be raised to about -20 dB.
            let quiet = dir.appendingPathComponent("quiet.m4a")
            if let src = try? AVAudioFile(forReading: out),
               let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: AVAudioFrameCount(src.length)),
               let dst = try? AVAudioFile(forWriting: quiet, settings: Render.aacSettings(bitrate: 32000),
                                          commonFormat: .pcmFormatFloat32, interleaved: false) {
                try? src.read(into: buf)
                for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] *= 0.018 }
                try? dst.write(from: buf)
            }
            let q = windowRMS(quiet)(0.7, 1.3)
            let gain = try Render.normalize(quiet, loudestDB: 20 * log10(q))
            let after = windowRMS(quiet)(0.7, 1.3)
            check(gain > 15 && abs(20 * log10(after) - (-20)) < 2,
                  String(format: "render: quiet track raised by %.0f dB to %.1f dB", gain, 20 * log10(after)))
            check((try Render.normalize(out, loudestDB: -12)) == 0, "render: loud track left as is")
            let mixed = dir.appendingPathComponent("mix.m4a")
            let len = try Render.mix([out, out], out: mixed)
            check(abs(len - 4.0) < 0.1, "render: mix has the same length")
        } catch {
            check(false, "render: \(error)")
        }
    }

    private static func windowRMS(_ url: URL) -> (Double, Double) -> Double {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else {
            return { _, _ in -1 }
        }
        try? f.read(into: buf)
        let rate = f.processingFormat.sampleRate
        let data = buf.floatChannelData![0]
        let n = Int(buf.frameLength)
        return { a, b in
            let i0 = max(0, Int(a * rate)), i1 = min(n, Int(b * rate))
            guard i1 > i0 else { return 0 }
            var sum = 0.0
            for i in i0..<i1 { sum += Double(data[i] * data[i]) }
            return sqrt(sum / Double(i1 - i0))
        }
    }
}
