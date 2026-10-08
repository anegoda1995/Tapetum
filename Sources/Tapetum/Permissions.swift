import AppKit
import AVFoundation

/// "System Audio Recording Only" permission. There is no public API to ask for it, and a tap alone
/// does not show the prompt, so this goes through TCC directly, as the AudioCap sample project does
/// (github.com/insidegui/AudioCap).
enum SystemAudioPermission {
    enum Status { case authorized, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static var cache: (at: Date, value: Status)?

    /// Cached for 5 s: the menu and status file ask every second.
    static func status() -> Status {
        if let c = cache, Date().timeIntervalSince(c.at) < 5 { return c.value }
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        let value: Status
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: value = .authorized
        case 1: value = .denied
        default: value = .unknown
        }
        cache = (Date(), value)
        return value
    }

    /// Shows the macOS prompt if the user has not decided yet.
    static func request(_ done: @escaping (Bool) -> Void) {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { done(false); return }
        unsafeBitCast(sym, to: RequestFn.self)(service, nil) { granted in
            DispatchQueue.main.async { cache = nil; done(granted) }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum MicPermission {
    static var granted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
