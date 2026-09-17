import Foundation
import AVFoundation
import CoreMedia

func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw RecorderFailure(message: message) }
}
@main struct LibraryTest {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wam-library-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary()
        for scheme in AudioScheme.allCases {
            var settings = RecordingSettings(); settings.systemAudio = false; settings.scheme = scheme
            let writer = try RecordingWriter(settings: settings, rootOverride: root)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: true)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
            buffer.frameLength = 24000
            memset(buffer.mutableAudioBufferList.pointee.mBuffers.mData!, 0, Int(buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize))
            var description: CMAudioFormatDescription?
            try require(CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr, "describe fixture")
            for offset in [0.0, 0.6] { // Intentional gap creates two short completed checkpoints.
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(seconds: writer.hostStart + offset, preferredTimescale: 48000), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                try require(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 24000, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, "create fixture")
                try require(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: buffer.audioBufferList) == noErr, "fixture data")
                CMSampleBufferSetDataReady(sample!)
                try writer.consume(sample!, source: "Microphone")
            }
            try writer.finish()
            let recording = SavedRecording(folder: writer.directory, receipt: writer.receipt)
            try require(recording.segments(for: "Microphone").count == 2, "two checkpoints")
            library.play(recording, source: "Microphone")
            try require(library.playing && library.error == nil && library.partCount == 2, "play \(scheme)")
            library.togglePlayback(); try require(!library.playing, "pause")
            library.seek(0.1); try require(abs(library.position - 0.1) < 0.01, "seek")
            library.togglePlayback(); try require(library.playing, "resume")
            for _ in 0..<60 {
                if !library.playing { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try require(!library.playing && library.part == 1 && library.error == nil, "automatic checkpoint advance and finish \(scheme)")
            for _ in 0..<100 { if !library.waveformLoading { break }; try await Task.sleep(nanoseconds: 20_000_000) }
            try require(library.waveformError == nil && library.waveform.count == 600 && library.waveform.allSatisfy { abs($0) < 0.00001 }, "silent waveform \(scheme)")
            library.skip(-1); try require(library.playing && library.part == 0, "previous checkpoint")
            library.stop(); try require(library.partCount == 0 && !library.playing, "stop")
            print("PASS \(scheme.rawValue): decode, pause, seek, resume, automatic checkpoint advance, previous, stop")
        }
        library.refresh(currentFolder: root.path)
        for _ in 0..<100 { if !library.loading { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        let generated = library.recordings.filter { $0.folder.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") }
        try require(generated.count == 5, "discover all generated sessions (found \(generated.count), loading \(library.loading), notice \(library.notice ?? "none"))")
        let corrupt = root.appendingPathComponent("corrupt"); try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("invalid json".utf8).write(to: corrupt.appendingPathComponent("session.json"))
        library.refresh(currentFolder: root.path)
        for _ in 0..<100 { if !library.loading { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        try require(library.notice != nil, "unreadable session reported")
        var bad = generated[0].receipt; bad.segments[0].file = "../outside.caf"
        library.play(SavedRecording(folder: generated[0].folder, receipt: bad), source: "Microphone")
        try require(library.error != nil && !library.playing, "unsafe path rejected")
        bad.segments[0].file = "missing.caf"
        library.play(SavedRecording(folder: generated[0].folder, receipt: bad), source: "Microphone")
        try require(library.error != nil && !library.playing, "missing file reported")
        print("PASS library discovery, malformed manifest, path validation, and missing-file handling")
        let waveURL = root.appendingPathComponent("waveform.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65537)!; buffer.frameLength = 65537
        for channel in 0..<2 { memset(buffer.floatChannelData![channel], 0, 65537 * 4) }
        buffer.floatChannelData![0][10] = 0.25
        buffer.floatChannelData![1][32768] = -1.2
        buffer.floatChannelData![0][65536] = 0.8
        do { let file = try AVAudioFile(forWriting: waveURL, settings: format.settings); try file.write(from: buffer) }
        let peaks = try AudioWaveform.peaks(url: waveURL, bins: 3)
        try require(peaks.count == 3 && abs(peaks[0] - 0.25) < 0.0001 && abs(peaks[1] - 1.2) < 0.0001 && abs(peaks[2] - 0.8) < 0.0001, "stereo peak envelope, chunk boundary and final frame")
        let gate = DispatchSemaphore(value: 0)
        let cancelled = Task.detached { gate.wait(); return try AudioWaveform.peaks(url: waveURL) }
        cancelled.cancel(); gate.signal()
        do { _ = try await cancelled.value; throw RecorderFailure(message: "cancelled waveform completed") }
        catch is CancellationError { }
        print("PASS waveform: stereo maxima, chunk boundary, final frame, over-range samples, cancellation and all-codec silence")
    }
}
