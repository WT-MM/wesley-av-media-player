import Foundation
import AVFoundation
import ScreenCaptureKit

final class CaptureCoordinator: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let audioQueue = DispatchQueue(label: "org.wam.recorder.audio", qos: .utility)
    private let controlQueue = DispatchQueue(label: "org.wam.recorder.control", qos: .utility)
    private var microphone: AVCaptureSession?
    private var stream: SCStream?
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
        var content: SCShareableContent?
        if settings.systemAudio {
            do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
            catch { throw RecorderFailure(message: "System audio access is unavailable. Enable WAM Recorder in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. \(error.localizedDescription)") }
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
                guard let display = content?.displays.first else { throw RecorderFailure(message: "No display is available for the system-audio capture session.") }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                config.sampleRate = settings.sampleRate == 0 ? 48000 : settings.sampleRate; config.channelCount = settings.systemChannels
                // Only audio output is registered. Minimize unused visual work; no video is saved.
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1); config.queueDepth = 3
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                self.stream = stream
                try await stream.startCapture()
                try Task.checkCancellation()
            }
        } catch {
            try? await stop(failure: error.localizedDescription)
            throw error
        }
    }
    func stop(failure: String? = nil) async throws {
        var stopError: Error?
        if let stream {
            self.stream = nil
            do { try await stream.stopCapture() } catch { stopError = error }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlQueue.async {
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
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { accept(sampleBuffer, source: "System audio") }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        audioQueue.async { self.fail("System audio capture stopped: \(error.localizedDescription)") }
    }
}
