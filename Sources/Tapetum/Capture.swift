import AVFoundation
import CoreAudio
import AudioToolbox

/// Mono samples, host time of the first sample, sample rate.
typealias SampleSink = (_ samples: [Float], _ hostTime: UInt64, _ sampleRate: Double) -> Void

protocol AudioSource: AnyObject {
    var sink: SampleSink? { get set }
    func start() throws
    func stop()
}

struct CaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Exported by CoreAudio, but not declared in the current SDK headers.
@_silgen_name("AudioDeviceDuck")
func AudioDeviceDuck(_ device: AudioObjectID, _ level: Float32, _ start: UnsafePointer<AudioTimeStamp>?, _ ramp: Float32) -> OSStatus

/// Voice processing turns every other app down while it runs, the call itself included: about -4 dB even at
/// `.min`, the lowest ducking level, after a deeper dip while it starts. The duck request belongs to this process,
/// so AudioDeviceDuck(1.0) from here takes it back. Voice processing sets it again when it reconfigures, so after
/// every start this repeats every 0.25 s for 5 s, then every 15 s.
final class DuckGuard {
    private let queue = DispatchQueue(label: "tapetum.duckguard")
    private var timer: DispatchSourceTimer?
    private var armedAt = Date.distantPast
    private var lastUnduck = Date.distantPast
    private var lastStatus: OSStatus = noErr

    func arm() {
        queue.async { [self] in
            armedAt = Date()
            lastUnduck = .distantPast
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func disarm() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        let now = Date()
        guard now.timeIntervalSince(armedAt) < 5 || now.timeIntervalSince(lastUnduck) >= 15 else { return }
        let first = lastUnduck == .distantPast
        lastUnduck = now
        let device = CA.defaultOutputDevice()
        let status = AudioDeviceDuck(device, 1.0, nil, 0)
        if first || status != lastStatus {
            Log.info("mic: voice processing's duck of other apps taken back on device \(device) (status \(status))")
        }
        lastStatus = status
    }
}

// MARK: - Microphone

/// Your side. Voice mode: AVAudioEngine with Apple voice processing (echo cancellation, noise suppression).
/// Plain mode: an AVCaptureSession, because a plain AVAudioEngine input started while the call app is still
/// starting the same mic sometimes waited about 13 s in AudioDeviceStart for the device's I/O thread, and a
/// capture session never did in the same tests.
final class MicCapture: AudioSource {
    var sink: SampleSink?
    var voiceMode = true
    var label = "mic"
    var onConfigChange: (() -> Void)?
    /// The mic the call app uses (nil or the default input: the default input, as before).
    var inputDevice: AudioObjectID?

    private var engine: AVAudioEngine?
    private var capture: CaptureBridge?
    private var observer: NSObjectProtocol?
    private let duckGuard = DuckGuard()

