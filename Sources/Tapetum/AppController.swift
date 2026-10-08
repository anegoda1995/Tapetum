import AppKit
import AVFoundation

/// One call being recorded. Capture closures hold on to it, so it can be finished after the UI moved on.
final class Session {
    var manifest: Manifest
    let dir: URL
    let auto: Bool
    let micTrack: TrackRecorder
    let sysTrack: TrackRecorder
    /// Plain mic that covers the first moments while voice processing starts (part of the mic track).
    let bridgeTrack: TrackRecorder
    let system: AudioSource
    /// Apps taking part in the call (outermost .app or executable), to know whether they still play sound.
    var appKeys = Set<String>()
    /// When the call app was first seen using the mic; latency is measured from here.
    var detectedHost: UInt64 = HostTime.now()
    /// The mic the call app uses, recorded as your side (nil: the default input).
    var micDevice: AudioObjectID?
    var voiceActual = true
    /// The call app let go of the mic (you muted yourself, a voice message ended), so ours is released too and only
    /// the other side is recorded until the app takes the mic again.
    var micParked = false
    var micProblem: String?
    var sysProblem: String?
    var sysNoCallbacks = false
    /// Watchdog: last seen buffer count, when it last grew, when the track was last (re)started.
    var micWatch = Watch()
    var sysWatch = Watch()

    struct Watch {
        var total = 0
        var progressAt = Date()
        var restartedAt = Date()
    }

    init(manifest: Manifest, dir: URL, auto: Bool, system: AudioSource) {
        self.manifest = manifest
        self.dir = dir
        self.auto = auto
        self.system = system
        micTrack = TrackRecorder(name: "mic", dir: dir)
        sysTrack = TrackRecorder(name: "sys", dir: dir)
        bridgeTrack = TrackRecorder(name: "mic", dir: dir, prefix: "mic_b")
    }

    func save() { manifest.save(dir) }
}

/// Menu bar item, call detection and the recording state machine.
/// State lives on the main thread; starting and stopping audio runs on one serial capture queue,
/// and its results come back to the main thread in the same order.
final class AppController: NSObject, NSMenuDelegate {
    enum State { case idle, recording, paused }

    private let config: Config
    private var prefs: Prefs
    private let jobs: JobRunner
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let deviceWatcher = DeviceWatcher()
    private let captureQueue = DispatchQueue(label: "tapetum.capture", qos: .userInitiated)
    private let mic = MicCapture()
    private let bridge = CaptureBridge()
    private let bridgeQueue = DispatchQueue(label: "tapetum.bridge", qos: .userInitiated)
    private var bridgeActive = false
    private let processWatcher = ProcessWatcher()
    private var timer: Timer?
    private var retryTimer: Timer?
    private let ownPID = getpid()

    private(set) var state: State = .idle
    private var session: Session?
    /// Voice mode wanted for the current call; every new call starts with config.voiceMode.
    private var voiceMode: Bool
    private var usersSince: Date?
    private var usersSinceHost: UInt64 = 0
    private var idleSince: Date?
    private var idleSinceHost: UInt64 = 0
    private var silentSince: Date?
    private var silentSinceHost: UInt64 = 0
    /// How long the call app has to stay off the mic before ours is released too. Shorter gaps are device
    /// reconfigurations (another app's voice processing starting), not the user muting.
    private let micReleaseDelaySec = 2.0

