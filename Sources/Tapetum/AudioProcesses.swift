import AppKit
import CoreAudio
import Darwin

/// Thin Core Audio property helpers.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var v = fallback
        let status = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? v : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        guard status == noErr, let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultOutputDevice() -> AudioObjectID {
        value(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
    }

    static func defaultInputDevice() -> AudioObjectID {
        value(system, kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(kAudioObjectUnknown))
    }

    static func inputStreamCount(_ device: AudioObjectID) -> Int {
        objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
    }
}

struct MicUser: Equatable {
    let pid: pid_t
    let bundleID: String
    let executable: String
    var object = AudioObjectID(kAudioObjectUnknown)
}

/// Which processes are capturing from any input device right now (macOS 14+ process objects).
enum AudioProcesses {
    static func inputUsers(excluding ownPID: pid_t, config: Config) -> [MicUser] {
        var users: [MicUser] = []
        for obj in CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList) {
            let running: UInt32 = CA.value(obj, kAudioProcessPropertyIsRunningInput, 0)
            guard running != 0 else { continue }
            let pid: pid_t = CA.value(obj, kAudioProcessPropertyPID, -1)
            guard pid > 0, pid != ownPID else { continue }
            let bundle = CA.string(obj, kAudioProcessPropertyBundleID) ?? ""
            let exe = executableName(pid)
            if isIgnored(bundle: bundle, executable: exe, path: executablePath(pid), config: config) { continue }
            users.append(MicUser(pid: pid, bundleID: bundle, executable: exe, object: obj))
        }
        return users
    }

    /// The microphone the call apps really use, or nil (then the default input is recorded). Call apps keep the mic
    /// they started with when a headset is plugged in mid-call, so the default input can be the wrong one.
    /// A voice-processing app also lists its output device among its inputs (the echo reference), so devices it
    /// also plays to are dropped when that leaves exactly one.
    static func micDevice(of users: [MicUser]) -> AudioObjectID? {
        let systemInputs = Set(CA.objects(CA.system, kAudioHardwarePropertyDevices).filter { CA.inputStreamCount($0) > 0 })
        var inputs = Set<AudioObjectID>(), outputs = Set<AudioObjectID>()
        for u in users where u.object != kAudioObjectUnknown {
            inputs.formUnion(CA.objects(u.object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
            outputs.formUnion(CA.objects(u.object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))
        }
        inputs.formIntersection(systemInputs)   // private aggregates of other processes are of no use here
        let mics = inputs.subtracting(outputs)
        if mics.count == 1 { return mics.first }
        if inputs.count == 1 { return inputs.first }
        let def = CA.defaultInputDevice()
        return inputs.contains(def) || mics.contains(def) ? def : nil
    }

    /// Whether a call app records through Apple voice processing itself. Such an app lists an output-only device
    /// (the speakers, its echo reference) among its inputs, or, like FaceTime's avconferenced, no devices at all.
    /// A plain recorder lists just its mic. While a voice processing app runs, the built-in mic is in a mode where
    /// every other client hears it about 40 dB down, and only another voice processing client gets the voice at
    /// full level.
    static func usesVoiceProcessing(_ users: [MicUser]) -> Bool {
        users.contains { u in
            guard u.object != kAudioObjectUnknown else { return false }
            let inputs = CA.objects(u.object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
            let outputs = CA.objects(u.object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
            if inputs.isEmpty && outputs.isEmpty { return true }
            return inputs.contains { CA.inputStreamCount($0) == 0 }
        }
    }

    static func deviceName(_ device: AudioObjectID) -> String {
        CA.string(device, kAudioObjectPropertyName) ?? "\(device)"
    }

    static func isIgnored(bundle: String, executable: String, path: String = "", config: Config) -> Bool {
        if !bundle.isEmpty, config.ignoreBundlePrefixes.contains(where: { bundle.hasPrefix($0) }) { return true }
        if !executable.isEmpty, config.ignoreProcessNames.contains(where: { $0.caseInsensitiveCompare(executable) == .orderedSame }) { return true }
        if !path.isEmpty, config.ignorePathFragments.contains(where: { path.contains($0) }) { return true }
        return false
    }

    static func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    static func executableName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        return ""
    }

    private static let knownDaemons = [
        "avconferenced": "FaceTime",
        "callservicesd": "FaceTime",
        "com.apple.WebKit.GPU": "Safari",
    ]

    /// Human name of the calling app: resolves helper bundle IDs (com.google.Chrome.helper -> Google Chrome).
    static func displayName(_ user: MicUser) -> String {
        if let known = knownDaemons[user.executable] { return known }
        // Helpers live inside the main app (Chrome, Slack, Teams): name the outermost .app in the process path.
        var pathBuf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(user.pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
            let path = String(cString: pathBuf)
            if let r = path.range(of: ".app/") {
                let app = String(path[..<r.lowerBound]) + ".app"
                return FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "")
            }
        }
        if !user.bundleID.isEmpty {
            var comps = user.bundleID.split(separator: ".").map(String.init)
            while comps.count >= 2 {
                let id = comps.joined(separator: ".")
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    return FileManager.default.displayName(atPath: url.path)
                        .replacingOccurrences(of: ".app", with: "")
                }
                comps.removeLast()
            }
        }
        if let app = NSRunningApplication(processIdentifier: user.pid), let name = app.localizedName { return name }
        return user.executable.isEmpty ? L.string("Call") : user.executable
    }

    static func displayName(_ users: [MicUser]) -> String {
        var seen: [String] = []
        for u in users {
            let n = displayName(u)
            if !seen.contains(n) { seen.append(n) }
        }
        return seen.isEmpty ? L.string("Call") : seen.joined(separator: ", ")
    }
}

