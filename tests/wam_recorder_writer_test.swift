import Foundation
import AVFoundation
import CoreMedia
import Darwin

func require(_ yes: @autoclosure () -> Bool, _ message: String) throws {
    if !yes() { throw RecorderFailure(message: message) }
}
func makeSample(frames: Int, rate: Double, channels: UInt32, pts: Double, phase: Int) throws -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: true)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
    pcm.frameLength = UInt32(frames)
    for i in 0..<frames { for c in 0..<Int(channels) { pcm.floatChannelData![0][i * Int(channels) + c] = Float(sin(Double(i + phase) * 2 * .pi * (c == 0 ? 440 : 880) / rate) * (phase < 4096 ? 1.2 : 0.2)) } }
    var description: CMAudioFormatDescription?
    try require(CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr, "format description")
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try require(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, "sample creation")
    try require(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList) == noErr, "sample data")
    try require(CMSampleBufferSetDataReady(sample!) == noErr, "sample ready")
    return sample!
}
@main struct WriterTests {
    static func main() throws {
        let seconds = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 12
        let sessions = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1
        let selected = CommandLine.arguments.count > 3 ? AudioScheme(rawValue: CommandLine.arguments[3])! : .float32
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wam-writer-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
                        if selected == .pcm16 || selected == .alac { try require(peak <= 1, "integer formats must clamp safely") }
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
