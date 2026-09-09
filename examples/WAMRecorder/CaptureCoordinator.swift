import Foundation
import AVFoundation
import CoreAudio

final class CaptureCoordinator: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let audioQueue = DispatchQueue(label: "org.wam.recorder.audio", qos: .utility)
    private let controlQueue = DispatchQueue(label: "org.wam.recorder.control", qos: .utility)
    private var microphone: AVCaptureSession?
    private var systemCapture: CoreAudioSystemCapture?
    private var writer: RecordingWriter?
    private var failed = false
    private var lastUpdate = Date.distantPast
    var onFailure: ((String) -> Void)?
    var onProgress: (([String: UInt64], [String: Double]) -> Void)?
    private(set) var directory: URL?

    func start(settings: RecordingSettings) async throws {
        if settings.microphone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw RecorderFailure(message: "Microphone access is off. Enable WAM Recorder in System Settings → Privacy & Security → Microphone.") }
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async {
                do {
                    let writer = try RecordingWriter(settings: settings)
                    self.writer = writer; self.directory = writer.directory; self.failed = false
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        do {
            try Task.checkCancellation()
            if settings.microphone {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    controlQueue.async {
                        do {
                            let device = settings.deviceID.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.first { $0.uniqueID == settings.deviceID }
                            guard let device else { throw RecorderFailure(message: "The selected microphone is disconnected. Choose an available input.") }
                            self.audioQueue.sync { self.writer?.receipt.inputDevices?["Microphone"] = device.localizedName }
                            let session = AVCaptureSession(); session.beginConfiguration()
                            let input = try AVCaptureDeviceInput(device: device)
                            guard session.canAddInput(input) else { throw RecorderFailure(message: "Cannot use the selected microphone.") }
                            session.addInput(input)
                            let output = AVCaptureAudioDataOutput()
                            guard session.canAddOutput(output) else { throw RecorderFailure(message: "Cannot create microphone audio output.") }
                            session.addOutput(output); output.setSampleBufferDelegate(self, queue: self.audioQueue)
                            session.commitConfiguration(); self.microphone = session; session.startRunning()
                            guard session.isRunning else { throw RecorderFailure(message: "Microphone capture did not start.") }
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
            try Task.checkCancellation()
            if settings.systemAudio {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    controlQueue.async {
                        do {
                            let capture = CoreAudioSystemCapture(deliveryQueue: self.audioQueue,
                                onSample: { [weak self] sample in self?.accept(sample, source: "System audio") },
                                onFailure: { [weak self] message in self?.fail(message) })
                            self.systemCapture = capture
                            try capture.start(channels: settings.systemChannels,
                                silenceProbe: CommandLine.arguments.contains("--benchmark-output") && CommandLine.arguments.contains("--benchmark-silent-tap"))
                            self.audioQueue.sync { self.writer?.receipt.inputDevices?["System audio"] = capture.deviceDescription }
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                try Task.checkCancellation()
            }
        } catch {
            try? await stop(failure: error.localizedDescription)
            throw error
        }
    }
    func stop(failure: String? = nil) async throws {
        var stopError: Error?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                do { try self.systemCapture?.stop() } catch { stopError = error }
                self.systemCapture = nil
                self.microphone?.stopRunning(); self.microphone = nil
                continuation.resume()
            }
        }
        let message = failure ?? stopError?.localizedDescription
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async {
                do {
                    try self.writer?.finish(failure: message)
                    self.writer = nil
                    continuation.resume()
                } catch { self.writer = nil; continuation.resume(throwing: error) }
            }
        }
        if let stopError, failure == nil { throw stopError }
    }
    private func accept(_ buffer: CMSampleBuffer, source: String) {
        guard !failed, let writer else { return }
        do {
            try writer.consume(buffer, source: source)
            if Date().timeIntervalSince(lastUpdate) >= 1 {
                lastUpdate = Date(); let frames = writer.lanes.mapValues { $0.totalFrames }; let durations = writer.lanes.mapValues { $0.totalSeconds }
                DispatchQueue.main.async { self.onProgress?(frames, durations) }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ message: String) {
        guard !failed else { return }; failed = true
        DispatchQueue.main.async { self.onFailure?(message) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        accept(sampleBuffer, source: "Microphone")
    }
}