    private func build(voice: Bool) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voice {
            try input.setVoiceProcessingEnabled(true)
            // Turn the other apps down as little as possible; DuckGuard takes the rest back once the engine runs.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        if let dev = inputDevice, dev != CA.defaultInputDevice() {
            if voice {
                // Voice processing resets a device chosen before it is enabled, and the AUAudioUnit's deviceID is
                // its output: the mic is element 1 of the voice processing unit.
                guard let au = input.audioUnit else { throw CaptureError(message: L.string("no audio unit for the microphone")) }
                var d = dev
                let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &d,
                                              UInt32(MemoryLayout<AudioObjectID>.size))
                guard st == noErr else { throw CaptureError(message: L.format("could not select the microphone (%d)", st)) }
            } else {
                try input.auAudioUnit.setDeviceID(dev)
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError(message: L.format("microphone unavailable (format %@)", format.description))
        }
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self, let channels = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            let host = when.isHostTimeValid ? when.hostTime : HostTime.now()
            // With voice processing channel 0 is the processed voice; other channels are raw mics.
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: n))
            self.sink?(samples, host, rate)
        }
        // Do not touch mainMixerNode here: connecting it makes the voice processing unit fail to initialize (-10875).
        engine.prepare()
        return engine
    }

    func start() throws {
        guard voiceMode else {
            let c = CaptureBridge()
            c.label = label
            c.inputDevice = inputDevice
            c.sink = sink
            try c.start()
            capture = c
            return
        }
        let t0 = Date()
        // Voice processing ducks while it is still being set up, so take it back from the start (failures: stop()).
        if voiceMode { duckGuard.arm() }
        let engine = try build(voice: voiceMode)
        try engine.start()
        if voiceMode { duckGuard.arm() }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            self?.onConfigChange?()
        }
        self.engine = engine
        let f = engine.inputNode.outputFormat(forBus: 0)
        let mic = AudioProcesses.deviceName(inputDevice ?? CA.defaultInputDevice())
        Log.info(String(format: "%@: started %d ch @ %d Hz, voice mode %@, in %.0f ms, mic %@", label, Int(f.channelCount),
                        Int(f.sampleRate), voiceMode ? "on" : "off", Date().timeIntervalSince(t0) * 1000, mic))
    }

    var isRunning: Bool { capture?.isRunning ?? engine?.isRunning ?? false }

    /// AVAudioEngine stops itself when the device configuration changes; Apple's advice is to start it again.
    /// This keeps voice processing as it is, instead of rebuilding it (which reconfigures the device again).
    func recover() -> Bool {
        if let capture {
            if capture.isRunning { return true }
            capture.stop()
            do {
                try capture.start()
                return true
            } catch {
                Log.info("\(label): capture session could not start again: \(error.localizedDescription)")
                return false
            }
        }
        guard let engine else { return false }
        if engine.isRunning { return true }
        do {
            try engine.start()
            if voiceMode { duckGuard.arm() }
            Log.info("\(label): engine started again after a device change")
            return true
        } catch {
            Log.info("\(label): engine could not start again: \(error.localizedDescription)")
            return false
        }
    }

    /// Voice processing sometimes starts "dead" (running, no audio). Stopping and starting the same engine
    /// brings it to life without rebuilding it.
    func kick() {
        if let capture {
            Log.info("\(label): capture session restarted because it gave no audio")
            capture.stop()
            do { try capture.start() } catch { Log.info("\(label): kick failed: \(error.localizedDescription)") }
            return
        }
        guard let engine else { return }
        engine.stop()
        do {
            try engine.start()
            if voiceMode { duckGuard.arm() }
            Log.info("\(label): engine kicked (stop/start) because it gave no audio")
        } catch {
            Log.info("\(label): kick failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        duckGuard.disarm()
        if let capture {
            capture.stop()
            self.capture = nil
            return
        }
        guard let engine else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if voiceMode { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        self.engine = nil
        Log.info("\(label): stopped")
    }
}

// MARK: - Bridge (AVCaptureSession)

/// The mic through AVCaptureSession: the whole mic in plain mode, and the first moments of the mic while voice
/// processing starts. It keeps capturing when voice processing reconfigures the device (measured: largest gap
/// 18-143 ms), while a plain AVAudioEngine stops dead.
final class CaptureBridge: NSObject, AudioSource, AVCaptureAudioDataOutputSampleBufferDelegate {
    var sink: SampleSink?
    /// Log prefix: "bridge" while it covers voice processing's start, "mic" when it is the plain mic.
    var label = "bridge"
    /// The mic the call app uses (nil: the default input). AVCaptureDevice's uniqueID is the Core Audio device UID.
    var inputDevice: AudioObjectID?
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "tapetum.capturebridge", qos: .userInitiated)

    var isRunning: Bool { session?.isRunning ?? false }

    /// The first AVCaptureDeviceInput in a process takes about 0.9 s when it is created while another app is starting
    /// the mic, which is exactly when a call begins; every later one takes ~15 ms, for any device. Creating one at
    /// launch pays that early. It opens no mic: audio only flows once a session runs. Needs the mic permission.
    static func warmUp() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = AVCaptureDevice.default(for: .audio) else { return false }
        return (try? AVCaptureDeviceInput(device: device)) != nil
    }

    func start() throws {
        let t0 = Date()
        let chosen = inputDevice.flatMap { CA.string($0, kAudioDevicePropertyDeviceUID) }.flatMap { AVCaptureDevice(uniqueID: $0) }
        guard let device = chosen ?? AVCaptureDevice.default(for: .audio) else { throw CaptureError(message: L.string("no microphone")) }
        let s = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard s.canAddInput(input) else { throw CaptureError(message: L.string("the microphone is busy")) }
        s.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(output) else { throw CaptureError(message: L.string("could not add the capture output")) }
        s.addOutput(output)
        s.startRunning()
        session = s
        Log.info(String(format: "%@: capture session started in %.0f ms, mic %@", label, Date().timeIntervalSince(t0) * 1000, device.localizedName))
    }

    func stop() {
        guard let s = session else { return }
        s.stopRunning()
        session = nil
        Log.info("\(label): stopped")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr, let first = UnsafeMutableAudioBufferListPointer(ablPtr).first, let data = first.mData else { return }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nch = Int(max(1, first.mNumberChannels))   // interleaved channels in the first buffer; use channel 0
        var mono = [Float](repeating: 0, count: frames)
        if isFloat && asbd.mBitsPerChannel == 32 {
            let f = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { mono[i] = f[i * nch] }
        } else if asbd.mBitsPerChannel == 16 {
            let p = data.assumingMemoryBound(to: Int16.self)
            for i in 0..<frames { mono[i] = Float(p[i * nch]) / 32768 }
        } else if asbd.mBitsPerChannel == 32 {
            let p = data.assumingMemoryBound(to: Int32.self)
            for i in 0..<frames { mono[i] = Float(p[i * nch]) / 2147483648 }
        } else {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = pts.isValid ? CMClockConvertHostTimeToSystemUnits(pts) : HostTime.now()
        sink?(mono, host, asbd.mSampleRate)
    }
}

// MARK: - System audio (Core Audio process tap)

/// The other side: everything the Mac plays, through a global process tap (macOS 14.2+).
/// Needs the "System Audio Recording" permission (NSAudioCaptureUsageDescription).
final class SystemTapCapture: AudioSource {
    var sink: SampleSink?
    /// Bundle ID prefixes of processes the tap leaves out (Config.tapExcludeBundlePrefixes).
    var excludedBundlePrefixes: [String] = []
    private(set) var callbacks = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "tapetum.systemtap", qos: .userInitiated)

    func start() throws {
        let excluded = CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList).filter { process in
            let bundle = CA.string(process, kAudioProcessPropertyBundleID) ?? ""
            return !bundle.isEmpty && excludedBundlePrefixes.contains { !$0.isEmpty && bundle.hasPrefix($0) }
        }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.name = AppInfo.name
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw CaptureError(message: L.format("could not create the audio tap (%d)", status)) }

        var formatAddr = CA.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &size, &asbd)
        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000

        // The aggregate holds the tap alone: one clocked by the output device could freeze when voice processing
        // reconfigured that device.
        // No kAudioAggregateDeviceTapAutoStartKey: with it the tap waits until some app plays sound, and while it
        // waits, starting the mic bridge in this process blocks for up to ~30 s. Without it the tap delivers
        // silence until something plays.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(AppInfo.name) Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw CaptureError(message: L.format("could not create the aggregate device (%d)", status))
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inData, inTime, _, _ in
            guard let self else { return }
            self.callbacks += 1
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            var mono: [Float] = []
            var channelsSummed = 0
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let nch = Int(max(1, buffer.mNumberChannels))
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / nch
                guard frames > 0 else { continue }
                if mono.isEmpty { mono = [Float](repeating: 0, count: frames) }
                let f = data.assumingMemoryBound(to: Float.self)
                let m = min(frames, mono.count)
                mono.withUnsafeMutableBufferPointer { out in
                    for i in 0..<m {
                        var s: Float = 0
                        for c in 0..<nch { s += f[i * nch + c] }
                        out[i] += s
                    }
                }
                channelsSummed += nch
            }
            guard !mono.isEmpty, channelsSummed > 0 else { return }
            let gain = 1 / Float(channelsSummed)
            for i in mono.indices { mono[i] *= gain }
            let t = inTime.pointee
            let host = t.mFlags.contains(.hostTimeValid) ? t.mHostTime : HostTime.now()
            self.sink?(mono, host, rate)
        }
        guard status == noErr else {
            stop()
            throw CaptureError(message: L.format("could not create the audio callback (%d)", status))
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw CaptureError(message: L.format("could not start the audio tap (%d)", status))
        }
        Log.info("system: tap started @ \(Int(rate)) Hz, \(asbd.mChannelsPerFrame) ch"
                 + (excluded.isEmpty ? "" : ", \(excluded.count) excluded process(es) left out"))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: - Test source

