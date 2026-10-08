import AVFoundation
// vpcaller <seconds>: a call app that runs Apple voice processing on the default mic, like FaceTime. Plays nothing.
// Like a real call app it starts its engine again when a device reconfiguration stops it.
let seconds = Double(CommandLine.arguments[1]) ?? 10
let engine = AVAudioEngine()
try! engine.inputNode.setVoiceProcessingEnabled(true)
let f = engine.inputNode.outputFormat(forBus: 0)
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: f) { _, _ in }
var restarts = 0
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
    restarts += 1
    try? engine.start()
}
try! engine.start()
print("vpcaller: voice processing on, \(f.channelCount) ch"); fflush(stdout)
let end = Date().addingTimeInterval(seconds)
while Date() < end {
    if !engine.isRunning { try? engine.start(); restarts += 1 }
    Thread.sleep(forTimeInterval: 0.2)
}
engine.stop()
print("vpcaller: done, \(restarts) restarts"); fflush(stdout)
