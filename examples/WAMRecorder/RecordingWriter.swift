import Foundation
import AVFoundation
import CoreMedia
import WAMKit
import Accelerate

enum AudioScheme: String, CaseIterable, Codable, Identifiable {
    case float32, pcm16, alac, aac64, aac96
    var id: String { rawValue }
    var title: String {
        switch self {
        case .float32: return "Float32 PCM · uncompressed"
        case .pcm16: return "16-bit PCM · uncompressed"
        case .alac: return "Apple Lossless · 16-bit"
        case .aac64: return "AAC · 64 kb/s per channel"
        case .aac96: return "AAC · 96 kb/s per channel"
        }
    }
    var codec: UInt32 {
        switch self {
        case .float32: return UInt32(WAM_AUDIO_FLOAT32)
        case .pcm16: return UInt32(WAM_AUDIO_PCM16)
        case .alac: return UInt32(WAM_AUDIO_ALAC)
        default: return UInt32(WAM_AUDIO_AAC)
        }
    }
    var bitrate: UInt32 { self == .aac64 ? 64000 : self == .aac96 ? 96000 : 0 }
    var fileExtension: String { codec <= UInt32(WAM_AUDIO_ALAC) ? "m4a" : "caf" }
}
struct RecordingSettings: Codable {
    var microphone = true
    var systemAudio = true
    var deviceID = ""
    // The final default is set from the measured benchmark results.
    var scheme: AudioScheme = .float32
    // Zero preserves the capture stream rate independently for each source.
    var sampleRate = 48000
    var microphoneChannels = 1
    var systemChannels = 2
    var checkpointMinutes = 5
    var folderPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/WAM Recordings").path
}
struct RecorderFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func checkWAM(_ result: wam_status_t, _ error: inout wam_error_t) throws {
    guard result != WAM_OK else { return }
    let name = withUnsafePointer(to: &error.name) { $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) } }
    let detail = withUnsafePointer(to: &error.detail) { $0.withMemoryRebound(to: CChar.self, capacity: 768) { String(cString: $0) } }
    throw RecorderFailure(message: "\(name): \(detail)")
}
struct SegmentReceipt: Codable {
    var source: String
    var file: String
    var frames: UInt64
    var sampleRate: Int
    var channels: Int
    var startOffsetSeconds: Double
    var completed: Bool
    var inputSampleRate: Double? = nil
    var inputChannels: UInt32? = nil
    var resampled: Bool? = nil
    var remixed: Bool? = nil
    var directFloat32: Bool? = nil
    var peakMagnitude: Float? = 0
    var limited: Bool? = false
}
struct CaptureEvent: Codable {
    var source: String
    var offsetSeconds: Double
    var kind: String
    var deltaSeconds: Double?
}
struct SessionReceipt: Codable {
    var startedAt: Date
    var endedAt: Date?
    var settings: RecordingSettings
    var status: String
    var failure: String?
    var segments: [SegmentReceipt]
    var events: [CaptureEvent]? = []
    var inputDevices: [String: String]? = [:]
}

// Entire object is confined to CaptureCoordinator's utility queue.
final class RecordingWriter {
    final class Lane {
        let source: String
        let channels: Int
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var conversionBuffer: AVAudioPCMBuffer?
        var direct = false
        var sampleRate = 48000
        var totalSeconds: Double = 0
        var encoder: wam_audio_encoder_t?
        var frames: UInt64 = 0
        var totalFrames: UInt64 = 0
        var receiptIndex: Int?
        var nextPTS: Double?
        var offset: Double = 0
        init(_ source: String, _ channels: Int) { self.source = source; self.channels = channels }
        deinit { if let encoder { wam_audio_encoder_release(encoder) } }
    }
    let directory: URL
    let settings: RecordingSettings
    let hostStart = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    var receipt: SessionReceipt
    var lanes: [String: Lane] = [:]
    private var lastDiskCheck = Date.distantPast
    private var lastManifest = Date.distantPast
    private var closed = false
    var bytes: UInt64 = 0