/// Test hook (TAPETUM_TEST_SYSTEM_FILE): plays a file as "system audio" in real time.
/// Time keeps running while stopped, like a real call during a pause.
final class FileSource: AudioSource {
    var sink: SampleSink?
    private let samples: [Float]
    private let rate: Double
    private var originHost: UInt64 = 0
    private var delivered = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "tapetum.filesource")

    init(path: String) throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CaptureError(message: "cannot read \(path)")
        }
        try file.read(into: buf)
        let n = Int(buf.frameLength), nch = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        if let ch = buf.floatChannelData {
            for c in 0..<nch { for i in 0..<n { mono[i] += ch[c][i] / Float(nch) } }
        }
        samples = mono
        rate = format.sampleRate
    }

    func start() throws {
        queue.sync {
            let now = HostTime.now()
            if originHost == 0 { originHost = now; delivered = 0 }
            else { delivered = min(samples.count, Int(HostTime.diff(now, originHost) * rate)) }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.pump() }
            t.resume()
            timer = t
        }
        Log.info("system: test file source started")
    }

    private func pump() {
        let target = min(samples.count, Int(HostTime.diff(HostTime.now(), originHost) * rate))
        guard target > delivered else { return }
        let chunk = Array(samples[delivered..<target])
        let host = originHost + HostTime.ticks(Double(delivered) / rate)
        delivered = target
        sink?(chunk, host, rate)
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }
}

