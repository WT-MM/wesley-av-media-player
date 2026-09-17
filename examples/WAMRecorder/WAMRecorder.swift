import SwiftUI
import AppKit
import AVFoundation

@MainActor
final class RecorderModel: ObservableObject {
    enum State { case idle, starting, recording, stopping }
    @Published var settings: RecordingSettings {
        didSet { if persistSettings, let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") } }
    }
    var persistSettings = true
    @Published var globalShortcutEnabled = UserDefaults.standard.object(forKey: "globalShortcutEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(globalShortcutEnabled, forKey: "globalShortcutEnabled")
            RecorderAppDelegate.shared?.configureShortcut()
        }
    }
    @Published var shortcutChoice = UserDefaults.standard.string(forKey: "recordingShortcutChoice").flatMap(RecordingShortcutChoice.init(rawValue:)) ?? .commandControl9 {
        didSet {
            UserDefaults.standard.set(shortcutChoice.rawValue, forKey: "recordingShortcutChoice")
            RecorderAppDelegate.shared?.configureShortcut()
        }
    }
    @Published var shortcutStatus = ""
    @Published var globalShortcutRegistered = false
    @Published var showingRecordings = false
    @Published var state: State = .idle
    @Published var message = "Ready to record"
    @Published var failure: String?
    @Published var devices: [AVCaptureDevice] = []
    @Published var startDate: Date?
    @Published var lastFolder: URL?
    @Published var capturedSeconds: [String: Double] = [:]
    @Published var frames: [String: UInt64] = [:]
    private var startupTask: Task<Void, Never>?
    private var generation = UUID()
    private var coordinator: CaptureCoordinator?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    var busy: Bool { state != .idle }
    var storageEstimate: String {
        if settings.sampleRate == 0 && settings.scheme.bitrate == 0 { return "Storage depends on the captured sample rate. Each file records its actual format." }
        let channels = (settings.microphone ? settings.microphoneChannels : 0) + (settings.systemAudio ? settings.systemChannels : 0)
        let bytes: Double
        switch settings.scheme {
        case .float32: bytes = Double(settings.sampleRate * channels * 4) * 5400
        case .pcm16: bytes = Double(settings.sampleRate * channels * 2) * 5400
        case .aac64, .aac96: bytes = Double(settings.scheme.bitrate) * Double(channels) / 8 * 5400
        case .alac: return "Lossless file size depends on the captured audio."
        }
        return String(format: "About %.2f GB per 90 minutes with these sources.", bytes / 1_000_000_000)
    }

