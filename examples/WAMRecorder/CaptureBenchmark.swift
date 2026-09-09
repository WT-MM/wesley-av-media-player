import Foundation
import Darwin
import AppKit
import AVFoundation

private func energy() -> UInt64 {
    var info = rusage_info_v6()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pid_rusage(getpid(), RUSAGE_INFO_V6, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
    }
    return status == 0 ? info.ri_energy_nj : 0
}
private func cpuTime() -> Double {
    var info = rusage(); getrusage(RUSAGE_SELF, &info)
    return Double(info.ru_utime.tv_sec + info.ru_stime.tv_sec) + Double(info.ru_utime.tv_usec + info.ru_stime.tv_usec) / 1_000_000
}
@MainActor
func runCaptureBenchmark(model: RecorderModel, output: URL) async {
    let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Bounded WAM recording energy benchmark")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let original = model.settings
    model.persistSettings = false
    var rows: [[String: Any]] = []
    var steps: [(String, AudioScheme)] = [("idle", .float32), ("microphone", .float32), ("idle", .float32), ("system", .float32), ("idle", .float32), ("both", .float32), ("both", .pcm16), ("both", .aac64), ("idle", .float32)]
    func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
    let customMode = argument("--benchmark-mode")
    let requestedDuration = argument("--benchmark-seconds").flatMap(Int.init)
    do {
        if let mode = customMode {
            guard ["microphone", "system", "both"].contains(mode),
                  let scheme = AudioScheme(rawValue: argument("--benchmark-scheme") ?? "float32"),
                  let duration = requestedDuration, (30...5400).contains(duration) else {
                throw RecorderFailure(message: "Use --benchmark-mode microphone|system|both, --benchmark-scheme float32|pcm16|alac|aac64|aac96, and --benchmark-seconds 30…5400.")
            }
            steps = CommandLine.arguments.contains("--benchmark-capture-only") ? [(mode, scheme)] : [("idle", scheme), (mode, scheme), ("idle", scheme)]
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (mode, scheme) in steps {
            model.settings = original; model.settings.scheme = scheme
            // Pin comparison settings; never inherit unrelated persisted channel/rate choices.
            model.settings.sampleRate = 48000; model.settings.microphoneChannels = 1
            model.settings.systemChannels = 2; model.settings.checkpointMinutes = 5
            if let channels = argument("--benchmark-system-channels") {
                guard let count = Int(channels), (1...2).contains(count) else { throw RecorderFailure(message: "Benchmark system channels must be 1 or 2.") }
                model.settings.systemChannels = count
            }
            if let name = argument("--benchmark-device-name") {
                let matches = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.filter { $0.localizedName == name }
                guard matches.count == 1 else { throw RecorderFailure(message: "Benchmark microphone name must match exactly one connected device.") }
                model.settings.deviceID = matches[0].uniqueID
            }
            model.settings.microphone = mode == "microphone" || mode == "both"
            model.settings.systemAudio = mode == "system" || mode == "both"
            model.settings.folderPath = output.appendingPathComponent("temporary-audio").path
            if mode != "idle" {
                model.start()
                for _ in 0..<240 {
                    if model.state != .starting { break }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                guard model.state == .recording else { throw RecorderFailure(message: model.failure ?? "Capture did not start before the benchmark timeout.") }
            }
            // Keep creation/TCC costs outside the steady recording measurement.
            try await Task.sleep(nanoseconds: 5_000_000_000)
            print("CAPTURE BENCHMARK WINDOW: \(mode) / \(scheme.rawValue)"); fflush(stdout)
            let initialEnergy = energy(), initialCPU = cpuTime(), start = Date(), uptime = ProcessInfo.processInfo.systemUptime
            let duration = customMode == nil ? (mode == "idle" ? 25 : 40) : requestedDuration!
            try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
            let elapsed = ProcessInfo.processInfo.systemUptime - uptime, finalEnergy = energy(), usedCPU = cpuTime() - initialCPU
            // Idle timers can be coalesced by several seconds. Use the actual
            // measured interval; reject large scheduling outliers and suspend.
            let wallElapsed = Date().timeIntervalSince(start)
            let allowedDelay = max(60.0, Double(duration) * 0.10)
            guard elapsed >= Double(duration) - 0.1, elapsed - Double(duration) <= allowedDelay,
                  abs(wallElapsed - elapsed) < 2, finalEnergy >= initialEnergy,
                  initialEnergy > 0, finalEnergy > 0 else {
                throw RecorderFailure(message: "Benchmark interval invalid: expected \(duration)s, uptime \(elapsed)s, wall \(wallElapsed)s, energy \(initialEnergy)…\(finalEnergy). Repeat this block.")
            }
            let usedEnergy = finalEnergy - initialEnergy
            if mode != "idle" {
                guard model.state == .recording else { throw RecorderFailure(message: model.failure ?? "Capture stopped during benchmark.") }
                await model.stop()
                if let failure = model.failure { throw RecorderFailure(message: failure) }
            }
            var row: [String: Any] = ["mode": mode, "scheme": scheme.rawValue, "start_unix": start.timeIntervalSince1970, "wall_seconds": elapsed, "process_energy_nj": usedEnergy, "process_power_mw": Double(usedEnergy) / 1_000_000 / elapsed, "cpu_percent_one_core": usedCPU / elapsed * 100, "frames": model.frames]
            if mode != "idle", let folder = model.lastFolder {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let receipt = try decoder.decode(SessionReceipt.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
                row["segments"] = receipt.segments.count
                row["capture_events"] = receipt.events?.count ?? 0
                row["input_devices"] = receipt.inputDevices ?? [:]
                row["bytes"] = try receipt.segments.reduce(UInt64(0)) { total, segment in
                    total + ((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(segment.file).path)[.size] as? NSNumber)?.uint64Value ?? 0)
                }
                row["formats"] = receipt.segments.map { ["source": $0.source, "rate": $0.sampleRate, "channels": $0.channels,
                    "resampled": $0.resampled ?? false, "remixed": $0.remixed ?? false, "limited": $0.limited ?? false, "peak": $0.peakMagnitude ?? 0] as [String: Any] }
                guard (receipt.events ?? []).isEmpty else { throw RecorderFailure(message: "Capture had timestamp or format discontinuities; reject and inspect this benchmark block.") }
                for source in (model.settings.microphone ? ["Microphone"] : []) + (model.settings.systemAudio ? ["System audio"] : []) {
                    let captured = receipt.segments.filter { $0.source == source && $0.completed }.reduce(0.0) { $0 + Double($1.frames) / Double($1.sampleRate) }
                    guard captured >= elapsed * 0.99 else { throw RecorderFailure(message: "Insufficient captured audio for \(source); reject this benchmark block.") }
                }
                if CommandLine.arguments.contains("--benchmark-silent-tap"), model.settings.systemAudio {
                    guard receipt.segments.filter({ $0.source == "System audio" }).allSatisfy({ $0.peakMagnitude == 0 }) else {
                        throw RecorderFailure(message: "The diagnostic silent tap unexpectedly captured a nonzero signal.")
                    }
                    row["diagnostic_silent_tap"] = true
                }
                row["status"] = receipt.status
                // This diagnostic owns these temporary recordings; retain metrics, not captured audio.
                if !CommandLine.arguments.contains("--benchmark-retain-audio") { try FileManager.default.removeItem(at: folder) }
                model.lastFolder = nil
            }
            rows.append(row)
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("capture-results.json"), options: .atomic)
            print("CAPTURE BENCHMARK: \(mode) / \(scheme.rawValue): \(row["process_power_mw"]!) mW", terminator: "\n")
        }
        model.message = "Energy benchmark completed"
    } catch {
        if model.busy { await model.stop(reason: error.localizedDescription) }
        try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("capture-error.txt"))
        model.failure = error.localizedDescription
        model.message = "Energy benchmark needs attention"
    }
    model.settings = original; model.persistSettings = true
    NSApp.terminate(nil)
}
