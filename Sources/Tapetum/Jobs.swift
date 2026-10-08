import Foundation

/// After a recording: render the tracks, mix them into the notes folder, create the note, transcribe, fill the note.
/// Every step is persisted in the manifest, so an app restart or an offline server only delays it.
final class JobRunner {
    let config: Config
    private let whisper: WhisperClient
    private let queue = DispatchQueue(label: "tapetum.jobs")
    private let lock = NSLock()
    private var active = 0
    private var queued = Set<String>()
    /// Set when the server just did not answer: the other waiting recordings skip it until then (jobs queue only).
    private var offlineUntil = Date.distantPast
    var onChange: (() -> Void)?

    init(config: Config) {
        self.config = config
        whisper = WhisperClient(config: config)
    }

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return active > 0 }

    private var summaryCache: (at: Date, value: (count: Int, failed: Int, lastError: String?))?

    /// Recordings that still wait for the server, and the last error among them (cached for 30 s).
    func pendingSummary() -> (count: Int, failed: Int, lastError: String?) {
        lock.lock()
        if let c = summaryCache, Date().timeIntervalSince(c.at) < 30 { lock.unlock(); return c.value }
        lock.unlock()
        let value = scanSummary()
        lock.lock(); summaryCache = (Date(), value); lock.unlock()
        return value
    }

    private func scanSummary() -> (count: Int, failed: Int, lastError: String?) {
        var pending = 0, failed = 0
        var err: String?
        for dir in recordingDirs() {
            guard let m = Manifest.load(dir) else { continue }
            if m.status == .pending || m.status == .finalizing { pending += 1; err = m.lastError ?? err }
            if m.status == .failed { failed += 1; err = m.lastError ?? err }
        }
        return (pending, failed, err)
    }

    func recordingDirs() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: config.recordingsDir.path)) ?? []
        return names.sorted().map { config.recordingsDir.appendingPathComponent($0, isDirectory: true) }
    }

    /// On launch and on the retry timer: pick up everything unfinished. `includeFailed` for the menu's retry.
    func resumeAll(includeFailed: Bool = false, activeSessionID: String? = nil) {
        for dir in recordingDirs() {
            guard var m = Manifest.load(dir), m.id != activeSessionID else { continue }
            if m.status == .failed && includeFailed {
                m.status = m.noteFile == nil ? .finalizing : .pending
                m.lastError = nil
                m.save(dir)
            }
            if [.recording, .finalizing, .pending].contains(m.status) { submit(dir) }
        }
    }

    func submit(_ dir: URL) {
        lock.lock()
        if queued.contains(dir.path) { lock.unlock(); return }
        queued.insert(dir.path)
        lock.unlock()
        queue.async { [self] in
            lock.lock(); active += 1; lock.unlock()
            notify()
            process(dir)
            lock.lock(); active -= 1; queued.remove(dir.path); lock.unlock()
            notify()
        }
    }

    /// Synchronous variant for the CLI (--process).
    func processNow(_ dir: URL) { process(dir) }

    private func notify() {
        lock.lock(); summaryCache = nil; lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }

    private func process(_ dir: URL) {
        guard var m = Manifest.load(dir) else { return }
        if m.status == .recording {
            // The app stopped while recording: close the last interval at the last written sample.
            if let last = m.intervals.indices.last, m.intervals[last].end == 0 {
                m.intervals[last].end = max(m.intervals[last].start, Parts.lastSampleHost(dir))
            }
            m.status = .finalizing
            m.save(dir)
            Log.info("jobs: \(m.id) recovered after an unfinished recording")
        }
        if m.status == .finalizing {
            do { try finalize(&m, dir) } catch {
                m.status = .failed
                m.lastError = L.format("Could not assemble the audio: %@", error.localizedDescription)
                m.save(dir)
                Log.info("jobs: \(m.id) finalize failed: \(error)")
                return
            }
        }
        if m.status == .pending { transcribe(&m, dir) }
    }

    private func finalize(_ m: inout Manifest, _ dir: URL) throws {
        let timeline = Timeline(m.intervals)
        let total = timeline.total
        if total < config.minRecordingSec {
            Log.info(String(format: "jobs: %@ is only %.1f s, discarded", m.id, total))
            m.status = .discarded
            m.durationSec = total
            Parts.removeRaw(dir)
            m.save(dir)
            try? FileManager.default.removeItem(at: dir)
            return
        }
        let micParts = Parts.scan(dir, track: "mic")
        let sysParts = Parts.scan(dir, track: "sys")
        var tracks: [URL] = []
        var micSilent = true, sysSilent = true
        if !micParts.isEmpty {
            let r = try Render.renderTrack(parts: micParts, dir: dir, timeline: timeline, out: dir.appendingPathComponent("mic.m4a"))
            micSilent = r.loudestDB < config.silenceThresholdDB
            let gain = micSilent ? 0 : try Render.normalize(r.url, loudestDB: r.loudestDB)
            tracks.append(r.url)
            Log.info(String(format: "jobs: mic %.1f s, loudest %.1f dB%@", r.seconds, r.loudestDB,
                            gain > 0 ? String(format: ", raised %.0f dB", gain) : ""))
        }
        if !sysParts.isEmpty {
            let r = try Render.renderTrack(parts: sysParts, dir: dir, timeline: timeline, out: dir.appendingPathComponent("sys.m4a"))
            sysSilent = r.loudestDB < config.systemSilenceThresholdDB
            let gain = sysSilent ? 0 : try Render.normalize(r.url, loudestDB: r.loudestDB)
            tracks.append(r.url)
            Log.info(String(format: "jobs: sys %.1f s, loudest %.1f dB%@", r.seconds, r.loudestDB,
                            gain > 0 ? String(format: ", raised %.0f dB", gain) : ""))
        }

        let notesDir = URL(fileURLWithPath: config.notesDir, isDirectory: true)
        let audioDir = notesDir.appendingPathComponent(config.audioSubdir, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let base = uniqueBase("\(Fmt.fileDate.string(from: m.startDate)) \(Fmt.fileSafe(m.app))", notesDir: notesDir, audioDir: audioDir)
        let audioName = base + ".m4a"
        let noteName = base + ".md"
        let length = try Render.mix(tracks, out: audioDir.appendingPathComponent(audioName))

        var remarks: [String] = []
        if m.sysNoCallbacks == true {
            remarks.append("⚠️ " + L.format("The other side was not recorded: %@ seems to lack the System Audio Recording permission.", AppInfo.name))
        }
        let pauses = timeline.pauses
        if !pauses.isEmpty {
            let paused = pauses.reduce(0) { $0 + $1.length }
            remarks.append("⏸ " + L.format("Pauses: %ld, %@ not recorded in total.", pauses.count, Fmt.human(paused)))
        }
        let note = Note.initial(audioName: audioName, date: m.startDate, duration: max(total, length), app: m.app, notes: remarks)
        try note.write(to: notesDir.appendingPathComponent(noteName), atomically: true, encoding: .utf8)

        m.audioFile = audioName
        m.noteFile = noteName
        m.durationSec = total
        m.micSilent = micSilent
        m.sysSilent = sysSilent
        m.status = .pending
        Parts.removeRaw(dir)
        m.save(dir)
        Log.info("jobs: \(m.id) -> \(noteName) (\(Fmt.clock(total)))")
    }

    private func uniqueBase(_ base: String, notesDir: URL, audioDir: URL) -> String {
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: notesDir.appendingPathComponent(candidate + ".md").path)
                || FileManager.default.fileExists(atPath: audioDir.appendingPathComponent(candidate + ".m4a").path) {
            candidate = "\(base) (\(n))"
            n += 1
        }
        return candidate
    }

    private func transcribe(_ m: inout Manifest, _ dir: URL) {
        guard !config.serverURL.isEmpty else {
            if m.lastError == nil { Log.info("jobs: \(m.id) waits: no Whisper server set (serverURL in config.json)") }
            m.lastError = L.string("No Whisper server set (serverURL in config.json)")
            m.save(dir)
            return
        }
        // Fail fast while the server is off, so a new call's note is not stuck behind waiting uploads.
        if Date() < offlineUntil || !whisper.reachable() {
            if Date() >= offlineUntil { offlineUntil = Date().addingTimeInterval(60) }
            m.attempts += 1
            m.lastError = WhisperError.offline(L.string("no answer")).localizedDescription
            m.save(dir)
            Log.info("jobs: \(m.id) transcription: Whisper server does not answer, will retry")
            return
        }
        let micURL = dir.appendingPathComponent("mic.m4a")
        let sysURL = dir.appendingPathComponent("sys.m4a")
        var micResp: WhisperResponse?
        var sysResp: WhisperResponse?
        // Both tracks go to the server at the same time; the slower one decides how long it takes.
        let group = DispatchGroup()
        let lock = NSLock()
        var firstError: Error?
        let started = Date()
        func run(_ url: URL, diarize: Bool, _ store: @escaping (WhisperResponse) -> Void) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do { let r = try self.whisper.transcribe(url, diarize: diarize); lock.lock(); store(r); lock.unlock() }
                catch { lock.lock(); if firstError == nil { firstError = error }; lock.unlock() }
            }
        }
        if m.micSilent == false, FileManager.default.fileExists(atPath: micURL.path) {
            run(micURL, diarize: false) { micResp = $0 }
        }
        if m.sysSilent == false, FileManager.default.fileExists(atPath: sysURL.path) {
            run(sysURL, diarize: config.diarize) { sysResp = $0 }
        }
        group.wait()
        Log.info(String(format: "jobs: %@ both tracks transcribed in parallel, %.1f s", m.id, Date().timeIntervalSince(started)))
        do {
            if let e = firstError { throw e }
        } catch let e as WhisperError {
            m.attempts += 1
            m.lastError = e.localizedDescription
            if !e.retryable { m.status = .failed }
            m.save(dir)
            Log.info("jobs: \(m.id) transcription: \(e.localizedDescription)\(e.retryable ? ", will retry" : "")")
            return
        } catch {
            m.attempts += 1
            m.lastError = error.localizedDescription
            m.save(dir)
            return
        }

        var languages: [String: Double] = [:]
        for r in [micResp, sysResp].compactMap({ $0 }) {
            if let perLanguage = r.language_seconds {
                for (k, v) in perLanguage { languages[k, default: 0] += v }
            } else if let lang = r.language, !lang.isEmpty {
                languages[lang, default: 0] += r.duration ?? 1
            }
        }
        let result = Transcript.build(
            mic: Transcript.segments(micResp, fromMic: true, config: config),
            remote: Transcript.segments(sysResp, fromMic: false, config: config),
            pauses: Timeline(m.intervals).pauses,
            languages: languages)

        guard let noteFile = m.noteFile else { return }
        let noteURL = URL(fileURLWithPath: config.notesDir).appendingPathComponent(noteFile)
        guard let text = try? String(contentsOf: noteURL, encoding: .utf8) else {
            Log.info("jobs: \(m.id) note \(noteFile) is gone (deleted by the user?), transcript not written")
            m.status = .done
            m.save(dir)
            return
        }
        let updated = Note.update(text, body: result.markdown, languages: result.languages, speakers: result.speakers)
        do {
            try updated.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            m.lastError = L.format("Could not write the note: %@", error.localizedDescription)
            m.save(dir)
            return
        }
        m.status = .done
        m.lastError = nil
        m.save(dir)
        Log.info("jobs: \(m.id) transcribed, \(result.speakers.joined(separator: ", ")), echo dropped \(result.echoDropped)")
    }
}
