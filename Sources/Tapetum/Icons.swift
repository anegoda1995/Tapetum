import AppKit

/// Template icons for the menu bar: the cassette cat, whose reels are its eyes, in five states. Each state is a
/// 22 px and a 44 px (Retina) PNG in Resources/MenuBar, made from docs/menubar/<state>.svg by scripts/make-icon.sh.
enum EyeIcon {
    case closed     // idle, nothing is recorded: eyes closed
    case open       // recording: eyes open, slit pupils
    case half       // paused: lids half down
    case busy       // transcribing: round pupils
    case waiting    // eyes closed with a dot: recordings wait for the Whisper server

    private static var cache: [String: NSImage] = [:]

    private var file: String {
        switch self {
        case .closed: return "idle"
        case .open: return "recording"
        case .half: return "paused"
        case .busy: return "transcribing"
        case .waiting: return "waiting"
        }
    }

    var image: NSImage {
        let key = "\(self)"
        if let img = EyeIcon.cache[key] { return img }
        let img = EyeIcon.load(file) ?? NSImage(size: NSSize(width: 22, height: 22))
        img.size = NSSize(width: 22, height: 22)
        img.isTemplate = true
        img.accessibilityDescription = AppInfo.name
        EyeIcon.cache[key] = img
        return img
    }

    /// From the app bundle; a binary run straight from .build reads the repo's Resources folder instead.
    /// Both sizes go into one image, which picks the sharp one for the screen it is drawn on.
    private static func load(_ name: String) -> NSImage? {
        let dir = Bundle.main.url(forResource: "MenuBar", withExtension: nil)
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Resources/MenuBar").standardizedFileURL
        let image = NSImage(size: NSSize(width: 22, height: 22))
        for file in ["\(name).png", "\(name)@2x.png"] {
            guard let rep = NSImageRep(contentsOf: dir.appendingPathComponent(file)) else { continue }
            rep.size = NSSize(width: 22, height: 22)
            image.addRepresentation(rep)
        }
        return image.representations.isEmpty ? nil : image
    }
}
