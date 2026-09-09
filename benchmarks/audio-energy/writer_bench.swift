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

private func usage() -> (Double, UInt64) {
    var cpu = rusage(); getrusage(RUSAGE_SELF, &cpu)
    var info = rusage_info_v6()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pid_rusage(getpid(), RUSAGE_INFO_V6, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
    }
    return (Double(cpu.ru_utime.tv_sec + cpu.ru_stime.tv_sec) + Double(cpu.ru_utime.tv_usec + cpu.ru_stime.tv_usec) / 1e6,
            status == 0 ? info.ri_energy_nj : 0)
}
@main struct WriterBenchmark {
    static func main() throws {
        // Precompute outside timing. Accelerated throughput only, never battery power.
        let seconds = 300, rate = Int(CommandLine.arguments.dropFirst().first ?? "48000")!
        let channels: UInt32 = 1
        let start = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        var samples: [CMSampleBuffer] = []
        for offset in stride(from: 0, to: seconds * rate, by: 1024) {
            samples.append(try makeSample(frames: min(1024, seconds * rate - offset), rate: Double(rate), channels: channels,
                pts: start + Double(offset) / Double(rate), phase: offset, interleaved: false))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wam-writer-bench-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = RecordingSettings(); settings.systemAudio = false; settings.sampleRate = 48000
        let before = usage(), clock = ProcessInfo.processInfo.systemUptime
        let writer = try RecordingWriter(settings: settings, rootOverride: root)
        for sample in samples { try autoreleasepool { try writer.consume(sample, source: "Microphone") } }
        try writer.finish()
        let wall = ProcessInfo.processInfo.systemUptime - clock, after = usage()
        let frames = writer.receipt.segments.reduce(UInt64(0)) { $0 + $1.frames }
        try require(abs(Int64(frames) - Int64(seconds * 48000)) <= 2, "frame loss")
        let row: [String: Any] = ["input_rate": rate, "output_rate": 48000, "audio_seconds": seconds,
            "cpu_seconds": after.0 - before.0, "wall_seconds": wall, "process_energy_nj": after.1 - before.1,
            "bytes": writer.bytes, "frames": frames, "measurement": "accelerated writer throughput, not real-time power"]
        print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