    init() {
        settings = UserDefaults.standard.data(forKey: "settings").flatMap { try? JSONDecoder().decode(RecordingSettings.self, from: $0) } ?? RecordingSettings()
        refreshDevices()
        Task { @MainActor in RecorderAppDelegate.shared?.attach(self) }
        if let index = CommandLine.arguments.firstIndex(of: "--benchmark-output"), CommandLine.arguments.count > index + 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await runCaptureBenchmark(model: self, output: url) }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.state == .recording { await self?.stop(reason: "The Mac is going to sleep. Completed audio was saved.") } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main) { [weak self] note in
            let description = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Microphone capture was interrupted."
            Task { @MainActor in if self?.state == .recording { await self?.stop(reason: description) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                self?.refreshDevices()
                guard let self, self.state == .recording, self.settings.microphone, let device = note.object as? AVCaptureDevice else { return }
                if self.settings.deviceID.isEmpty || self.settings.deviceID == device.uniqueID { await self.stop(reason: "An audio device disconnected. Completed audio was saved.") }
            }
        })
    }
    func refreshDevices() { devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices }
    func start() {
        guard !busy, settings.microphone || settings.systemAudio else { return }
        RecorderAppDelegate.shared?.model = self
        state = .starting; failure = nil; message = "Preparing recording…"; frames = [:]; capturedSeconds = [:]
        let coordinator = CaptureCoordinator(); self.coordinator = coordinator
        coordinator.onFailure = { [weak self] message in Task { @MainActor in await self?.stop(reason: message) } }
        coordinator.onProgress = { [weak self] frames, durations in self?.frames = frames; self?.capturedSeconds = durations }
        if persistSettings {
            var roots = UserDefaults.standard.stringArray(forKey: "recordingFolders") ?? []
            if !roots.contains(settings.folderPath) { roots.append(settings.folderPath) }
            UserDefaults.standard.set(roots, forKey: "recordingFolders")
        }
        let chosen = settings
        let run = UUID(); generation = run
        startupTask = Task {
            do {
                try await coordinator.start(settings: chosen)
                try Task.checkCancellation()
                guard generation == run else { try? await coordinator.stop(); return }
                activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Saving an audio recording")
                lastFolder = coordinator.directory; startDate = Date(); state = .recording; message = "Recording"
            } catch {
                try? await coordinator.stop(failure: error.localizedDescription)
                guard generation == run else { return }
                self.coordinator = nil; state = .idle; message = "Recording did not start"; failure = error.localizedDescription
            }
        }
    }
    func stop(reason: String? = nil) async {
        guard state == .recording || state == .starting else { return }
        generation = UUID()
        state = .stopping; message = "Finishing audio files…"
        startupTask?.cancel()
        await startupTask?.value
        startupTask = nil
        do { try await coordinator?.stop(failure: reason); failure = reason; message = reason == nil ? "Recording saved" : "Recording interrupted" }
        catch { failure = error.localizedDescription; message = "Some audio could not be finalized" }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        coordinator = nil; state = .idle; startDate = nil
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Save recordings here"; panel.directoryURL = URL(fileURLWithPath: settings.folderPath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { settings.folderPath = url.path }
    }
    func showReport() { if let lastFolder { NSWorkspace.shared.open(lastFolder.appendingPathComponent("Recording report.txt")) } }
    func reveal() { if let lastFolder { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: lastFolder.path) } }
}
@MainActor
final class RecorderAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: RecorderAppDelegate?
    override init() { super.init(); Self.shared = self }
    weak var model: RecorderModel?
    private var recorderWindow: NSWindow?
    private var launched = false
    private var redirecting = false
    private var shortcut: GlobalRecordingShortcut?
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--benchmark-output"), let bundle = Bundle.main.bundleIdentifier,
              let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
                .filter({ $0.processIdentifier != getpid() && !$0.isTerminated })
                .sorted(by: { $0.processIdentifier < $1.processIdentifier }).first,
              let url = existing.bundleURL else { return }
        redirecting = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    private var showsWindowOnLaunch: Bool {
        !CommandLine.arguments.contains("--benchmark-output") || CommandLine.arguments.contains("--show-window")
    }
    func attach(_ model: RecorderModel) {
        self.model = model
        if launched && !redirecting { configureShortcut(); if showsWindowOnLaunch { showRecorderWindow() } }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !redirecting else { return }
        launched = true
        NSApp.setActivationPolicy(showsWindowOnLaunch ? .regular : .accessory)
        configureShortcut()
        if showsWindowOnLaunch { showRecorderWindow() }
    }
    func configureShortcut() {
        shortcut?.unregister(); shortcut = nil
        guard launched, !redirecting, let model else { return }
        model.globalShortcutRegistered = false
        guard !CommandLine.arguments.contains("--benchmark-output"), model.globalShortcutEnabled else {
            model.shortcutStatus = "Global shortcut off"; return
        }
        let shortcut = GlobalRecordingShortcut { [weak self] in
            guard let self, let model = self.model else { return }
            switch model.state {
            case .idle:
                model.showingRecordings = false
                self.showRecorderWindow()
                model.start()
            case .recording:
                Task { @MainActor in await model.stop() }
            case .starting, .stopping: break
            }
        }
        let status = shortcut.register(choice: model.shortcutChoice)
        if status == noErr {
            self.shortcut = shortcut
            model.globalShortcutRegistered = true
            model.shortcutStatus = "\(model.shortcutChoice.label) starts / stops recording from any app"
        } else {
            model.shortcutStatus = "\(model.shortcutChoice.label) unavailable (\(status)). Another app may use it. Turn the shortcut off and on to retry."
        }
    }
    func applicationWillTerminate(_ notification: Notification) { shortcut?.unregister() }
    @objc func showRecorderWindow() {
        guard let model else { return }
        if recorderWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "WAM Recorder"
            window.minSize = NSSize(width: 480, height: 460)
            window.contentView = NSHostingView(rootView: RecorderWindowContent(model: model))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("WAMRecorderControls")
            window.center()
            recorderWindow = window
        }
        if recorderWindow?.isMiniaturized == true { recorderWindow?.deminiaturize(nil) }
        recorderWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showRecorderWindow()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Show recorder", action: #selector(showRecorderWindow), keyEquivalent: "")
        item.target = self
        return menu
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        Task { await model.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
struct RecorderPanel: View {
    @ObservedObject var model: RecorderModel
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WAM Recorder").font(.headline)
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let start = model.startDate {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(duration(context.date.timeIntervalSince(start))).font(.title2.monospacedDigit())
                    }
                } else { Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Microphone", isOn: $model.settings.microphone)
                if model.settings.microphone {
                    Picker("Input", selection: $model.settings.deviceID) {
                        Text("System default").tag("")
                        ForEach(model.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }.labelsHidden().accessibilityLabel("Microphone input device")
                }
                Toggle("System audio", isOn: $model.settings.systemAudio)
                Text(model.settings.microphone && model.settings.systemAudio ? "Two source tracks in one session folder." : "Only the selected source will be recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            if let failure = model.failure {
                Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if model.state == .recording {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.frames.keys.sorted(), id: \.self) { source in
                        Text("\(source): \(duration(model.capturedSeconds[source] ?? 0)) captured")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                if model.state == .recording { Task { await model.stop() } } else { model.start() }
            } label: {
                Label(model.state == .recording ? "Stop and save" : "Start recording", systemImage: model.state == .recording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).tint(.red)
                .disabled(model.state == .starting || model.state == .stopping || (!model.settings.microphone && !model.settings.systemAudio))
                .keyboardShortcut(model.globalShortcutRegistered ? nil : KeyboardShortcut(KeyEquivalent(model.shortcutChoice.digit), modifiers: [.command, .control]))
            Text(model.shortcutStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Global recording shortcut", isOn: $model.globalShortcutEnabled).font(.caption)
            Picker("Key combination", selection: $model.shortcutChoice) {
                ForEach(RecordingShortcutChoice.allCases) { Text($0.label).tag($0) }
            }.disabled(!model.globalShortcutEnabled)
            DisclosureGroup("Recording settings", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Format", selection: $model.settings.scheme) { ForEach(AudioScheme.allCases) { Text($0.title).tag($0) } }
                    Text(model.storageEstimate).font(.caption).foregroundStyle(.secondary)
                    Picker("Sample rate", selection: $model.settings.sampleRate) { Text("Preserve captured rate").tag(0); Text("48 kHz").tag(48000); Text("44.1 kHz").tag(44100) }
                    Text("Preserve captured rate avoids app resampling. The report shows each source’s delivered rate; macOS or the device may process audio before capture.").font(.caption).foregroundStyle(.secondary)
                    if model.settings.microphone {
                        Picker("Microphone channels", selection: $model.settings.microphoneChannels) { Text("Mono").tag(1); Text("Stereo").tag(2) }
                    }
                    if model.settings.systemAudio {
                        Picker("System channels", selection: $model.settings.systemChannels) { Text("Mono").tag(1); Text("Stereo").tag(2) }
                    }
                    Picker("File checkpoints", selection: $model.settings.checkpointMinutes) { Text("Every 5 minutes").tag(5); Text("Every 15 minutes").tag(15); Text("Every 90 minutes").tag(90) }
                    Text("Completed checkpoints remain playable after an interruption. The Mac stays awake while recording; closing the lid can still interrupt capture.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Choose save folder…") { model.chooseFolder() }
                    Text(model.settings.folderPath).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    Text("\(model.settings.scheme.title). Native audio processing; no hardware AAC encoder is available on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }.disabled(model.busy)
            Divider()
            HStack {
                Button("Recordings") { model.showingRecordings = true; RecorderAppDelegate.shared?.showRecorderWindow() }
                Button("Show recording") { model.reveal() }.disabled(model.lastFolder == nil)
                Button("Report") { model.showReport() }.disabled(model.lastFolder == nil || model.busy).accessibilityLabel("Open recording quality report")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.buttonStyle(.plain).font(.caption)
        }.padding(20).frame(width: 360)
            .onAppear { model.refreshDevices() }
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let n = max(0, Int(seconds)); return String(format: "%02d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
    }
}
@main
struct WAMRecorderApp: App {
    @NSApplicationDelegateAdaptor(RecorderAppDelegate.self) var delegate
    @StateObject private var model = RecorderModel()
    var body: some Scene {
        MenuBarExtra {
            ScrollView { RecorderPanel(model: model).onAppear { delegate.model = model } }.frame(maxHeight: 750)
        } label: {
            Image(systemName: model.state == .recording ? "record.circle.fill" : "waveform.circle")
                .accessibilityLabel(model.state == .recording ? "WAM Recorder is recording" : "WAM Recorder")
        }.menuBarExtraStyle(.window)
            .commands {
                CommandGroup(after: .windowArrangement) {
                    Button("Show recorder") { delegate.showRecorderWindow() }
                        .keyboardShortcut("0", modifiers: .command)
                }
            }
    }
}
