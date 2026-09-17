import SwiftUI
import AppKit

struct RecorderWindowContent: View {
    @ObservedObject var model: RecorderModel
    @StateObject private var library = RecordingLibrary()
    @State private var selected: String?
    @State private var query = ""
    private var filteredRecordings: [SavedRecording] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return library.recordings }
        return library.recordings.filter {
            "\($0.folder.lastPathComponent) \($0.receipt.startedAt.formatted(date: .abbreviated, time: .shortened)) \($0.sources.joined(separator: " ")) \($0.receipt.settings.scheme.title)".localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $model.showingRecordings) {
                Text("Record").tag(false)
                Text("Recordings").tag(true)
            }.pickerStyle(.segmented).padding(16)
            if model.showingRecordings {
                recordingsView
            } else {
                ScrollView { RecorderPanel(model: model).frame(maxWidth: .infinity) }
            }
        }
        .onChange(of: model.showingRecordings) { _, visible in
            if visible { library.refresh(currentFolder: model.settings.folderPath) }
        }
        .onChange(of: model.busy) { _, busy in
            if !busy && model.showingRecordings { library.refresh(currentFolder: model.settings.folderPath) }
        }
        .onAppear { if model.showingRecordings { library.refresh(currentFolder: model.settings.folderPath) } }
    }
    private var recordingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recordings").font(.title2).bold()
                Spacer()
                Button("Open save folder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.folderPath)) }
                Button { library.refresh(currentFolder: model.settings.folderPath) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh recordings").disabled(library.loading)
            }
            TextField("Filter by date, source or format", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter recordings")
            if let notice = library.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if library.loading && library.recordings.isEmpty { ProgressView("Loading recordings…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if library.recordings.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "waveform", description: Text("Saved sessions appear here. Choose Record to start a session."))
            } else {
                List(filteredRecordings, selection: $selected) { recording in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recording.receipt.startedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        Text("\(recording.sources.joined(separator: " + ")) · \(recording.receipt.settings.scheme.title)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(recording.id).padding(.vertical, 3)
                }.listStyle(.inset).frame(minHeight: 110)
                if let recording = library.recordings.first(where: { $0.id == selected }) {
                    HStack {
                        Text(recording.receipt.status == "completed" ? "Saved session" : "Incomplete session · saved checkpoints only").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recording.folder.path) }
                    }
                    ForEach(recording.sources, id: \.self) { source in
                        HStack {
                            Text(source)
                            Spacer()
                            Text(clockText(recording.duration(for: source))).monospacedDigit().foregroundStyle(.secondary)
                            Button { library.play(recording, source: source) } label: { Label("Play", systemImage: "play.fill") }
                                .accessibilityLabel("Play \(source)")
                        }
                    }
                    if recording.sources.isEmpty { Text("No completed audio checkpoints yet.").foregroundStyle(.secondary) }
                } else { Text("Select a session to play or reveal its files.").font(.caption).foregroundStyle(.secondary) }
            }
            if !library.title.isEmpty {
                Divider()
                HStack {
                    Button { library.skip(-1) } label: { Image(systemName: "backward.end.fill") }.disabled(library.part == 0).accessibilityLabel("Previous checkpoint")
                    Button { library.togglePlayback() } label: { Image(systemName: library.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(library.playing ? "Pause playback" : "Resume playback")
                    Button { library.skip(1) } label: { Image(systemName: "forward.end.fill") }.disabled(library.part + 1 >= library.partCount).accessibilityLabel("Next checkpoint")
                    Text("\(library.title) · \(library.part + 1) of \(library.partCount)").font(.caption)
                    Spacer()
                    Button("Stop") { library.stop() }
                }
                Slider(value: Binding(get: { library.position }, set: { library.seek($0) }), in: 0...max(0.01, library.duration)).accessibilityLabel("Playback position")
                HStack { Text(clockText(library.position)); Spacer(); Text(clockText(library.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("Checkpoints play in order. Timing gaps are not filled.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = library.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }.padding([.horizontal, .bottom], 16)
        .onChange(of: selected) { _, _ in library.stop() }
    }
    private func clockText(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}
