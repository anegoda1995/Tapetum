import Foundation
import Darwin

/// Timestamped logging to stdout. Under the LaunchAgent stdout goes to ~/Library/Logs/Tapetum.log.
enum Log {
    private static let queue = DispatchQueue(label: "tapetum.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let date = Date()
        queue.async {
            print("\(formatter.string(from: date)) \(message)")
            fflush(stdout)
        }
    }

    static func flush() { queue.sync {} }
}

/// Text shown in the menu and written into notes. The English text is the key; Resources/uk.lproj translates it.
enum L {
    static func string(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    static func format(_ key: String, _ args: CVarArg...) -> String { String(format: string(key), arguments: args) }
}

/// mach_absolute_time helpers. Host times are only compared with each other inside one recording.
enum HostTime {
    static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    static func now() -> UInt64 { mach_absolute_time() }

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// a - b in seconds, may be negative.
    static func diff(_ a: UInt64, _ b: UInt64) -> Double {
        a >= b ? seconds(a - b) : -seconds(b - a)
    }
}

struct Config {
    /// OpenAI-compatible transcription server: POST <serverURL>/v1/audio/transcriptions. Empty: recordings are
    /// kept with their notes and wait until a server is set; audio never goes anywhere by default.
    var serverURL = ""
    var model = "whisper-1"
    /// Ask the server to split the remote track by speaker. Not part of the OpenAI API, so off by default.
    var diarize = false
    /// The API key is a generic password in the login Keychain. Without one, requests go out without a key.
    var keychainService = AppInfo.name
    var keychainAccount = "whisper"
    var notesDir = NSHomeDirectory() + "/Documents/Tapetum"
    var audioSubdir = "audio"
    /// Processes that use the microphone but are not calls (dictation, Siri).
    var ignoreBundlePrefixes = [
        "com.apple.SpeechRecognitionCore", "com.apple.siri", "com.apple.assistant", "com.apple.corespeech",
        "com.apple.dictation", AppInfo.bundleID,
    ]
    var ignoreProcessNames = [
        "corespeechd", "assistantd", "SiriNCService", "Siri", "localspeechrecognition", "DictationIM",
        "speechrecognitiond", AppInfo.name,
    ]
    /// Mic users matched by a fragment of their executable path, for tools whose process name changes.
    var ignorePathFragments: [String] = []
    /// Apps left out of the system audio tap. A tool that replays other apps' sound and mutes the originals
    /// would otherwise be recorded twice, a few milliseconds apart.
    var tapExcludeBundlePrefixes: [String] = []
    /// 0: start the moment an app opens the mic. Short false starts are dropped later (minRecordingSec).
    var startDelaySec = 0.0
    /// The mic was released and the calling app also stopped playing sound: the call is over after this long.
    var endGraceSec = 5.0
    /// The mic was released but the calling app still plays sound (you muted yourself): keep recording this long.
    var mutedMaxSec = 1200.0
    /// Apple voice processing (echo cancellation) on the mic for every new call. Off by default: while it runs, macOS
    /// switches the built-in mic into its voice processing mode and every other app recording that mic gets a signal
    /// about 40 dB quieter (voice messages, dictation, calls that do not use voice processing themselves). The menu
    /// turns it on for one call; echo the mic picks up from the speakers is dropped from the transcript either way.
    var voiceMode = false
    /// With voice mode: system audio and a plain mic ("bridge") start at once; voice processing takes over when ready.
    var fastStart = true
    var minRecordingSec = 20.0
    var retryIntervalSec = 600.0
    var lowConfidenceLogprob = -0.8
    var lowConfidenceNoSpeech = 0.6
    /// A track whose loudest 1 s window is quieter than this is not sent to Whisper (it only invents text on silence).
    var silenceThresholdDB = -40.0
    /// The remote track is digital: real silence is exactly zero, so only near-zero counts as silence.
    var systemSilenceThresholdDB = -65.0

    var home: URL
    var testSystemFile: String?
    /// Test hook TAPETUM_TEST_STALL_SYS=<seconds>: the remote track stops receiving audio after that many
    /// seconds of its first part, like a frozen tap, so the watchdog can be tested.
    var testStallSysAfter: Double?
    var apiKeyOverride: String?
    var isTestMode = false

    var recordingsDir: URL { home.appendingPathComponent("recordings", isDirectory: true) }
    var statusFile: URL { home.appendingPathComponent("status.json") }
    var prefsFile: URL { home.appendingPathComponent("prefs.json") }
    var configFile: URL { home.appendingPathComponent("config.json") }

