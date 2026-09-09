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
}
struct SessionReceipt: Codable {
    var startedAt: Date
    var endedAt: Date?
    var settings: RecordingSettings
    var status: String
    var failure: String?
    var segments: [SegmentReceipt]
}

// Entire object is confined to CaptureCoordinator's utility queue.
final class RecordingWriter {
    final class Lane {
        let source: String
        let channels: Int
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
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
        var config = wam_audio_file_config_t(struct_size: UInt32(MemoryLayout<wam_audio_file_config_t>.size), sample_rate: UInt32(settings.sampleRate), channels: UInt32(lane.channels), codec: settings.scheme.codec, bitrate: settings.scheme.bitrate * UInt32(lane.channels), require_hardware: 0, reserved: 0)
        var error = wam_error_t()
        let result = directory.appendingPathComponent(name).path.withCString { wam_audio_encoder_create_file(&config, $0, &lane.encoder, &error) }
        try checkWAM(result, &error)
        lane.frames = 0
        lane.receiptIndex = receipt.segments.count
        receipt.segments.append(SegmentReceipt(source: lane.source, file: name, frames: 0, sampleRate: settings.sampleRate, channels: lane.channels, startOffsetSeconds: lane.offset, completed: false))
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
        lane.offset += Double(lane.frames) / Double(settings.sampleRate)
        lane.frames = 0
        try saveManifest()
    }
    private func write(_ buffer: AVAudioPCMBuffer, lane: Lane) throws {
        guard let samples = buffer.floatChannelData?[0] else { throw RecorderFailure(message: "Audio conversion produced no PCM data.") }
        if settings.scheme != .float32 {
            var lower: Float = -1, upper: Float = 1
            vDSP_vclip(samples, 1, &lower, &upper, samples, 1, vDSP_Length(buffer.frameLength) * vDSP_Length(lane.channels))
        }
        var offset = 0
        while offset < Int(buffer.frameLength) {
            if lane.encoder == nil { try open(lane) }
            let limit = UInt64(settings.checkpointMinutes * 60 * settings.sampleRate)
            let count = min(Int(buffer.frameLength) - offset, 4096, Int(limit - lane.frames))
            var error = wam_error_t()
            let result = wam_audio_encoder_write(lane.encoder, samples.advanced(by: offset * lane.channels), UInt32(count), &error)
            try checkWAM(result, &error)
            lane.frames += UInt64(count); lane.totalFrames += UInt64(count); offset += count
            if let index = lane.receiptIndex { receipt.segments[index].frames = lane.frames }
            if lane.frames == limit { try closeSegment(lane) }
        }
    }
    private func convert(_ input: AVAudioPCMBuffer?, lane: Lane, end: Bool = false) throws {
        guard let converter = lane.converter else { return }
        var supplied = false
        for _ in 0..<128 {
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4096) else { throw RecorderFailure(message: "Cannot allocate conversion buffer.") }
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
        if let next = lane.nextPTS, abs(pts - next) > 0.1 {
            try convert(nil, lane: lane, end: true); try closeSegment(lane)
            lane.converter = nil
        }
        if lane.inputFormat != format || lane.converter == nil {
            if lane.converter != nil { try convert(nil, lane: lane, end: true); try closeSegment(lane) }
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(settings.sampleRate), channels: AVAudioChannelCount(lane.channels), interleaved: true)!
            guard let converter = AVAudioConverter(from: format, to: target) else { throw RecorderFailure(message: "Cannot convert this device's audio format.") }
            lane.converter = converter; lane.inputFormat = format; lane.offset = max(0, pts - hostStart)
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
        try withExtendedLifetime(retained) { try convert(pcm, lane: lane) }
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
        if let firstError { throw firstError }
    }
}
