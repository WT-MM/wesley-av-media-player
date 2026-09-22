import AVFoundation
import Accelerate

// Decode in fixed-size chunks; retain only a compact peak envelope, not the audio.
enum AudioWaveform {
    static func peaks(url: URL, bins: Int = 600) throws -> [Float] {
        guard bins > 0, bins <= 4096 else { throw RecorderFailure(message: "Invalid waveform resolution.") }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0 else { return [] }
        guard file.processingFormat.channelCount <= 8,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768) else {
            throw RecorderFailure(message: "Unsupported waveform audio layout.")
        }
        let count = min(bins, Int(file.length))
        var peaks = [Float](repeating: 0, count: count)
        var position: Int64 = 0
        while position < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            var offset = 0
            while offset < frames {
                let absolute = position + Int64(offset)
                let bin = min(count - 1, Int(absolute * Int64(count) / file.length))
                let boundary = (Int64(bin + 1) * file.length + Int64(count) - 1) / Int64(count)
                let length = min(frames - offset, max(1, Int(boundary - absolute)))
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    var peak: Float = 0
                    vDSP_maxmgv(channels[channel].advanced(by: offset), 1, &peak, vDSP_Length(length))
                    if peak.isFinite { peaks[bin] = max(peaks[bin], peak) }
                }
                offset += length
            }
            position += Int64(frames)
        }
        return peaks
    }
}