    static func load() -> Config {
        let env = ProcessInfo.processInfo.environment
        let home: URL
        if let h = env["TAPETUM_HOME"], !h.isEmpty {
            home = URL(fileURLWithPath: h, isDirectory: true)
        } else {
            home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(AppInfo.name, isDirectory: true)
        }
        var c = Config(home: home)
        c.isTestMode = env["TAPETUM_HOME"] != nil

        if let data = try? Data(contentsOf: c.configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = json["serverURL"] as? String { c.serverURL = v }
            if let v = json["model"] as? String { c.model = v }
            if let v = json["diarize"] as? Bool { c.diarize = v }
            if let v = json["keychainService"] as? String { c.keychainService = v }
            if let v = json["keychainAccount"] as? String { c.keychainAccount = v }
            if let v = json["notesDir"] as? String { c.notesDir = (v as NSString).expandingTildeInPath }
            if let v = json["ignoreBundlePrefixes"] as? [String] { c.ignoreBundlePrefixes += v }
            if let v = json["ignoreProcessNames"] as? [String] { c.ignoreProcessNames += v }
            if let v = json["ignorePathFragments"] as? [String] { c.ignorePathFragments += v }
            if let v = json["tapExcludeBundlePrefixes"] as? [String] { c.tapExcludeBundlePrefixes += v }
            if let v = json["startDelaySec"] as? Double { c.startDelaySec = v }
            if let v = json["endGraceSec"] as? Double { c.endGraceSec = v }
            if let v = json["mutedMaxSec"] as? Double { c.mutedMaxSec = v }
            if let v = json["voiceMode"] as? Bool { c.voiceMode = v }
            if let v = json["fastStart"] as? Bool { c.fastStart = v }
            if let v = json["minRecordingSec"] as? Double { c.minRecordingSec = v }
            if let v = json["retryIntervalSec"] as? Double { c.retryIntervalSec = v }
            if let v = json["silenceThresholdDB"] as? Double { c.silenceThresholdDB = v }
            if let v = json["systemSilenceThresholdDB"] as? Double { c.systemSilenceThresholdDB = v }
        }

        // Test hooks
        if let v = env["TAPETUM_NOTES_DIR"], !v.isEmpty { c.notesDir = v }
        if let v = env["TAPETUM_TEST_SYSTEM_FILE"], !v.isEmpty { c.testSystemFile = v }
        if let v = env["TAPETUM_WHISPER_KEY"], !v.isEmpty { c.apiKeyOverride = v }
        if let v = env["TAPETUM_STOP_GRACE"], let d = Double(v) { c.endGraceSec = d }
        if let v = env["TAPETUM_MUTED_MAX"], let d = Double(v) { c.mutedMaxSec = d }
        if let v = env["TAPETUM_FAST_START"] { c.fastStart = v == "1" }
        if let v = env["TAPETUM_MIN_SEC"], let d = Double(v) { c.minRecordingSec = d }
        if let v = env["TAPETUM_START_DELAY"], let d = Double(v) { c.startDelaySec = d }
        if let v = env["TAPETUM_TEST_STALL_SYS"], let d = Double(v) { c.testStallSysAfter = d }

        try? FileManager.default.createDirectory(at: c.recordingsDir, withIntermediateDirectories: true)
        return c
    }
}

/// Small persisted preferences (auto recording on/off).
struct Prefs: Codable {
    var autoRecord = true

    static func load(_ config: Config) -> Prefs {
        guard let data = try? Data(contentsOf: config.prefsFile),
              let p = try? JSONDecoder().decode(Prefs.self, from: data) else { return Prefs() }
        return p
    }

    func save(_ config: Config) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: config.prefsFile, options: .atomic) }
    }
}

enum Fmt {
    /// 83.4 -> "00:01:23"
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// 192 -> "3 min 12 s"
    static func human(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        var parts: [String] = []
        if h > 0 { parts.append(L.format("%ld h", h)) }
        if m > 0 { parts.append(L.format("%ld min", m)) }
        if sec > 0 || parts.isEmpty { parts.append(L.format("%ld s", sec)) }
        return parts.joined(separator: " ")
    }

    /// Short elapsed for the menu: "12:34" or "1:02:03"
    static func elapsed(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func fileSafe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        let cleaned = name.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(separator: " ").joined(separator: " ")
        return collapsed.isEmpty ? L.string("Call") : collapsed
    }

    static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()
}

enum Shell {
    /// Runs a tool and returns trimmed stdout, or nil on non-zero exit.
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
