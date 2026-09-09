import Foundation
import CoreAudio
import CoreMedia

// Audio-only system capture using a private aggregate and the current output clock.
// Does not change the default device or mute playback.
final class CoreAudioSystemCapture: @unchecked Sendable {
    private let ioQueue = DispatchQueue(label: "org.wam.recorder.tap", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let deliveryQueue: DispatchQueue
    private let slots = DispatchSemaphore(value: 8)
    private let onSample: (CMSampleBuffer) -> Void
    private let onFailure: (String) -> Void
    private(set) var deviceDescription = "Core Audio process tap"
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var watchdog: DispatchSourceTimer?
    private var format = AudioStreamBasicDescription()
    private var description: CMAudioFormatDescription?
    // These three fields are confined to ioQueue while I/O is active.
    private var active = false
    private var failed = false
    private var lastReceived: TimeInterval = 0

    init(deliveryQueue: DispatchQueue, onSample: @escaping (CMSampleBuffer) -> Void,
         onFailure: @escaping (String) -> Void) {
        self.deliveryQueue = deliveryQueue; self.onSample = onSample; self.onFailure = onFailure
        ioQueue.setSpecific(key: queueKey, value: true)
    }
    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw RecorderFailure(message: "System audio: \(operation) failed (\(status)). Check WAM Recorder’s System Audio Recording permission and the current audio output device.")
        }
    }
    func start(channels: Int, silenceProbe: Bool = false) throws {
        do {
            let config = CATapDescription()
            config.name = "WAM system audio"; config.isPrivate = true
            config.isExclusive = !silenceProbe; config.isMixdown = true; config.isMono = channels == 1
            config.muteBehavior = .unmuted
            var pid = getpid(), process: AudioObjectID = 0
            var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr, process != 0 {
                config.processes = [process]
            } else {
                guard !silenceProbe else { throw RecorderFailure(message: "The silent-tap diagnostic could not identify its own process.") }
                config.processes = []
            }
            if #available(macOS 26.0, *), let bundle = Bundle.main.bundleIdentifier { config.bundleIDs = [bundle] }
            try check(AudioHardwareCreateProcessTap(config, &tap), "create audio tap")
            property = address(kAudioTapPropertyFormat); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &format), "read tap format")
            guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate.isFinite, (8000...192000).contains(format.mSampleRate),
                  format.mChannelsPerFrame == UInt32(channels), format.mBytesPerFrame > 0, format.mBytesPerFrame <= 16 else {
                throw RecorderFailure(message: "The system audio tap returned an unsupported format.")
            }
            try check(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), "describe tap format")
            var uid: Unmanaged<CFString>?
            property = address(kAudioTapPropertyUID); size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            try check(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &uid), "read tap identifier")
            guard let tapUID = uid?.takeRetainedValue() else { throw RecorderFailure(message: "The system audio tap has no identifier.") }
            // A physical output provides an I/O clock when no display is attached.
            var output: AudioObjectID = 0
            property = address(kAudioHardwarePropertyDefaultOutputDevice); size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &output), "read output clock")
            guard output != 0 else { throw RecorderFailure(message: "No output device is available for system audio.") }
            var outputUIDValue: Unmanaged<CFString>?
            property = address(kAudioDevicePropertyDeviceUID); size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            try check(AudioObjectGetPropertyData(output, &property, 0, nil, &size, &outputUIDValue), "read output identifier")
            guard let outputUID = outputUIDValue?.takeRetainedValue() else { throw RecorderFailure(message: "The output device has no identifier.") }
            var nameValue: Unmanaged<CFString>?
            property = address(kAudioObjectPropertyName); size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(output, &property, 0, nil, &size, &nameValue) == noErr, let name = nameValue?.takeRetainedValue() {
                deviceDescription = "Core Audio process tap · clock: \(name)"
            }
            if silenceProbe { deviceDescription += " · DIAGNOSTIC own-process silence" }
            let device: [String: Any] = [
                kAudioAggregateDeviceNameKey: "WAM private system capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceInputChannelsKey: 0]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: false]]
            ]
            try check(AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate), "create private capture device")
            var clockRate: Float64 = 0
            property = address(kAudioDevicePropertyNominalSampleRate); size = UInt32(MemoryLayout<Float64>.size)
            try check(AudioObjectGetPropertyData(aggregate, &property, 0, nil, &size, &clockRate), "read capture clock rate")
            guard clockRate == format.mSampleRate else {
                throw RecorderFailure(message: "System audio clock and tap rates differ. Choose an output device with a matching sample rate and start again.")
            }
            let route: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.active else { return }
                self.fail("The system output device changed. Completed audio was saved; start a new session with the current output device.")
            }
            property = address(kAudioHardwarePropertyDefaultOutputDevice)
            try check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, ioQueue, route), "observe output route")
            routeListener = route
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.active else { return }
                self.fail("System audio format changed. Completed audio was saved; start a new session with the current output device.")
            }
            property = address(kAudioTapPropertyFormat)
            try check(AudioObjectAddPropertyListenerBlock(tap, &property, ioQueue, listener), "observe tap format")
            formatListener = listener
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, ioQueue) { [weak self] _, input, time, _, _ in
                self?.consume(input, time: time.pointee)
            }, "create capture callback")
            ioQueue.sync { active = true; failed = false; lastReceived = ProcessInfo.processInfo.systemUptime }
            try check(AudioDeviceStart(aggregate, ioProc), "start capture")
            let timer = DispatchSource.makeTimerSource(queue: ioQueue)
            timer.schedule(deadline: .now() + 5, repeating: 2, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in
                guard let self, self.active, ProcessInfo.processInfo.systemUptime - self.lastReceived > 5 else { return }
                self.fail("System audio stopped delivering buffers. Completed audio was saved. Check recording permission and the output device.")
            }
            watchdog = timer; timer.resume()
        } catch { try? stop(); throw error }
    }
    private func fail(_ message: String) {
        guard !failed else { return }; failed = true
        deliveryQueue.async { [onFailure] in onFailure(message) }
    }
    private func consume(_ input: UnsafePointer<AudioBufferList>, time: AudioTimeStamp) {
        guard active, !failed else { return }
        // HAL can deliver an empty input list before the tap becomes ready.
        guard input.pointee.mNumberBuffers > 0, input.pointee.mBuffers.mDataByteSize > 0 else { return }
        guard slots.wait(timeout: .now()) == .success else {
            fail("System audio could not keep up with storage. Completed checkpoints were saved."); return
        }
        do {
            guard let description else { throw RecorderFailure(message: "Missing system audio format.") }
            let sample = try Self.copySample(input, time: time, format: format, description: description)
            lastReceived = ProcessInfo.processInfo.systemUptime
            deliveryQueue.async { [slots, onSample] in
                defer { slots.signal() }
                onSample(sample)
            }
        } catch { slots.signal(); fail(error.localizedDescription) }
    }
    // Internal for ownership/layout tests. This never retains HAL's borrowed memory.
    static func copySample(_ input: UnsafePointer<AudioBufferList>, time: AudioTimeStamp,
                           format: AudioStreamBasicDescription, description: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard format.mSampleRate.isFinite, (8000...192000).contains(format.mSampleRate),
              format.mSampleRate.rounded() == format.mSampleRate, format.mBytesPerFrame > 0, let first = buffers.first, first.mDataByteSize > 0 else { throw RecorderFailure(message: "Empty system audio buffer.") }
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let frames = first.mDataByteSize / format.mBytesPerFrame
        guard frames > 0, frames <= 8192, first.mDataByteSize % format.mBytesPerFrame == 0,
              buffers.count == (planar ? Int(format.mChannelsPerFrame) : 1),
              buffers.allSatisfy({ $0.mData != nil && $0.mDataByteSize == frames * format.mBytesPerFrame && $0.mNumberChannels == (planar ? 1 : format.mChannelsPerFrame) }),
              time.mFlags.contains(.hostTimeValid) else {
            throw RecorderFailure(message: "System audio delivered an invalid buffer layout or timestamp.")
        }
        // Copy borrowed HAL memory before returning. At most eight buffers are
        // queued; all conversion, encoder work and disk I/O happen off this callback.
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(format.mSampleRate)),
            presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(time.mHostTime), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var status = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: description, sampleCount: Int(frames), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        if status == noErr, let sample {
            status = CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, bufferList: input)
            if status == noErr { status = CMSampleBufferSetDataReady(sample) }
        }
        guard status == noErr, let sample else { throw RecorderFailure(message: "System audio buffer copy failed (\(status)).") }
        return sample
    }
    func stop() throws {
        watchdog?.cancel(); watchdog = nil
        var first: OSStatus = noErr
        func remember(_ status: OSStatus) { if first == noErr && status != noErr { first = status } }
        if let ioProc { remember(AudioDeviceStop(aggregate, ioProc)); remember(AudioDeviceDestroyIOProcID(aggregate, ioProc)); self.ioProc = nil }
        if DispatchQueue.getSpecific(key: queueKey) == true { active = false }
        else { ioQueue.sync { active = false } }
        if let routeListener {
            var property = address(kAudioHardwarePropertyDefaultOutputDevice)
            remember(AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, ioQueue, routeListener)); self.routeListener = nil
        }
        if let formatListener {
            var property = address(kAudioTapPropertyFormat)
            remember(AudioObjectRemovePropertyListenerBlock(tap, &property, ioQueue, formatListener)); self.formatListener = nil
        }
        if aggregate != 0 { remember(AudioHardwareDestroyAggregateDevice(aggregate)); aggregate = 0 }
        if tap != 0 { remember(AudioHardwareDestroyProcessTap(tap)); tap = 0 }
        try check(first, "release capture resources")
    }
    deinit { try? stop() }
}
