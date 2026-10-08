import AppKit

enum AppInfo {
    static let name = "Tapetum"
    static let bundleID = "io.github.anegoda1995.tapetum"
    /// Distributed notification that `Tapetum --send <command>` posts to the running app. An instance with its own
    /// TAPETUM_HOME (the tests) listens on its own name, so test commands never reach the installed app.
    static var controlNotification: Notification.Name {
        let home = ProcessInfo.processInfo.environment["TAPETUM_HOME"] ?? ""
        return Notification.Name(bundleID + ".control" + (home.isEmpty ? "" : ":" + home))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = AppController(config: Config.load())
        controller = c
        c.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}

@main
enum TapetumApp {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "--selftest":
            exit(SelfTest.run() ? 0 : 1)
        case "--send":
            guard args.count > 1 else { print("usage: Tapetum --send <command>"); exit(2) }
            DistributedNotificationCenter.default().postNotificationName(
                AppInfo.controlNotification, object: args[1], userInfo: nil, deliverImmediately: true)
            exit(0)
        case "--process":
            // Finish one recording directory synchronously (render, note, transcription).
            guard args.count > 1 else { print("usage: Tapetum --process <recording dir>"); exit(2) }
            let jobs = JobRunner(config: Config.load())
            jobs.processNow(URL(fileURLWithPath: args[1], isDirectory: true))
            Log.flush()
            exit(0)
        case "--render-icons":
            renderIcons(to: URL(fileURLWithPath: args.count > 1 ? args[1] : "."))
            exit(0)
        case "--list-mic":
            let c = Config.load()
            for u in AudioProcesses.inputUsers(excluding: getpid(), config: c) {
                let voice = AudioProcesses.usesVoiceProcessing([u]) ? " [voice processing]" : ""
                print("\(u.pid) \(u.executable) \(u.bundleID) -> \(AudioProcesses.displayName(u))\(voice)")
            }
            exit(0)
        default:
            break
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        withExtendedLifetime(term) { app.run() }
    }

    /// Draws every menu bar icon state side by side, once for a light and once for a dark menu bar
    /// (menu-icons-light.png, menu-icons-dark.png), to check them without the menu bar.
    private static func renderIcons(to dir: URL) {
        let states: [EyeIcon] = [.closed, .open, .half, .busy, .waiting]
        let scale: CGFloat = 4, icon: CGFloat = 18, gap: CGFloat = 10
        let size = NSSize(width: (CGFloat(states.count) * (icon + gap) + gap) * scale, height: (icon + 2 * 6) * scale)
        for (suffix, bg, fg) in [("light", NSColor(white: 0.93, alpha: 1), NSColor.black),
                                 ("dark", NSColor(white: 0.16, alpha: 1), NSColor.white)] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            bg.setFill()
            NSRect(origin: .zero, size: size).fill()
            for (i, state) in states.enumerated() {
                let frame = NSRect(x: (gap + CGFloat(i) * (icon + gap)) * scale, y: 6 * scale, width: icon * scale, height: icon * scale)
                let tinted = NSImage(size: frame.size, flipped: false) { r in
                    state.image.draw(in: r)
                    fg.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: frame)
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("menu-icons-\(suffix).png"))
        }
    }
}
