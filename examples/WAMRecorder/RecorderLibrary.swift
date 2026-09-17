import SwiftUI
import AppKit
import AVFoundation

struct SavedRecording: Identifiable {
    let folder: URL
    let receipt: SessionReceipt
    var id: String { folder.path }
    var sources: [String] { Array(Set(receipt.segments.filter(\.completed).map(\.source))).sorted() }
    func segments(for source: String) -> [SegmentReceipt] { receipt.segments.filter { $0.completed && $0.source == source } }
    func duration(for source: String) -> Double {
        segments(for: source).reduce(0) { $0 + Double($1.frames) / Double(max(1, $1.sampleRate)) }
    }
}

@MainActor
final class RecordingLibrary: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var recordings: [SavedRecording] = []
    @Published var loading = false
    @Published var notice: String?
    @Published var error: String?
    @Published var playing = false
    @Published var title = ""
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var part = 0
    @Published var partCount = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var playlist: [URL] = []
    private var refreshID = UUID()

    func refresh(currentFolder: String) {
        let run = UUID(); refreshID = run; loading = true
        let defaults = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/WAM Recordings").path
        let roots = Set((UserDefaults.standard.stringArray(forKey: "recordingFolders") ?? []) + [currentFolder, defaults])
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([SavedRecording], Int) in
                var found: [SavedRecording] = []; var unreadable = 0
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                for root in roots {
                    let url = URL(fileURLWithPath: root)
                    guard FileManager.default.fileExists(atPath: root) else { continue }
                    do {
                        for folder in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                            let manifest = folder.appendingPathComponent("session.json")
                            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
                            do {
                                let receipt = try decoder.decode(SessionReceipt.self, from: Data(contentsOf: manifest))
                                found.append(SavedRecording(folder: folder, receipt: receipt))
                            } catch { unreadable += 1 }
                        }
                    } catch { unreadable += 1 }
                }
                return (found.sorted { $0.receipt.startedAt > $1.receipt.startedAt }, unreadable)
            }.value
            guard refreshID == run else { return }
            var seen = Set<String>()
            recordings = result.0.filter { seen.insert($0.id).inserted }
            notice = result.1 == 0 ? nil : "Some recording folders could not be read. Open the save folder in Finder to inspect them."
            loading = false
        }
    }
    func play(_ recording: SavedRecording, source: String) {
        stop(); error = nil
        let segments = recording.segments(for: source)
        guard !segments.isEmpty else { return }
        guard segments.allSatisfy({ !$0.file.isEmpty && $0.file != "." && $0.file != ".." && !$0.file.contains("/") }) else {
            error = "This session contains an invalid audio file path."; return
        }
        playlist = segments.map { recording.folder.appendingPathComponent($0.file) }
        title = source; partCount = playlist.count; loadPart(0)
    }
    private func loadPart(_ index: Int) {
        guard playlist.indices.contains(index) else { stop(); return }
        timer?.invalidate(); timer = nil; player?.stop(); playing = false
        do {
            let next = try AVAudioPlayer(contentsOf: playlist[index])
            next.delegate = self
            guard next.prepareToPlay(), next.play() else { throw RecorderFailure(message: "macOS could not play this audio file.") }
            player = next; part = index; duration = next.duration; position = 0; playing = true
            startTimer()
        } catch { self.error = "Could not play \(playlist[index].lastPathComponent): \(error.localizedDescription)"; stop() }
    }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.position = self?.player?.currentTime ?? 0 }
        }
    }
    func togglePlayback() {
        guard let player else { return }
        if playing { player.pause(); timer?.invalidate(); timer = nil; playing = false }
        else if player.play() { playing = true; startTimer() }
        else { error = "Playback could not resume." }
    }
    func seek(_ value: Double) { player?.currentTime = min(max(0, value), duration); position = player?.currentTime ?? 0 }
    func skip(_ delta: Int) { loadPart(part + delta) }
    func stop() {
        timer?.invalidate(); timer = nil; player?.stop(); player = nil
        playing = false; position = 0; duration = 0; title = ""; playlist = []; part = 0; partCount = 0
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            if !flag { self.error = "Playback was interrupted."; self.stop() }
            else if self.part + 1 < self.playlist.count { self.loadPart(self.part + 1) }
            else { self.playing = false; self.timer?.invalidate(); self.timer = nil; self.position = self.duration }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.error = "Audio decoding failed: \(error?.localizedDescription ?? "unknown error")"; self.stop()
        }
    }
    deinit { timer?.invalidate() }
}