    init(config: Config) {
        self.config = config
        voiceMode = config.voiceMode
        prefs = Prefs.load(config)
        jobs = JobRunner(config: config)
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        statusItem.autosaveName = AppInfo.name   // macOS remembers where the user drags it (cmd+drag)
        statusItem.button?.image = EyeIcon.closed.image
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // No restart on the bridge's own device notifications: reopening the mic while voice processing
        // initializes left voice processing broken (3 channels, no audio) in tests.
        processWatcher.onChange = { [weak self] in self?.evaluate() }
        processWatcher.start()
        jobs.onChange = { [weak self] in self?.refresh() }
        mic.onConfigChange = { [weak self] in self?.micConfigChanged() }
        deviceWatcher.onOutputChange = { [weak self] in self?.requestRestart("output device changed") }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.requestRestart("woke from sleep")
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteCommand(_:)), name: AppInfo.controlNotification,
            object: nil, suspensionBehavior: .deliverImmediately)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        retryTimer = Timer.scheduledTimer(withTimeInterval: config.retryIntervalSec, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.jobs.resumeAll(activeSessionID: self.session?.manifest.id)
        }
        jobs.resumeAll()
        requestPermissions()
        warmUpAudio()
        refresh()
        Log.info("\(AppInfo.name) started (pid \(ownPID)), auto recording \(prefs.autoRecord ? "on" : "off"), "
                 + "notes \(config.notesDir), server \(config.serverURL), voice mode \(config.voiceMode ? "on" : "off"), "
                 + "fast start \(config.fastStart)")
        evaluate()
    }

    /// Called on quit: close the files so the recording can be finished at the next launch.
    func shutdown() {
        if let s = session {
            let wasRecording = state == .recording
            let mic = self.mic
            captureQueue.sync {
                if wasRecording {
                    mic.stop()
                    self.stopBridge(s)
                    s.system.stop()
                    s.micTrack.end()
                    s.sysTrack.end()
                    if let last = s.manifest.intervals.indices.last { s.manifest.intervals[last].end = HostTime.now() }
                }
                s.manifest.status = .finalizing
                s.save()
            }
            Log.info("session: \(s.manifest.id) closed on quit, will be finished at next launch")
        }
        Log.flush()
    }

    /// Ask for both permissions at launch, so the prompts do not pop up in the middle of a call.
    private func requestPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("permission: microphone \(granted ? "granted" : "denied")")
                if granted {
                    DispatchQueue.global(qos: .utility).async {
                        if CaptureBridge.warmUp() { Log.info("warm-up: mic input ready") }
                    }
                }
                DispatchQueue.main.async { self.refresh() }
            }
        }
        guard !config.isTestMode else { return }
        let status = SystemAudioPermission.status()
        Log.info("permission: system audio \(status)")
        if status != .authorized {
            SystemAudioPermission.request { granted in
                Log.info("permission: system audio \(granted ? "granted" : "not granted")")
                DispatchQueue.main.async { self.refresh() }
            }
        }
    }

    /// The first audio component lookup in a process waits for the system's component registry, which rescans
    /// after apps were installed or updated (1-2 s), and the first capture input is slow as well
    /// (CaptureBridge.warmUp). Done at the first call, both held the mic bridge back and the first call after a launch
    /// lost its first words. Pay them at launch instead. Opens no mic.
    private func warmUpAudio() {
        DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            var any = AudioComponentDescription()
            let count = AudioComponentCount(&any)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tapetum-warmup-\(getpid()).caf")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000.0,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            _ = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try? FileManager.default.removeItem(at: url)
            let input = CaptureBridge.warmUp()
            Log.info(String(format: "warm-up: %d audio components, track writer%@ ready in %.0f ms", count,
                            input ? " and mic input" : " (mic input waits for the permission)", Date().timeIntervalSince(t0) * 1000))
        }
    }

    // MARK: - Detection

    private func tick() {
        if state == .recording { watchdog(Date()) }
        evaluate()
        refresh()
    }

    /// Runs on every Core Audio process event and once a second.
    private func evaluate() {
        let now = Date()
        switch state {
        case .idle:
            guard prefs.autoRecord else { usersSince = nil; return }
            let users = AudioProcesses.inputUsers(excluding: ownPID, config: config)
            if users.isEmpty { usersSince = nil; return }
            if usersSince == nil {
                usersSince = now
                usersSinceHost = HostTime.now()
            }
            if now.timeIntervalSince(usersSince!) >= config.startDelaySec {
                startSession(app: AudioProcesses.displayName(users), auto: true, users: users, detectedHost: usersSinceHost)
            }
        case .recording, .paused:
            guard let s = session, s.auto else { return }
            let users = AudioProcesses.inputUsers(excluding: ownPID, config: config)
            if !users.isEmpty {
                for u in users { s.appKeys.insert(AudioProcesses.appKey(u.pid)) }
                let dev = AudioProcesses.micDevice(of: users)
                if s.micParked {
                    if let dev { s.micDevice = dev }
                    if state == .recording { unparkMic(s) }
                } else if let dev, dev != (s.micDevice ?? CA.defaultInputDevice()) {
                    // The call app moved to another mic (a headset plugged in mid-call): record that one from now on.
                    Log.info("detect: the call app now uses the mic \(AudioProcesses.deviceName(dev)), the mic track follows")
                    s.micDevice = dev
                    requestRestart("call app switched its microphone")
                }
                if idleSince != nil {
                    idleSince = nil
                    silentSince = nil
                    Log.info("detect: microphone is used again, recording continues")
                }
                return
            }
            if idleSince == nil {
                idleSince = now
                idleSinceHost = HostTime.now()
                Log.info("detect: microphone released")
            }
            if !s.micParked, state == .recording, now.timeIntervalSince(idleSince!) >= micReleaseDelaySec { parkMic(s) }
            // Still playing sound = still in the call (you are muted): keep going for a while.
            let playing = !AudioProcesses.outputApps(excluding: ownPID).isDisjoint(with: s.appKeys)
            if playing {
                if silentSince != nil { silentSince = nil }
                if now.timeIntervalSince(idleSince!) >= config.mutedMaxSec {
                    Log.info("detect: mic released \(Int(config.mutedMaxSec)) s ago, the app still plays sound; stopping")
                    stopSession(trimTo: nil)
                }
            } else {
                if silentSince == nil {
                    silentSince = now
                    silentSinceHost = HostTime.now()
                    Log.info("detect: the call app is silent too, stopping in \(Int(config.endGraceSec)) s unless it comes back")
                } else if now.timeIntervalSince(silentSince!) >= config.endGraceSec {
                    stopSession(trimTo: silentSinceHost)
                }
            }
        }
    }

    /// Audio can stop arriving without any error: a voice processing restart or a device change can freeze
    /// the system audio tap, sleep can stop the engine. If a track gets no buffers for 4 s, restart it.
    private func watchdog(_ now: Date) {
        guard let s = session else { return }
        func check(_ w: inout Session.Watch, _ track: TrackRecorder, _ label: String) -> Bool {
            let total = track.totalBuffers
            if total != w.total {
                w.total = total
                w.progressAt = now
                return false
            }
            guard now.timeIntervalSince(w.progressAt) > 4, now.timeIntervalSince(w.restartedAt) > 8 else { return false }
            Log.info("watchdog: \(label) got no audio for \(Int(now.timeIntervalSince(w.progressAt))) s, restarting it")
            w.restartedAt = now
            w.progressAt = now
            return true
        }
        // While the bridge covers the mic, voice processing is looked after by the handover monitor.
        let micStalled = !bridgeActive && !s.micParked && check(&s.micWatch, s.micTrack, "mic")
        let watchSys = !(s.system is FileSource) || config.testStallSysAfter != nil
        let sysStalled = watchSys && check(&s.sysWatch, s.sysTrack, "sys")
        if micStalled || sysStalled { requestRestart("watchdog") }
    }

    private func resetWatch(_ s: Session) {
        let now = Date()
        s.micWatch = Session.Watch(total: s.micTrack.totalBuffers, progressAt: now, restartedAt: now)
        s.sysWatch = Session.Watch(total: s.sysTrack.totalBuffers, progressAt: now, restartedAt: now)
    }

    // MARK: - Session

    private func startSession(app: String, auto: Bool, users: [MicUser] = [], detectedHost: UInt64? = nil) {
        guard state == .idle else { return }
        let started = Date()
        let idFmt = DateFormatter()
        idFmt.locale = Locale(identifier: "en_US_POSIX")
        idFmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let id = idFmt.string(from: started)
        let dir = config.recordingsDir.appendingPathComponent(id, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            Log.info("session: cannot create \(dir.path): \(error)")
            return
        }
        let system: AudioSource
        if let path = config.testSystemFile, let fs = try? FileSource(path: path) {
            system = fs
        } else {
            let tap = SystemTapCapture()
            tap.excludedBundlePrefixes = config.tapExcludeBundlePrefixes
            system = tap
        }
        voiceMode = config.voiceMode
        var m = Manifest(id: id, app: app, startDate: started)
        m.voiceModeAtStart = voiceMode
        let s = Session(manifest: m, dir: dir, auto: auto, system: system)
        s.voiceActual = voiceMode
        s.sysTrack.stallAfter = config.testStallSysAfter
        s.detectedHost = detectedHost ?? HostTime.now()
        for u in users { s.appKeys.insert(AudioProcesses.appKey(u.pid)) }
        s.micDevice = AudioProcesses.micDevice(of: users)
        let t0 = s.detectedHost
        func latency(_ label: String) -> (UInt64) -> Void {
            return { host in Log.info(String(format: "latency: %@ first audio %+.0f ms after the call opened the mic", label,
                                             HostTime.diff(host, t0) * 1000)) }
        }
        s.micTrack.onFirstBuffer = latency(voiceMode ? "mic (voice processing)" : "mic")
        s.bridgeTrack.onFirstBuffer = latency("mic (bridge)")
        s.sysTrack.onFirstBuffer = latency("system audio")
        s.save()
        session = s
        state = .recording
        idleSince = nil
        silentSince = nil
        usersSince = nil
        let who = users.map { "\($0.executable)[\($0.pid)] \($0.bundleID)" }.joined(separator: ", ")
        Log.info("session: \(id) started (\(auto ? "auto" : "manual")) for \(app)\(who.isEmpty ? "" : ": " + who), "
                 + "mic \(AudioProcesses.deviceName(s.micDevice ?? CA.defaultInputDevice()))")
        beginInterval(s)
        refresh()
    }

    /// Starts capturing into new parts. The interval start is taken on the capture queue, so it can never
    /// be earlier than the end of the previous interval.
    /// Fast start (voice mode): the system audio tap and a plain "bridge" mic start at once (tens of ms); voice
    /// processing (0.7-2 s) takes over the mic when it delivers audio. If the tap froze while voice processing
    /// started, it is restarted right away.
    private func beginInterval(_ s: Session) {
        resetWatch(s)
        lastRestartAt = Date()   // voice processing start sends its own "device changed": not a reason to restart
        let mic = self.mic
        let voice = voiceMode
        // Only voice processing needs the bridge: in plain mode the mic is a capture session already.
        let fast = config.fastStart && voice
        let device = s.micDevice
        let parked = s.micParked
        captureQueue.async { [weak self] in
            guard let self else { return }
            mic.inputDevice = device
            let start = HostTime.now()
            DispatchQueue.main.async {
                s.manifest.intervals.append(Interval(start: start, end: 0))
                s.save()
            }
            if parked {
                // Resumed while the call app is still off the mic: the other side only, the mic follows the app.
                s.sysTrack.begin()
                self.startSystemOnQueue(s)
                return
            }
            s.micTrack.begin()
            s.sysTrack.begin()
            guard fast else {
                // Voice processing has to start before the tap (started under a running tap, it freezes it);
                // a plain mic does not mind, so then the other side starts first.
                if voice {
                    self.startMicOnQueue(s, mic: mic, voice: true)
                    self.startSystemOnQueue(s)
                } else {
                    self.startSystemOnQueue(s)
                    self.startMicOnQueue(s, mic: mic, voice: false)
                }
                return
            }
            self.startSystemOnQueue(s)
            self.startBridge(s)
            let sysBefore = s.sysTrack.totalBuffers
            self.startMicOnQueue(s, mic: mic, voice: true)
            // The bridge stays until voice processing really delivers audio; the monitor also revives it.
            self.startHandoverMonitor(s)
            // Voice processing may have frozen the tap that was already running: check and restart it.
            Thread.sleep(forTimeInterval: 0.25)
            if !(s.system is FileSource), s.sysTrack.totalBuffers == sysBefore || !self.sysFlowing(s, within: 0.25) {
                Log.info("capture: system audio stalled after voice processing started, restarting the tap")
                s.system.stop()
                s.sysTrack.end()
                s.sysTrack.begin()
                self.startSystemOnQueue(s)
            }
            DispatchQueue.main.async { self.lastRestartAt = Date() }
        }
    }

    /// True if the system track received buffers within the given time (checked on the capture queue).
    private func sysFlowing(_ s: Session, within seconds: Double) -> Bool {
        let before = s.sysTrack.totalBuffers
        Thread.sleep(forTimeInterval: seconds)
        return s.sysTrack.totalBuffers > before
    }

    private let handoverQueue = DispatchQueue(label: "tapetum.handover")

    /// Watches the handover from the bridge to voice processing: stops the bridge as soon as voice processing
    /// writes audio, and kicks voice processing (stop/start, then recover) when it stays silent for 1.5 s.
    private func startHandoverMonitor(_ s: Session) {
        let mic = self.mic
        handoverQueue.async { [weak self] in
            var lastKick = Date()
            let started = Date()
            while let self, self.bridgeActive {
                if s.micTrack.stats.buffers > 0 {
                    Log.info(String(format: "capture: voice processing took over from the bridge after %.0f ms",
                                    Date().timeIntervalSince(started) * 1000))
                    self.stopBridge(s)
                    return
                }
                if Date().timeIntervalSince(lastKick) > 1.5 {
                    lastKick = Date()
                    self.captureQueue.async {
                        if !mic.isRunning { _ = mic.recover() } else { mic.kick() }
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func startBridge(_ s: Session) {
        bridgeQueue.sync {
            bridgeActive = true
            bridge.inputDevice = s.micDevice
            s.bridgeTrack.begin()
            bridge.sink = { samples, host, rate in s.bridgeTrack.append(samples, host: host, rate: rate) }
            do { try bridge.start() } catch { Log.info("bridge: \(error.localizedDescription)") }
        }
    }

    private func stopBridge(_ s: Session) {
        bridgeQueue.sync {
            guard bridgeActive else { return }
            bridgeActive = false
            bridge.stop()
            s.bridgeTrack.end()
        }
    }

    /// Stops capturing; `then` runs on the main thread after the files are closed.
    private func endInterval(_ s: Session, then: (() -> Void)? = nil) {
        let mic = self.mic
        captureQueue.async { [weak self] in
            self?.stopBridge(s)
            mic.stop()
            s.system.stop()
            s.micTrack.end()
            s.sysTrack.end()
            let end = HostTime.now()
            DispatchQueue.main.async {
                if let last = s.manifest.intervals.indices.last, s.manifest.intervals[last].end == 0 {
                    s.manifest.intervals[last].end = end
                }
                s.save()
                then?()
            }
        }
    }

    private func startMicOnQueue(_ s: Session, mic: MicCapture, voice: Bool) {
        let track = s.micTrack
        mic.voiceMode = voice
        mic.sink = { samples, host, rate in track.append(samples, host: host, rate: rate) }
        var actual = voice
        var problem: String?
        do {
            try mic.start()
        } catch {
            if voice {
                Log.info("mic: voice mode failed (\(error.localizedDescription)), falling back to plain mic")
                mic.stop()
                mic.voiceMode = false
                actual = false
                problem = L.string("Voice mode did not start, recording the plain microphone")
                do { try mic.start() } catch { problem = L.format("Microphone is not recording: %@", error.localizedDescription) }
            } else {
                problem = L.format("Microphone is not recording: %@", error.localizedDescription)
            }
        }
        DispatchQueue.main.async { [weak self] in
            s.voiceActual = actual
            s.micProblem = problem
            if actual != voice, self?.session === s { self?.voiceMode = actual }
            self?.checkHealth(s, track, label: "mic")
            self?.refresh()
        }
    }

    private func startSystemOnQueue(_ s: Session) {
        let track = s.sysTrack
        s.system.sink = { samples, host, rate in track.append(samples, host: host, rate: rate) }
        var problem: String?
        do { try s.system.start() } catch {
            problem = L.format("The other side is not recording: %@", error.localizedDescription)
            Log.info("system: \(error.localizedDescription)")
        }
        DispatchQueue.main.async { [weak self] in
            s.sysProblem = problem
            self?.checkHealth(s, track, label: "sys")
        }
    }

    /// A few seconds after a start, make sure buffers actually arrive (no buffers = no permission).
    private func checkHealth(_ s: Session, _ track: TrackRecorder, label: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.session === s, self.state == .recording else { return }
            let stats = track.stats
            Log.info(String(format: "health: %@ %d buffers, peak %.4f", label, stats.buffers, stats.peak))
            if stats.buffers == 0 {
                if label == "mic" {
                    s.micProblem = L.string("Microphone is not recording: no microphone permission?")
                } else {
                    s.sysProblem = L.string("The other side is not recording: no System Audio Recording permission?")
                    s.sysNoCallbacks = true
                }
            } else if label == "sys" {
                s.sysNoCallbacks = false
            }
            self.refresh()
        }
    }

    /// A device change stopped the mic engine: start the same engine again (soft), a full restart only if that
    /// fails. The watchdog still catches a mic that runs but delivers nothing.
    private func micConfigChanged() {
        guard state == .recording, let s = session, !s.micParked else { return }
        let mic = self.mic
        captureQueue.async { [weak self] in
            Thread.sleep(forTimeInterval: 0.1)
            if mic.isRunning { return }
            if !mic.recover() {
                DispatchQueue.main.async { self?.requestRestart("mic engine could not restart") }
            } else {
                DispatchQueue.main.async { if self?.session === s { self?.resetWatch(s) } }
            }
        }
    }

    private var restartPending = false
    private var lastRestartAt = Date.distantPast

    /// Every capture problem (voice mode toggle, device change, wake, watchdog) ends in one coordinated
    /// restart of both tracks, at most once per 2 s. Bursts of device notifications collapse into one.
    private func requestRestart(_ reason: String, fromConfigChange: Bool = false) {
        guard state == .recording, let s = session else { return }
        if fromConfigChange, Date().timeIntervalSince(lastRestartAt) < 3, mic.isRunning {
            Log.info("capture: device notification right after a restart ignored, the mic is running")
            return
        }
        guard !restartPending else { return }
        restartPending = true
        let wait = max(fromConfigChange ? 0.5 : 0, 2 - Date().timeIntervalSince(lastRestartAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            guard self.state == .recording, self.session === s else { return }
            self.lastRestartAt = Date()
            self.restartCaptures(s, reason: reason)
        }
    }

    /// Safe order: stop both, let the device list settle, then mic (voice processing) and only then the tap.
    /// Voice processing started under a running tap freezes the tap; an aggregate device destroyed under a
    /// running voice processing engine makes the engine reconfigure. Both were seen in live tests.
    private func restartCaptures(_ s: Session, reason: String) {
        Log.info("capture: restart (\(reason))")
        resetWatch(s)
        let mic = self.mic
        let voice = voiceMode
        let device = s.micDevice
        let parked = s.micParked
        captureQueue.async { [weak self] in
            mic.stop()
            s.system.stop()
            s.micTrack.end()
            s.sysTrack.end()
            mic.inputDevice = device
            Thread.sleep(forTimeInterval: 0.3)
            if !parked { s.micTrack.begin() }
            s.sysTrack.begin()
            if !parked { self?.startMicOnQueue(s, mic: mic, voice: voice) }
            self?.startSystemOnQueue(s)
        }
    }

    /// The call app let go of the mic: stop ours and keep recording the other side. Park and unpark go through the
    /// capture queue like every other start and stop, so they keep their order against restarts.
    private func parkMic(_ s: Session) {
        s.micParked = true
        Log.info("capture: the call app released the mic, Tapetum releases it too; the other side keeps recording")
        let mic = self.mic
        captureQueue.async { [weak self] in
            self?.stopBridge(s)
            mic.stop()
            s.micTrack.end()
        }
        refresh()
    }

    /// The call app took the mic again (unmuted): record it again, on whatever mic the app uses now.
    private func unparkMic(_ s: Session) {
        s.micParked = false
        Log.info("capture: the call app uses the mic again, so does Tapetum")
        s.micWatch = Session.Watch(total: s.micTrack.totalBuffers, progressAt: Date(), restartedAt: Date())
        let mic = self.mic
        let voice = voiceMode
        let device = s.micDevice
        captureQueue.async { [weak self] in
            mic.inputDevice = device
            s.micTrack.begin()
            self?.startMicOnQueue(s, mic: mic, voice: voice)
        }
        refresh()
    }

    func pause() {
        guard state == .recording, let s = session else { return }
        state = .paused
        endInterval(s) { Log.info("session: paused, nothing is captured") }
        refresh()
    }

    func resume() {
        guard state == .paused, let s = session else { return }
        state = .recording
        beginInterval(s)
        Log.info("session: resumed")
        refresh()
    }

    func stopSession(trimTo trimHost: UInt64?) {
        guard state != .idle, let s = session else { return }
        let wasRecording = state == .recording
        state = .idle
        session = nil
        idleSince = nil
        silentSince = nil
        usersSince = nil
        let finish = { [weak self] in
            // Cut the quiet tail after the call app released the microphone.
            if let trim = trimHost, let last = s.manifest.intervals.indices.last,
               trim > s.manifest.intervals[last].start, trim < s.manifest.intervals[last].end {
                s.manifest.intervals[last].end = trim
            }
            s.manifest.status = .finalizing
            s.manifest.sysNoCallbacks = s.sysNoCallbacks ? true : nil
            s.save()
            Log.info("session: \(s.manifest.id) stopped, \(Fmt.clock(Timeline(s.manifest.intervals).total)) recorded")
            self?.jobs.submit(s.dir)
            self?.refresh()
        }
        if wasRecording {
            endInterval(s, then: finish)
        } else {
            // A pause may still be closing its files on the capture queue: finish after it.
            captureQueue.async { DispatchQueue.main.async { finish() } }
        }
        refresh()
    }

    func setVoiceMode(_ on: Bool) {
        guard state != .idle, on != voiceMode else { return }
        voiceMode = on
        Log.info("session: voice mode \(on ? "on" : "off")")
        if state == .recording { requestRestart("voice mode toggled") }
        refresh()
    }

    // MARK: - Remote control (tests, scripts)

    @objc private func remoteCommand(_ note: Notification) {
        guard let cmd = note.object as? String else { return }
        Log.info("control: \(cmd)")
        switch cmd {
        case "pause": pause()
        case "resume": resume()
        case "stop": stopSession(trimTo: nil)
        case "start": startSession(app: L.string("Manual recording"), auto: false)
        case "voice-on": setVoiceMode(true)
        case "voice-off": setVoiceMode(false)
        case "auto-on": prefs.autoRecord = true; prefs.save(config)
        case "auto-off": prefs.autoRecord = false; prefs.save(config)
        case "retry": jobs.resumeAll(includeFailed: true, activeSessionID: session?.manifest.id)
        case "quit": NSApp.terminate(nil)
        default: break
        }
        refresh()
    }

    // MARK: - UI

    private var icon: EyeIcon {
        switch state {
        case .recording: return .open
        case .paused: return .half
        case .idle:
            if jobs.isBusy { return .busy }
            return jobs.pendingSummary().count > 0 ? .waiting : .closed
        }
    }

    private var headline: String {
        let elapsed = Fmt.elapsed(currentRecorded())
        let app = session?.manifest.app ?? ""
        switch state {
        case .recording: return L.format("Recording: %@ · %@", app, elapsed)
        case .paused: return L.format("Paused: %@ · %@ recorded", app, elapsed)
        case .idle:
            if jobs.isBusy { return L.string("Transcribing…") }
            let p = jobs.pendingSummary()
            if p.count > 0 { return L.format("Waiting for the Whisper server: %ld", p.count) }
            return prefs.autoRecord ? L.string("Idle · recording calls automatically") : L.string("Idle · automatic recording is off")
        }
    }

    private func currentRecorded() -> Double {
        guard let s = session else { return 0 }
        var intervals = s.manifest.intervals
        if let last = intervals.indices.last, intervals[last].end == 0 { intervals[last].end = HostTime.now() }
        return Timeline(intervals).total
    }

    private func refresh() {
        let img = icon.image
        if statusItem.button?.image !== img { statusItem.button?.image = img }
        writeStatus()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, checked: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.isEnabled = action != nil
            i.state = checked ? .on : .off
            menu.addItem(i)
            return i
        }
        _ = item(headline, nil)
        if !MicPermission.granted {
            _ = item("⚠︎ " + L.string("No microphone permission: open Settings…"), #selector(menuMicSettings))
        }
        if !config.isTestMode, config.testSystemFile == nil, SystemAudioPermission.status() != .authorized {
            _ = item("⚠︎ " + L.string("Allow recording the other side…"), #selector(menuSystemAudio))
        }
        if let s = session {
            for problem in [s.micProblem, s.sysProblem].compactMap({ $0 }) { _ = item("⚠︎ " + problem, nil) }
        }
        let pending = jobs.pendingSummary()
        if state == .idle, let err = pending.lastError, pending.count + pending.failed > 0 {
            _ = item("⚠︎ " + err, nil)
        }
        menu.addItem(.separator())
        switch state {
        case .recording:
            _ = item(L.string("Pause"), #selector(menuPause))
            _ = item(L.string("Stop Recording"), #selector(menuStop))
        case .paused:
            _ = item(L.string("Resume Recording"), #selector(menuResume))
            _ = item(L.string("Stop Recording"), #selector(menuStop))
        case .idle:
            _ = item(L.string("Record Now"), #selector(menuStart))
        }
        menu.addItem(.separator())
        // Idle: shows the setting new calls start with (voiceMode in config.json); during a call it changes that call.
        _ = item(L.string("Voice Mode (Echo Cancellation)"), state == .idle ? nil : #selector(menuVoice),
                 checked: state == .idle ? config.voiceMode : voiceMode)
        _ = item(L.string("Record Calls Automatically"), #selector(menuAuto), checked: prefs.autoRecord)
        menu.addItem(.separator())
        if pending.count + pending.failed > 0 {
            _ = item(L.format("Retry Transcription (%ld)", pending.count + pending.failed), #selector(menuRetry))
        }
        _ = item(L.string("Open Notes Folder"), #selector(menuOpenFolder))
        menu.addItem(.separator())
        _ = item(L.format("Quit %@", AppInfo.name), #selector(menuQuit))
    }

    @objc private func menuMicSettings() { MicPermission.openSettings() }
    @objc private func menuSystemAudio() {
        if SystemAudioPermission.status() == .denied {
            SystemAudioPermission.openSettings()
        } else {
            SystemAudioPermission.request { granted in
                if !granted { DispatchQueue.main.async { SystemAudioPermission.openSettings() } }
            }
        }
    }
    @objc private func menuPause() { pause() }
    @objc private func menuResume() { resume() }
    @objc private func menuStop() { stopSession(trimTo: nil) }
    @objc private func menuStart() { startSession(app: L.string("Manual recording"), auto: false) }
    @objc private func menuVoice() { setVoiceMode(!voiceMode) }
    @objc private func menuAuto() {
        prefs.autoRecord.toggle()
        prefs.save(config)
        Log.info("prefs: auto recording \(prefs.autoRecord ? "on" : "off")")
        refresh()
    }
    @objc private func menuRetry() { jobs.resumeAll(includeFailed: true, activeSessionID: session?.manifest.id) }
    @objc private func menuOpenFolder() {
        let url = URL(fileURLWithPath: config.notesDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// status.json for scripts and tests.
    private func writeStatus() {
        let p = jobs.pendingSummary()
        let s: [String: Any] = [
            "state": "\(state)",
            "icon": "\(icon)",
            "app": session?.manifest.app ?? "",
            "session": session?.manifest.id ?? "",
            "recordedSec": currentRecorded(),
            "voiceMode": voiceMode,
            "voiceActual": session?.voiceActual ?? voiceMode,
            "micReleased": session?.micParked ?? false,
            "autoRecord": prefs.autoRecord,
            "busy": jobs.isBusy,
            "pending": p.count,
            "failed": p.failed,
            "lastError": p.lastError ?? "",
            "micProblem": session?.micProblem ?? "",
            "sysProblem": session?.sysProblem ?? "",
            "micPermission": MicPermission.granted,
            "systemAudioPermission": "\(SystemAudioPermission.status())",
            "updated": Fmt.iso.string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: config.statusFile, options: .atomic)
        }
    }
}
