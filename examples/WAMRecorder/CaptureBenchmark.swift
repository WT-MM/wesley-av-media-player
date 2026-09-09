import Foundation
import Darwin
import AppKit

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
    let steps: [(String, AudioScheme)] = [("idle", .float32), ("microphone", .float32), ("idle", .float32), ("system", .float32), ("idle", .float32), ("both", .float32), ("both", .pcm16), ("both", .aac64), ("idle", .float32)]
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (mode, scheme) in steps {
            model.settings = original; model.settings.scheme = scheme
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
            let initialEnergy = energy(), initialCPU = cpuTime(), start = Date()
            let duration = mode == "idle" ? 25 : 40
            try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
            let elapsed = Date().timeIntervalSince(start), usedEnergy = energy() - initialEnergy, usedCPU = cpuTime() - initialCPU
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
                row["status"] = receipt.status
                // This diagnostic owns these temporary recordings; retain metrics, not captured audio.
                try FileManager.default.removeItem(at: folder)
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