// MARK: - Writing parts to disk

/// Sidecar next to every part file: when it started and at what rate. Survives a crash.
struct PartInfo: Codable {
    var file: String
    var startHost: UInt64
    var sampleRate: Double
}

/// Writes one track ("mic" / "sys") as a sequence of 16-bit mono CAF parts.
/// A new part starts after every pause, device change or voice mode toggle.
final class TrackRecorder {
    let name: String
    let dir: URL
    private let queue: DispatchQueue
    private var accepting = false
    private var file: AVAudioFile?
    private var fileName = ""
    private var rate: Double = 0
    private var index = 0
    /// Test hook: drop everything after this many seconds of the first part (simulated frozen capture).
    var stallAfter: Double?
    private var firstBeginAt: Date?
    private var begins = 0
    private var stallBegins: Int?
    private var buffers = 0
    private var total = 0
    private var peak: Float = 0

    /// File prefix: "mic", "sys", or "mic_b" for the bridge (still part of the mic track when rendering).
    let prefix: String
    /// Called once, on the first buffer that is written (host time of its first sample).
    var onFirstBuffer: ((UInt64) -> Void)?
    private var sawFirst = false

    init(name: String, dir: URL, prefix: String? = nil) {
        self.name = name
        self.dir = dir
        self.prefix = prefix ?? name
        queue = DispatchQueue(label: "tapetum.track.\(prefix ?? name)")
        // Continue numbering if parts already exist (should not normally happen).
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        index = existing.filter { $0.hasPrefix("\(self.prefix)_") && $0.hasSuffix(".caf") }.count
    }

    func begin() {
        queue.sync {
            begins += 1
            if firstBeginAt == nil { firstBeginAt = Date() }
            accepting = true
            buffers = 0
            peak = 0
        }
    }

    func append(_ samples: [Float], host: UInt64, rate sampleRate: Double) {
        queue.async { [self] in
            guard accepting, !samples.isEmpty else { return }
            if let stall = stallAfter, let t0 = firstBeginAt, Date().timeIntervalSince(t0) > stall {
                // Frozen from `stall` seconds on, until the next restart of this track.
                if stallBegins == nil { stallBegins = begins }
                if begins == stallBegins { return }
            }
            if file == nil || sampleRate != rate {
                closeCurrent()
                openNew(host: host, rate: sampleRate)
            }
            guard let f = file,
                  let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
            else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            do { try f.write(from: buf) } catch { Log.info("\(name): write failed: \(error)") }
            if !sawFirst {
                sawFirst = true
                onFirstBuffer?(host)
            }
            buffers += 1
            total += 1
            for v in samples where abs(v) > peak { peak = abs(v) }
        }
    }

    /// Stops accepting samples and closes the current part. Nothing arriving later is written.
    func end() {
        queue.sync {
            accepting = false
            closeCurrent()
        }
    }

    var stats: (buffers: Int, peak: Float) { queue.sync { (buffers, peak) } }

    /// Buffers written since the recording started; the watchdog checks that it keeps growing.
    var totalBuffers: Int { queue.sync { total } }

    private func openNew(host: UInt64, rate sampleRate: Double) {
        index += 1
        fileName = "\(prefix)_\(index).caf"
        let url = dir.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            rate = sampleRate
            let info = PartInfo(file: fileName, startHost: host, sampleRate: sampleRate)
            if let data = try? JSONEncoder().encode(info) {
                try? data.write(to: dir.appendingPathComponent(fileName + ".json"), options: .atomic)
            }
        } catch {
            Log.info("\(name): cannot open \(fileName): \(error)")
            file = nil
        }
    }

    private func closeCurrent() {
        guard file != nil else { return }
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
    }
}
