import Foundation
import Speech
import AVFoundation
import CoreMedia

// Offline only: never requests asset installation. JSONL events are unbuffered.
func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}
func stamp(_ seconds: Double) -> String {
    let n = max(0, Int((seconds * 1000).rounded()))
    return String(format: "%02d:%02d:%02d,%03d", n/3600000, n/60000%60, n/1000%60, n%1000)
}
@main struct Main {
    static func main() async {
        do {
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) ?? Locale(identifier: "en_US")
            let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            // Asset status is reported to the reserving process; an unreserved
            // process sees an installed asset as merely "supported".
            try await AssetInventory.reserve(locale: locale)
            let status = await AssetInventory.status(forModules: [module])
            let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
            emit(["event": "assets", "available": SpeechTranscriber.isAvailable,
                  "status": String(describing: status), "locale": locale.identifier,
                  "installedLocales": installed])
            // status(forModules:) stays "supported" for an asset another process
            // installed; installedLocales is what the transcriber consults.
            let ready = status == .installed || installed.contains(locale.identifier)
            guard SpeechTranscriber.isAvailable && ready else {
                emit(["event": "blocked", "reason": "On-device en-US asset unavailable; no download attempted. App must reserve locale, request AssetInventory.assetInstallationRequest(supporting:), and call downloadAndInstall with progress before use."])
                exit(78)
            }
            if CommandLine.arguments.contains("--probe") { return }
            guard CommandLine.arguments.count == 3 else { exit(64) }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
            let analyzer = SpeechAnalyzer(modules: [module])
            let reader = Task { () throws -> [(Double, Double, String)] in
                var final: [(Double, Double, String)] = []
                for try await result in module.results {
                    let start = result.range.start.seconds
                    let end = CMTimeRangeGetEnd(result.range).seconds
                    let text = String(result.text.characters)
                    emit(["event": "segment", "start": start, "end": end, "text": text, "final": result.isFinal])
                    if result.isFinal { final.append((start, end, text)) }
                }
                return final
            }
            let start = ProcessInfo.processInfo.systemUptime
            try await analyzer.prepareToAnalyze(in: file.processingFormat)
            emit(["event": "prepared", "seconds": ProcessInfo.processInfo.systemUptime - start])
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let segments = try await reader.value
            let base = CommandLine.arguments[2]
            try segments.map(\.2).joined(separator: " ").write(toFile: base + ".txt", atomically: true, encoding: .utf8)
            let srt = segments.enumerated().map { i, s in "\(i+1)\n\(stamp(s.0)) --> \(stamp(s.1))\n\(s.2)\n" }.joined(separator: "\n")
            try srt.write(toFile: base + ".srt", atomically: true, encoding: .utf8)
        } catch {
            emit(["event": "error", "reason": String(describing: error)])
            exit(1)
        }
    }
}
