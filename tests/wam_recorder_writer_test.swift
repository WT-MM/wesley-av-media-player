import Foundation
import AVFoundation
import CoreMedia
import Darwin

func require(_ yes: @autoclosure () -> Bool, _ message: String) throws {
    if !yes() { throw RecorderFailure(message: message) }
}
func makeSample(frames: Int, rate: Double, channels: UInt32, pts: Double, phase: Int, interleaved: Bool = true) throws -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
    pcm.frameLength = UInt32(frames)
    for i in 0..<frames { for c in 0..<Int(channels) { pcm.floatChannelData![interleaved ? 0 : c][interleaved ? i * Int(channels) + c : i] = Float(sin(Double(i + phase) * 2 * .pi * (c == 0 ? 440 : 880) / rate) * (phase < 4096 ? 1.2 : 0.2)) } }
    var description: CMAudioFormatDescription?
    try require(CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr, "format description")
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try require(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, "sample creation")
    try require(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList) == noErr, "sample data")
    try require(CMSampleBufferSetDataReady(sample!) == noErr, "sample ready")
    return sample!
}
func verifyPreservation(root: URL) throws {
    for rate in [16000, 44100, 48000, 96000] {
        for channels in [1, 2] {
            for interleaved in [true, false] {
                var settings = RecordingSettings(); settings.systemAudio = false
                settings.sampleRate = 0; settings.microphoneChannels = channels
                let writer = try RecordingWriter(settings: settings, rootOverride: root)
                let sample = try makeSample(frames: 4096, rate: Double(rate), channels: UInt32(channels), pts: writer.hostStart, phase: 0, interleaved: interleaved)
                try writer.consume(sample, source: "Microphone"); try writer.finish()
                let segment = writer.receipt.segments[0]
                try require(segment.sampleRate == rate && segment.frames == 4096, "native rate or frame count changed")
                try require(segment.resampled == false && segment.remixed == false && segment.limited == false, "unexpected sample processing")
                let file = try AVAudioFile(forReading: writer.directory.appendingPathComponent(segment.file))
                let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
                try file.read(into: decoded)
                for i in 0..<4096 { for c in 0..<channels {
                    let expected = Float(sin(Double(i) * 2 * .pi * (c == 0 ? 440 : 880) / Double(rate)) * 1.2)
                    try require(decoded.floatChannelData![c][i].bitPattern == expected.bitPattern, "Float32 sample changed at \(rate) Hz, channel \(c), frame \(i)")
                } }
                try require(abs(writer.lanes["Microphone"]!.totalSeconds - 4096 / Double(rate)) < 1e-9, "native-rate duration incorrect")
                try require(FileManager.default.fileExists(atPath: writer.directory.appendingPathComponent("Recording report.txt").path), "missing recording report")
            }
        }
    }
    for rate in [8000, 192000] {
        var pcm = RecordingSettings(); pcm.systemAudio = false; pcm.sampleRate = 0; pcm.scheme = .pcm16
        let writer = try RecordingWriter(settings: pcm, rootOverride: root)
        try writer.consume(makeSample(frames: 4096, rate: Double(rate), channels: 1, pts: writer.hostStart, phase: 20000), source: "Microphone")
        try writer.finish()
        let file = try AVAudioFile(forReading: writer.directory.appendingPathComponent(writer.receipt.segments[0].file))
        try require(file.processingFormat.sampleRate == Double(rate) && file.length == 4096, "PCM16 rate boundary failed")
    }
    var settings = RecordingSettings(); settings.systemAudio = false; settings.sampleRate = 0
    let writer = try RecordingWriter(settings: settings, rootOverride: root)
    var pts = writer.hostStart
    for (index, rate) in [44100, 96000, 96000, 96000].enumerated() {
        if index == 2 { pts += 0.05 }
        if index == 3 { pts -= 0.02 }
        try writer.consume(makeSample(frames: 4096, rate: Double(rate), channels: 1, pts: pts, phase: 0), source: "Microphone")
        pts += 4096 / Double(rate)
    }
    try writer.finish()
    try require(writer.receipt.segments.count == 4, "format changes and gaps must split files")
    try require(writer.receipt.events?.count == 3, "missing discontinuity/format events")
    try require(writer.receipt.events?[0].kind == "formatChange", "missing format change")
    try require(abs((writer.receipt.events?[1].deltaSeconds ?? 0) - 0.05) < 1e-6, "gap duration lost")
    try require(abs((writer.receipt.events?[2].deltaSeconds ?? 0) + 0.02) < 1e-6, "overlap duration lost")
    print("PASS bit-exact Float32: 16/44.1/48/96 kHz, mono/stereo, planar/interleaved, over-range peaks; format changes and 50ms gaps/20ms overlaps reported")
}
@main struct WriterTests {
    static func main() throws {
        let seconds = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 12
        let sessions = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1
        let selected = CommandLine.arguments.count > 3 ? AudioScheme(rawValue: CommandLine.arguments[3])! : .float32
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wam-writer-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if selected == .float32 && !CommandLine.arguments.contains("--crash-proof") { try verifyPreservation(root: root) }
        for session in 0..<sessions {
            var settings = RecordingSettings(); settings.scheme = selected
            let writer = try RecordingWriter(settings: settings, rootOverride: root)
            let rates = [44100, 48000]; let names = ["Microphone", "System audio"]
            // One-second interleaving exercises both lanes without buffering an entire recording.
            for second in 0..<seconds {
                for lane in 0..<2 {
                    let rate = rates[lane]
                    for offset in stride(from: 0, to: rate, by: 4096) {
                        try autoreleasepool {
                            let n = min(4096, rate - offset)
                            let sample = try makeSample(frames: n, rate: Double(rate), channels: UInt32(lane + 1), pts: writer.hostStart + Double(second) + Double(offset) / Double(rate), phase: second * rate + offset)
                            try writer.consume(sample, source: names[lane])
                        }
                    }
                }
            }
            if CommandLine.arguments.contains("--crash-proof") {
                print(writer.directory.path); fflush(stdout); _exit(86)
            }
            try writer.finish(); try writer.finish()
            try require(writer.receipt.status == "completed", "final receipt")
            for source in names {
                let segments = writer.receipt.segments.filter { $0.source == source }
                let total = segments.reduce(UInt64(0)) { $0 + $1.frames }
                try require(abs(Int64(total) - Int64(seconds * 48000)) <= 2, "resampled frame count \(source) \(total)")
                for segment in segments {
                    try require(segment.completed, "checkpoint incomplete")
                    let file = try AVAudioFile(forReading: writer.directory.appendingPathComponent(segment.file))
                    try require(file.length == Int64(segment.frames), "decoded length \(file.length) != \(segment.frames)")
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: min(4096, UInt32(file.length)))!
                    try file.read(into: buffer)
                    try require(buffer.frameLength > 0, "empty checkpoint")
                    if segment.file == segments.first?.file {
                        let peak = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
                        if selected == .float32 { try require(peak > 1, "Float32 must preserve capture peaks above full scale") }
                        if selected == .pcm16 || selected == .alac { try require(peak <= 1, "integer formats must clamp safely"); try require(segment.limited == true, "limiting must be reported") }
                    }
                    file.framePosition = max(0, file.length - 4096)
                    try file.read(into: buffer)
                    try require(buffer.frameLength > 0, "missing tail")
                }
            }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("Peak RSS: \(Double(usage.ru_maxrss) / 1_048_576) MiB")
            print("PASS session \(session + 1): \(seconds)s × microphone/system, \(writer.receipt.segments.count) playable checkpoints, \(writer.bytes) bytes; resampling and tail verified")
            try FileManager.default.removeItem(at: writer.directory)
        }
    }
}
