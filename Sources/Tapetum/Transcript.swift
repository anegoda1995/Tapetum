import Foundation

struct Seg {
    var start: Double
    var end: Double
    var text: String
    var speaker: String
    var doubtful: Bool
    var fromMic: Bool
}

struct TranscriptResult {
    var markdown: String
    var languages: [String]
    var speakers: [String]
    var echoDropped: Int
}

enum Transcript {
    static var me: String { L.string("Me") }

    static func segments(_ r: WhisperResponse?, fromMic: Bool, config: Config) -> [Seg] {
        guard let r else { return [] }
        let raw = r.segments ?? []
        // Name remote speakers in order of appearance; a single voice is simply "Them".
        var order: [String] = []
        for s in raw { let k = s.speaker ?? "?"; if !order.contains(k) { order.append(k) } }
        return raw.compactMap { s in
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let doubtful = (s.avg_logprob ?? 0) < config.lowConfidenceLogprob
                || (s.no_speech_prob ?? 0) > config.lowConfidenceNoSpeech
            let speaker: String
            if fromMic {
                speaker = me
            } else if order.count <= 1 {
                speaker = L.string("Them")
            } else {
                speaker = L.format("Speaker %ld", (order.firstIndex(of: s.speaker ?? "?") ?? 0) + 1)
            }
            return Seg(start: s.start, end: s.end, text: text, speaker: speaker, doubtful: doubtful, fromMic: fromMic)
        }
    }

    static func normalize(_ s: String) -> String {
        let scalars = s.lowercased().unicodeScalars.map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// Dice coefficient over character bigrams, 0...1.
    static func similarity(_ a: String, _ b: String) -> Double {
        func bigrams(_ s: String) -> Set<String> {
            let c = Array(s)
            guard c.count > 1 else { return [s] }
            return Set((0..<(c.count - 1)).map { String(c[$0]) + String(c[$0 + 1]) })
        }
        let x = bigrams(a), y = bigrams(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return 2 * Double(x.intersection(y).count) / Double(x.count + y.count)
    }

    /// Without headphones the mic hears the speakers. A mic phrase that repeats a remote phrase at the same time is echo.
    static func isEcho(_ m: Seg, among remote: [Seg]) -> Bool {
        let nm = normalize(m.text)
        guard nm.count >= 3 else { return false }
        for r in remote where m.start < r.end + 2.0 && r.start < m.end + 2.0 {
            let nr = normalize(r.text)
            if similarity(nm, nr) >= 0.55 { return true }
            if nm.count >= 8, nr.contains(nm) { return true }
        }
        return false
    }

    static func build(mic: [Seg], remote: [Seg], pauses: [(at: Double, length: Double)],
                      languages: [String: Double]) -> TranscriptResult {
        var kept = remote
        var dropped = 0
        for m in mic {
            if isEcho(m, among: remote) { dropped += 1 } else { kept.append(m) }
        }
        kept.sort { $0.start < $1.start }

        enum Item { case seg(Seg), pause(Double, Double) }
        var items: [(Double, Int, Item)] = kept.map { ($0.start, 1, .seg($0)) }
        items += pauses.map { ($0.at, 0, .pause($0.at, $0.length)) }
        items.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }

        var paragraphs: [String] = []
        var current: (speaker: String, start: Double, texts: [String])? = nil
        func flush() {
            if let c = current {
                paragraphs.append("**[\(Fmt.clock(c.start))] \(c.speaker):** " + c.texts.joined(separator: " "))
            }
            current = nil
        }
        for (_, _, item) in items {
            switch item {
            case .pause(_, let length):
                flush()
                paragraphs.append("*⏸ " + L.format("Paused, %@ not recorded.", Fmt.human(length)) + "*")
            case .seg(let s):
                let text = s.doubtful ? "\(s.text) " + L.string("[unclear?]") : s.text
                if current?.speaker == s.speaker {
                    current!.texts.append(text)
                } else {
                    flush()
                    current = (s.speaker, s.start, [text])
                }
            }
        }
        flush()

        var speakers: [String] = []
        for s in kept where !speakers.contains(s.speaker) { speakers.append(s.speaker) }
        let langs = languages.filter { $0.value >= 1 }.sorted { $0.value > $1.value }.map { $0.key }
        let body = paragraphs.isEmpty ? "*" + L.string("No speech found in the recording.") + "*" : paragraphs.joined(separator: "\n\n")
        return TranscriptResult(markdown: body, languages: langs, speakers: speakers, echoDropped: dropped)
    }
}

/// Obsidian note: frontmatter, embedded recording, transcript between invisible markers.
enum Note {
    static let startMarker = "%% tapetum:transcript:start %%"
    static let endMarker = "%% tapetum:transcript:end %%"
    static var placeholder: String {
        "> ⏳ " + L.string("Transcription in progress. If the Whisper server is offline, this note fills in by itself once it is back.")
    }

    static func yamlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func yamlList(_ items: [String]) -> String {
        "[" + items.map(yamlString).joined(separator: ", ") + "]"
    }

    static func initial(audioName: String, date: Date, duration: Double, app: String, notes: [String]) -> String {
        var s = """
        ---
        source: \(yamlString("[[\(audioName)]]"))
        date: \(Fmt.iso.string(from: date))
        duration: \(yamlString(Fmt.clock(duration)))
        app: \(yamlString(app))
        languages: []
        speakers: []
        ---
        ![[\(audioName)]]


        """
        for n in notes { s += "> \(n)\n\n" }
        s += "\(startMarker)\n\(placeholder)\n\(endMarker)\n"
        return s
    }

    /// Replaces only our block and our two frontmatter lines, so anything the user added stays.
    static func update(_ text: String, body: String, languages: [String], speakers: [String]) -> String {
        var out = text
        if let a = out.range(of: startMarker), let b = out.range(of: endMarker, range: a.upperBound..<out.endIndex) {
            out.replaceSubrange(a.upperBound..<b.lowerBound, with: "\n\(body)\n")
        } else {
            out += "\n\(startMarker)\n\(body)\n\(endMarker)\n"
        }
        var lines = out.components(separatedBy: "\n")
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            for i in 1..<close {
                if lines[i].hasPrefix("languages:") { lines[i] = "languages: [" + languages.joined(separator: ", ") + "]" }
                if lines[i].hasPrefix("speakers:") { lines[i] = "speakers: " + yamlList(speakers) }
            }
        }
        return lines.joined(separator: "\n")
    }
}
