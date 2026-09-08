import AppKit
import SwiftUI
import WAMKit

private func text<T>(_ field: inout T) -> String {
    withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published var state: UInt32 = UInt32(WAM_EMPTY)
    @Published var status = "Open a local media file"
    @Published var target = "1001/30000"
    private var player: wam_player_t?
    private var closing = false
    private var closeRequest: UInt64 = 0
    private var sought = false
    private var started = false
    private var pendingWrites = 0
    private var writer = DispatchQueue(label: "WAMKitSwiftHost.metrics")
    private var metrics: FileHandle?
    private let env = ProcessInfo.processInfo.environment
    private var measured = false
    private var began = 0.0
    var terminationPending = false

    private(set) var view: WAMPresentationView!
    var canTransport: Bool { !closing && [WAM_READY, WAM_PLAYING, WAM_PAUSED, WAM_SEEKING, WAM_ENDED].contains(Int(state)) }
    var canOpen: Bool { !closing }

    init() {
        var error = wam_error_t()
        guard wam_player_create(&player, &error) == WAM_OK else {
            fatalError(text(&error.name))
        }
        view = Unmanaged<WAMPresentationView>.fromOpaque(wam_player_presentation_view(player)!).takeUnretainedValue()
        wam_player_observe(player, { context, event in
            guard let context, let event else { return }
            MainActor.assumeIsolated {
                Unmanaged<PlayerModel>.fromOpaque(context).takeUnretainedValue().receive(event.pointee)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func begin() {
        guard !started else { return }; started = true
        func hex(_ key: String) -> Bool {
            guard let value = env[key], value.count == 64 else { return false }
            return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        measured = env["WAM_NATIVE_BENCHMARK_TELEMETRY"] == "1"
            && UUID(uuidString: env["WAM_NATIVE_BENCHMARK_RUN_ID"] ?? "") != nil
            && hex("WAM_NATIVE_BENCHMARK_ASSET_SHA256") && hex("WAM_NATIVE_BENCHMARK_CANDIDATE_ID")
        guard measured else { return }
        if let window = NSApp.windows.first {
            window.setFrame(NSRect(x: 2400, y: 1000, width: 480, height: 270), display: false)
            window.orderBack(nil)
        }
        guard let path = env["WAM_PLAYBACK_METRICS_PATH"] else { return }
        writer.async {
            FileManager.default.createFile(atPath: path, contents: nil)
            let handle = FileHandle(forWritingAtPath: path)
            DispatchQueue.main.async {
                self.metrics = handle
                self.began = ProcessInfo.processInfo.systemUptime
                wam_player_set_metrics_enabled(self.player, 1)
                if CommandLine.arguments.count > 1 { self.open(URL(fileURLWithPath: CommandLine.arguments[1])) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.close() }
            }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { self.open(url) }
        }
    }
    func open(_ url: URL) {
        var error = wam_error_t()
        let result = url.path.withCString { wam_player_open_file(player, $0, wam_time_t(value: 0, timescale: 1, reserved: 0), 0, nil, &error) }
        accepted(result, &error)
    }
    func pause(_ paused: Bool) {
        var error = wam_error_t()
        accepted(wam_player_set_paused(player, paused ? 1 : 0, nil, &error), &error)
    }
    func seek() {
        let parts = target.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let value = Int64(parts[0]), value >= 0,
              let scale = Int32(parts[1]), scale > 0 else {
            status = "Enter a nonnegative numerator and positive timescale"; return
        }
        var error = wam_error_t()
        accepted(wam_player_seek(player, wam_time_t(value: value, timescale: scale, reserved: 0), nil, &error), &error)
    }
    func close() {
        guard !closing else { return }; closing = true
        var error = wam_error_t()
        accepted(wam_player_close(player, &closeRequest, &error), &error)
    }
    private func accepted(_ result: UInt32, _ error: inout wam_error_t) {
        if result != WAM_OK { status = "\(text(&error.name)): \(text(&error.detail))" }
    }
    private func receive(_ source: wam_event_t) {
        var event = source
        state = event.snapshot.state
        let names = ["Empty", "Preparing", "Ready", "Playing", "Paused", "Seeking", "Ended", "Stopping", "Failed", "Closed"]
        let refusal = text(&event.error.name)
        status = refusal.isEmpty ? names[min(Int(state), names.count - 1)] : "\(refusal): \(text(&event.error.detail))"
        if measured, let handle = metrics, pendingWrites < 64 {
            var capabilities = wam_capabilities_t()
            capabilities.struct_size = UInt32(MemoryLayout<wam_capabilities_t>.size)
            wam_copy_capabilities(&capabilities)
            let related: [String] = withUnsafeBytes(of: event.error.related_names) { bytes in
                (0..<Int(event.error.related_count)).map { index in
                    String(decoding: bytes[(index * 128)..<((index + 1) * 128)].prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            let row: [String: Any] = [
                "since_open": ProcessInfo.processInfo.systemUptime - began,
                "kind": event.kind, "state": state, "result": event.result,
                "request_id": event.request_id, "generation": event.snapshot.generation,
                "drawn_frames": event.snapshot.drawn_frames, "clock_rate": event.snapshot.clock_rate,
                "clock_valid": event.snapshot.clock_valid, "position": event.snapshot.display_seconds,
                "first_pts_value": event.snapshot.first_pts.value, "first_pts_timescale": event.snapshot.first_pts.timescale,
                "requested_value": event.requested_target.value, "requested_timescale": event.requested_target.timescale,
                "audio_start_value": event.audio_presentation_start.value, "audio_start_timescale": event.audio_presentation_start.timescale,
                "retiring": event.snapshot.retiring, "charged_sessions": capabilities.charged_sessions,
                "refusal": refusal, "related_refusals": related,
                "run_id": env["WAM_NATIVE_BENCHMARK_RUN_ID"]!, "asset_sha256": env["WAM_NATIVE_BENCHMARK_ASSET_SHA256"]!,
                "candidate_id": env["WAM_NATIVE_BENCHMARK_CANDIDATE_ID"]!]
            pendingWrites += 1
            writer.async {
                if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                    handle.write(data); handle.write(Data([10]))
                }
                DispatchQueue.main.async { self.pendingWrites -= 1 }
            }
        }
        if measured, env["WAM_TEST_SEEK_SCRIPT"] != nil, !sought,
           event.kind == WAM_EVENT_METRICS, event.snapshot.display_seconds >= 1 {
            sought = true; seek()
        }
        if closing, event.kind == WAM_EVENT_RESULT, event.request_id == closeRequest {
            let succeeded = event.result == WAM_COMPLETED && event.snapshot.retiring == 0
            wam_player_observe(player, nil, nil)
            wam_player_release(player); player = nil
            if measured {
                let handle = metrics
                writer.async {
                    try? handle?.close()
                    DispatchQueue.main.async { exit(succeeded ? 0 : 1) }
                }
            } else if terminationPending { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }
}

struct Presentation: NSViewRepresentable {
    let view: WAMPresentationView
    func makeNSView(context: Context) -> WAMPresentationView { view }
    func updateNSView(_ view: WAMPresentationView, context: Context) {}
}

struct PlayerContent: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        VStack(spacing: 8) {
            Presentation(view: model.view).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("Open…", action: model.openPanel).disabled(!model.canOpen).keyboardShortcut("o")
                Button("Play") { model.pause(false) }.disabled(!model.canTransport)
                Button("Pause") { model.pause(true) }.disabled(!model.canTransport)
                TextField("Numerator/timescale", text: $model.target).frame(width: 110)
                    .accessibilityLabel("Seek target, numerator over timescale")
                Button("Seek", action: model.seek).disabled(!model.canTransport)
                Button("Close", action: model.close).disabled(!model.canOpen)
            }.controlSize(.small)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.padding(10).frame(minWidth: 460, minHeight: 230)
            .onAppear { DispatchQueue.main.async { model.begin() } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PlayerModel()
    private var window: NSWindow?
    func applicationWillFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["WAM_TEST_BACKGROUND"] == "1" {
            NSApp.setActivationPolicy(.prohibited)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 450),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "WAMKit Swift Host"
        window.contentView = NSHostingView(rootView: PlayerContent(model: model))
        self.window = window
        if ProcessInfo.processInfo.environment["WAM_TEST_BACKGROUND"] == "1" {
            window.setFrame(NSRect(x: 2400, y: 1000, width: 480, height: 270), display: false)
            window.orderBack(nil)
        } else { window.makeKeyAndOrderFront(nil) }
        model.begin()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.state == WAM_PLAYER_CLOSED { return .terminateNow }
        model.terminationPending = true; model.close(); return .terminateLater
    }
}

@main
struct WAMKitSwiftHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