/// Calls back on the main queue when the default output device changes.
final class DeviceWatcher {
    var onOutputChange: (() -> Void)?

    init() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.onOutputChange?()
        }
    }
}

extension AudioProcesses {
    /// The app a process belongs to: the outermost .app in its path (Chrome and Slack helpers belong to their app),
    /// or the executable name for daemons and command line tools.
    static func appKey(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
            return (path as NSString).lastPathComponent
        }
        return executableName(pid)
    }

    /// Apps (appKey) that are playing sound right now.
    static func outputApps(excluding ownPID: pid_t) -> Set<String> {
        var keys = Set<String>()
        for obj in CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList) {
            let running: UInt32 = CA.value(obj, kAudioProcessPropertyIsRunningOutput, 0)
            guard running != 0 else { continue }
            let pid: pid_t = CA.value(obj, kAudioProcessPropertyPID, -1)
            guard pid > 0, pid != ownPID else { continue }
            keys.insert(appKey(pid))
        }
        return keys
    }
}

/// Event-driven detection: Core Audio tells us the moment a call app opens the mic, instead of us finding out on
/// the next poll (up to 1 s later, the first words lost). Core Audio does not send notifications for
/// kAudioProcessPropertyIsRunningInput/Output, only for kAudioProcessPropertyIsRunning (a process starts any IO)
/// and, for an app that already plays sound and then opens its mic (a browser call), for the input device's
/// kAudioDevicePropertyDeviceIsRunningSomewhere. Both arrive as soon as the call app opens the mic.
final class ProcessWatcher {
    var onChange: (() -> Void)?
    private var watched = Set<AudioObjectID>()

    func start() {
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices] {
            var addr = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(CA.system, &addr, DispatchQueue.main) { [weak self] _, _ in
                self?.refresh()
                self?.onChange?()
            }
        }
        refresh()
    }

    /// Adds listeners to process objects and input devices we have not seen yet. Objects that go away take their
    /// listeners with them, so there is nothing to remove.
    private func refresh() {
        let processes = CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList)
        let inputs = CA.objects(CA.system, kAudioHardwarePropertyDevices).filter { CA.inputStreamCount($0) > 0 }
        let pairs = processes.map { ($0, kAudioProcessPropertyIsRunning) } + inputs.map { ($0, kAudioDevicePropertyDeviceIsRunningSomewhere) }
        for (obj, selector) in pairs where !watched.contains(obj) {
            var addr = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(obj, &addr, DispatchQueue.main) { [weak self] _, _ in self?.onChange?() }
        }
        watched = Set(processes + inputs)
    }
}