    init(settings: RecordingSettings, rootOverride: URL? = nil) throws {
        guard settings.sampleRate == 0 || (8000...192000).contains(settings.sampleRate),
              (1...2).contains(settings.microphoneChannels), (1...2).contains(settings.systemChannels),
              [5, 15, 90].contains(settings.checkpointMinutes), settings.microphone || settings.systemAudio else {
            throw RecorderFailure(message: "Invalid recording settings.")
        }
        self.settings = settings
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let root = rootOverride ?? URL(fileURLWithPath: settings.folderPath)
        directory = root.appendingPathComponent("Recording \(stamp.string(from: Date())) \(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        receipt = SessionReceipt(startedAt: Date(), settings: settings, status: "recording", segments: [])
        if settings.microphone { lanes["Microphone"] = Lane("Microphone", settings.microphoneChannels) }
        if settings.systemAudio { lanes["System audio"] = Lane("System audio", settings.systemChannels) }
        try saveManifest()
    }
    private func saveManifest() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        lastManifest = Date()
    }
    private func open(_ lane: Lane) throws {
        let number = receipt.segments.filter { $0.source == lane.source }.count + 1
        let name = String(format: "%@ %03d.%@", lane.source, number, settings.scheme.fileExtension)
        var config = wam_audio_file_config_t(struct_size: UInt32(MemoryLayout<wam_audio_file_config_t>.size), sample_rate: UInt32(lane.sampleRate), channels: UInt32(lane.channels), codec: settings.scheme.codec, bitrate: settings.scheme.bitrate * UInt32(lane.channels), require_hardware: 0, reserved: 0)
        var error = wam_error_t()
        let result = directory.appendingPathComponent(name).path.withCString { wam_audio_encoder_create_file(&config, $0, &lane.encoder, &error) }
        try checkWAM(result, &error)
        lane.frames = 0
        lane.receiptIndex = receipt.segments.count
        receipt.segments.append(SegmentReceipt(source: lane.source, file: name, frames: 0, sampleRate: lane.sampleRate, channels: lane.channels, startOffsetSeconds: lane.offset, completed: false,
            inputSampleRate: lane.inputFormat?.sampleRate, inputChannels: lane.inputFormat?.channelCount,
            resampled: lane.inputFormat?.sampleRate != Double(lane.sampleRate),
            remixed: lane.inputFormat?.channelCount != UInt32(lane.channels), directFloat32: lane.direct))
        try saveManifest()
    }
    private func closeSegment(_ lane: Lane) throws {
        guard let encoder = lane.encoder else { return }
        lane.encoder = nil
        var error = wam_error_t()
        let result = wam_audio_encoder_finish(encoder, &error)
        wam_audio_encoder_release(encoder)
        try checkWAM(result, &error)
        if let index = lane.receiptIndex {
            receipt.segments[index].frames = lane.frames
            receipt.segments[index].completed = true
            let path = directory.appendingPathComponent(receipt.segments[index].file)
            let file = try FileHandle(forWritingTo: path)
            try file.synchronize(); try file.close()
            bytes += (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.uint64Value ?? 0
        }
        lane.receiptIndex = nil
        lane.offset += Double(lane.frames) / Double(lane.sampleRate)
        lane.frames = 0
        try saveManifest()
    }
    private func write(_ buffer: AVAudioPCMBuffer, lane: Lane) throws {
        guard let samples = buffer.floatChannelData?[0] else { throw RecorderFailure(message: "Audio conversion produced no PCM data.") }
        var offset = 0
        while offset < Int(buffer.frameLength) {
            if lane.encoder == nil { try open(lane) }
            let limit = UInt64(settings.checkpointMinutes * 60 * lane.sampleRate)
            let count = min(Int(buffer.frameLength) - offset, 4096, Int(limit - lane.frames))
            let chunk = samples.advanced(by: offset * lane.channels)
            let sampleCount = vDSP_Length(count * lane.channels)
            var peak: Float = 0
            vDSP_maxmgv(chunk, 1, &peak, sampleCount)
            if settings.scheme != .float32 {
                var lower: Float = -1, upper: Float = 1
                vDSP_vclip(chunk, 1, &lower, &upper, chunk, 1, sampleCount)
            }
            var error = wam_error_t()
            let result = wam_audio_encoder_write(lane.encoder, samples.advanced(by: offset * lane.channels), UInt32(count), &error)
            try checkWAM(result, &error)
            lane.totalSeconds += Double(count) / Double(lane.sampleRate)
            lane.frames += UInt64(count); lane.totalFrames += UInt64(count); offset += count
            if let index = lane.receiptIndex {
                receipt.segments[index].frames = lane.frames
                receipt.segments[index].peakMagnitude = max(receipt.segments[index].peakMagnitude ?? 0, peak)
                receipt.segments[index].limited = (receipt.segments[index].limited ?? false) || (peak > 1 && settings.scheme != .float32)
            }
            if lane.frames == limit { try closeSegment(lane) }
        }
    }
    private func convert(_ input: AVAudioPCMBuffer?, lane: Lane, end: Bool = false) throws {
        guard let converter = lane.converter else { return }
        var supplied = false
        for _ in 0..<128 {
            guard let output = lane.conversionBuffer else { throw RecorderFailure(message: "Cannot allocate conversion buffer.") }
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if end { state.pointee = .endOfStream; return nil }
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            if output.frameLength > 0 { try write(output, lane: lane) }
            if status == .error { throw RecorderFailure(message: "Audio conversion failed.") }
            if status == .endOfStream || status == .inputRanDry { return }
            if output.frameLength == 0 { return }
        }
        throw RecorderFailure(message: "Audio converter exceeded its bounded work limit.")
    }
    func consume(_ sample: CMSampleBuffer, source: String) throws {
        guard !closed, let lane = lanes[source], CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) > 0 else { return }
        guard let description = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description), let format = AVAudioFormat(streamDescription: asbd) else { throw RecorderFailure(message: "Unsupported input audio format.") }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard pts.isFinite else { throw RecorderFailure(message: "Capture returned an invalid audio timestamp.") }
        // More than two input frames is a real timestamp discontinuity; do not
        // silently concatenate across a missing interval or hide an overlap.
        let delta = lane.nextPTS.map { pts - $0 }
        let discontinuity = delta.map { abs($0) > 2 / format.sampleRate } ?? false
        let formatChanged = lane.inputFormat != nil && lane.inputFormat != format
        if discontinuity || formatChanged {
            try convert(nil, lane: lane, end: true); try closeSegment(lane)
            receipt.events?.append(CaptureEvent(source: source, offsetSeconds: max(0, pts - hostStart),
                kind: discontinuity ? "timestampDiscontinuity" : "formatChange", deltaSeconds: delta))
            lane.inputFormat = nil; lane.converter = nil; lane.conversionBuffer = nil
        }
        if lane.inputFormat == nil {
            let rate = settings.sampleRate == 0 ? format.sampleRate : Double(settings.sampleRate)
            guard rate.isFinite, rate.rounded() == rate, (8000...192000).contains(rate) else {
                throw RecorderFailure(message: "The captured sample rate is unsupported. Choose 48 kHz or 44.1 kHz.")
            }
            if settings.scheme.codec <= UInt32(WAM_AUDIO_ALAC) && rate != 44100 && rate != 48000 {
                throw RecorderFailure(message: "This compressed format supports 44.1 or 48 kHz. Choose one of those rates or PCM to preserve the captured rate.")
            }
            lane.sampleRate = Int(rate)
            lane.direct = settings.scheme == .float32 && format.commonFormat == .pcmFormatFloat32 &&
                format.sampleRate == rate && format.channelCount == UInt32(lane.channels) &&
                (format.isInterleaved || lane.channels == 1)
            if !lane.direct {
                let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                    channels: AVAudioChannelCount(lane.channels), interleaved: true)!
                guard let converter = AVAudioConverter(from: format, to: target),
                      let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
                    throw RecorderFailure(message: "Cannot convert this device's audio format.")
                }
                lane.converter = converter; lane.conversionBuffer = output
            }
            lane.inputFormat = format; lane.offset = max(0, pts - hostStart)
        }
        lane.nextPTS = pts + Double(CMSampleBufferGetNumSamples(sample)) / format.sampleRate
        var required = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &required, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard status == noErr else { throw RecorderFailure(message: "Cannot size captured audio (\(status)).") }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: required, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: required, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &retained)
        guard status == noErr, let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { throw RecorderFailure(message: "Cannot read captured audio (\(status)).") }
        pcm.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        try withExtendedLifetime(retained) {
            if lane.direct { try write(pcm, lane: lane) }
            else { try convert(pcm, lane: lane) }
        }
        if Date().timeIntervalSince(lastDiskCheck) > 15 {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
            guard (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0 > 256 * 1024 * 1024 else { throw RecorderFailure(message: "Recording stopped because less than 256 MB of disk space remains.") }
            lastDiskCheck = Date()
        }
        if Date().timeIntervalSince(lastManifest) > 10 { try saveManifest() }
    }
    func finish(failure: String? = nil) throws {
        guard !closed else { return }; closed = true
        var firstError: Error?
        for lane in lanes.values {
            do { try convert(nil, lane: lane, end: true); try closeSegment(lane) }
            catch { firstError = firstError ?? error }
        }
        receipt.endedAt = Date(); receipt.failure = failure ?? firstError?.localizedDescription
        receipt.status = receipt.failure == nil ? "completed" : "interrupted"
        try saveManifest()
        var lines = ["WAM recording report", "Status: \(receipt.status)", "Format: \(settings.scheme.title)",
            "Files are separate source tracks. Use start offsets to align them; gaps are not filled with invented audio."]
        for (source, device) in receipt.inputDevices ?? [:] { lines.append("\(source) device: \(device)") }
        if let failure = receipt.failure { lines.append("Failure: \(failure)") }
        for segment in receipt.segments {
            lines.append("\(segment.file): \(segment.completed ? "saved" : "incomplete"), \(segment.frames) frames, \(segment.sampleRate) Hz, \(segment.channels) channels, offset \(segment.startOffsetSeconds)s")
            lines.append("  Resampled: \(segment.resampled == true); channel conversion: \(segment.remixed == true); direct Float32: \(segment.directFloat32 == true); peak before limiting: \(segment.peakMagnitude ?? 0); limited: \(segment.limited == true)")
        }
        for event in receipt.events ?? [] { lines.append("\(event.source): \(event.kind) at \(event.offsetSeconds)s; timestamp delta \(event.deltaSeconds ?? 0)s") }
        lines.append("Float32 preserves finite over-range samples. PCM16/ALAC16 quantize to 16 bits. AAC is lossy. Capture-device or OS processing before the app is not verified by this report.")
        try Data(lines.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("Recording report.txt"), options: .atomic)
        if let firstError { throw firstError }
    }
}
