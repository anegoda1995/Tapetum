import AVFoundation
import CoreAudio
// A call app you mute: holds the mic for <micSeconds>, keeps playing the remote side until <totalSeconds>.
// usage: mutecall <remote.wav> <micSeconds> <totalSeconds> [output device name]
// With an output device name (a virtual device, for example) the test plays nothing through the speakers.
// MUTECALL_REOPEN=<seconds>: unmute at that time, holding the mic again until <totalSeconds>.
let a = CommandLine.arguments
let micSeconds = Double(a[2])!, total = Double(a[3])!

func device(named name: String) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids.first { id in
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var cfSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &cfSize, $0) }
        return st == noErr && (cf?.takeRetainedValue() as String?) == name
    }
}

let inEngine = AVAudioEngine()
inEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inEngine.inputNode.outputFormat(forBus: 0)) { _, _ in }
try! inEngine.start()
let out = AVAudioEngine()
if a.count > 4 {
    guard let id = device(named: a[4]) else { print("mutecall: no output device named \(a[4])"); exit(2) }
    try! out.outputNode.auAudioUnit.setDeviceID(id)
}
let player = AVAudioPlayerNode()
let file = try! AVAudioFile(forReading: URL(fileURLWithPath: a[1]))
out.attach(player)
out.connect(player, to: out.mainMixerNode, format: file.processingFormat)
out.mainMixerNode.outputVolume = 0.3
try! out.start()
player.scheduleFile(file, at: nil, completionHandler: nil)
player.play()
// Like a real call app: when another app's voice processing reconfigures the devices, the engines stop and
// are started again.
var micOn = true
let center = NotificationCenter.default
center.addObserver(forName: .AVAudioEngineConfigurationChange, object: inEngine, queue: nil) { _ in
    if micOn { try? inEngine.start() }
}
center.addObserver(forName: .AVAudioEngineConfigurationChange, object: out, queue: nil) { _ in
    try? out.start()
    player.play()
}
print("mutecall: mic + sound"); fflush(stdout)
Thread.sleep(forTimeInterval: micSeconds)
micOn = false
inEngine.stop()
print("mutecall: muted (mic released), sound continues"); fflush(stdout)
if let reopen = ProcessInfo.processInfo.environment["MUTECALL_REOPEN"].flatMap(Double.init), reopen < total {
    Thread.sleep(forTimeInterval: max(0, reopen - micSeconds))
    micOn = true
    try! inEngine.start()
    print("mutecall: unmuted (mic again)"); fflush(stdout)
    Thread.sleep(forTimeInterval: max(0, total - reopen))
    micOn = false
    inEngine.stop()
} else {
    Thread.sleep(forTimeInterval: max(0, total - micSeconds))
}
out.stop()
print("mutecall: call over"); fflush(stdout)
