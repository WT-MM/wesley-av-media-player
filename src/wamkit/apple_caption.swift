import Foundation
import Speech
import AVFoundation
import CoreMedia

// No actor, Task, Swift object or string ownership crosses WAMCaption.h.
public typealias CaptionCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, Int32, Double, Double, Double, Int32, UnsafePointer<CChar>?) -> Void
private final class Session: @unchecked Sendable {
    let callback: CaptionCallback
    let context: UnsafeMutableRawPointer?
    let lock = NSRecursiveLock()
    var task: Task<Void, Never>?
    var core: AnyObject?
    var cancelling = false
    init(_ callback: @escaping CaptionCallback, _ context: UnsafeMutableRawPointer?) {
        self.callback = callback; self.context = context
    }
    func emit(_ generation: UInt64, _ kind: Int32, _ text: String = "", start: Double = 0, end: Double = 0, progress: Double = 0, flags: Int32 = 0) {
        lock.lock(); defer { lock.unlock() }
        text.withCString { callback(context, generation, kind, start, end, progress, flags, $0) }
    }
    func launch(_ generation: UInt64, _ body: @escaping @Sendable () async throws -> Void) {
        lock.lock(); defer { lock.unlock() }
        cancelling = false
        task = Task.detached {
            do { try Task.checkCancellation(); try await body() }
            catch { self.emit(generation, Task.isCancelled ? 7 : 6, String(describing:error)) }
        }
    }
    func cancel() {
        lock.lock()
        if cancelling { lock.unlock(); return }
        cancelling = true
        let active = task; lock.unlock()
        active?.cancel()
        if #available(macOS 26, *), let engine = core as? Engine {
            Task.detached { await engine.cancel() }
        }
    }
}
@available(macOS 26, *)
private actor Engine {
    let session: Session
    var locale: Locale?
    var module: SpeechTranscriber?
    var analyzer: SpeechAnalyzer?
    var reader: Task<Void, Error>?
    var prepared = false
    // Production idle deadline. Query cancels the timer and awaits any close
    // already in progress before reserving/re-preparing the next request.
    var idleVersion: UInt64 = 0
    var idle: Task<Void, Never>?
    var eviction: Task<Void, Never>?
    func armIdle() {
        idle?.cancel()
        idleVersion &+= 1
        let version = idleVersion
        idle = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(30)) } catch { return }
            await self?.evict(version)
        }
    }
    func evict(_ version: UInt64) {
        // Cancellation can arrive after sleep returns but before this actor
        // hop. A stale timer must never close a newly admitted request.
        guard version == idleVersion, idle != nil else { return }
        eviction = Task { await self.close() }
    }
    func resume() async {
        idleVersion &+= 1
        idle?.cancel(); idle = nil
        await eviction?.value; eviction = nil
    }
    var offset: Int64 = 0
    var generation: UInt64 = 0
    var base: Double = 0
    var duration: Double = 0
    init(_ session: Session) { self.session = session }
    func query(_ language: String, _ g: UInt64) async throws {
        await resume()
        guard SpeechTranscriber.isAvailable,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier:language)) else {
            session.emit(g,1,flags:0); return
        }
        if locale != resolved {
            await close()
            locale = resolved
            module = SpeechTranscriber(locale:resolved,preset:.timeIndexedProgressiveTranscription)
        }
        try await AssetInventory.reserve(locale:resolved)
        let ready = await isReady()
        session.emit(g,1,resolved.identifier,flags:ready ? 3 : 5)
    }
    func isReady() async -> Bool {
        guard let m = module, let l = locale else { return false }
        let status = await AssetInventory.status(forModules:[m])
        let installed = await SpeechTranscriber.installedLocales
        return status == .installed || installed.contains(l)
    }
    func prepare(_ consent: Bool, _ g: UInt64) async throws {
        guard let m = module else { throw Failure("Apple Speech locale unavailable") }
        if !(await isReady()) {
            guard consent else { throw Failure("Language download was not approved") }
            if let install = try await AssetInventory.assetInstallationRequest(supporting:[m]) {
                let progress = Task {
                    while !Task.isCancelled {
                        session.emit(g,4,"Downloading one-time on-device language asset…",progress:install.progress.fractionCompleted)
                        try? await Task.sleep(for:.milliseconds(100))
                    }
                }
                do {
                    try await withTaskCancellationHandler {
                        try await install.downloadAndInstall()
                    } onCancel: { install.progress.cancel() }
                } catch {
                    progress.cancel(); await progress.value
                    throw error
                }
                progress.cancel(); await progress.value
            }
            guard await isReady() else { throw Failure("Language asset is not ready after installation") }
        }
        try Task.checkCancellation()
        if !prepared {
            let a = SpeechAnalyzer(modules:[m])
            analyzer = a
            reader = Task {
                for try await result in m.results { self.receive(result) }
            }
            // Streaming input must be Int16, not AVAudioFile's default Float32.
            let format = AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:false)!
            try await a.prepareToAnalyze(in:format)
            prepared = true
            session.emit(g,4,"Apple Speech prepared",progress:1)
        }
        session.emit(g,2)
    }
    func receive(_ r: SpeechTranscriber.Result) {
        let start = r.range.start.seconds, end = CMTimeRangeGetEnd(r.range).seconds
        session.emit(generation,3,String(r.text.characters),start:max(0,start-base),end:max(0,end-base),flags:r.isFinal ? 1 : 0)
        session.emit(generation,4,"Apple Speech: transcribing on device…",progress:duration > 0 ? min(1,(r.resultsFinalizationTime.seconds-base)/duration) : 0)
    }
    func start(_ path: String, _ g: UInt64) async throws {
        guard prepared, let a = analyzer else { throw Failure("Apple Speech was not prepared") }
        let file = try AVAudioFile(forReading:URL(fileURLWithPath:path),commonFormat:.pcmFormatInt16,interleaved:false)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else {
            throw Failure("Expected 16 kHz mono PCM")
        }
        generation = g; base = Double(offset)/16000; duration = Double(file.length)/16000
        let origin = offset
        // Pull-based sequence: at most one second of PCM in flight at this seam.
        let input = AsyncThrowingStream<AnalyzerInput,Error>(unfolding: {
            try Task.checkCancellation()
            guard file.framePosition < file.length else { return nil }
            let position = file.framePosition
            let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:16000)!
            try file.read(into:buffer)
            return AnalyzerInput(buffer:buffer,bufferStartTime:CMTime(value:origin+position,timescale:16000))
        })
        let end = try await a.analyzeSequence(input)
        try Task.checkCancellation()
        try await a.finalize(through:end)
        // Removing the completed module closes its result sequence. Awaiting
        // that reader is a deterministic drain barrier; a scheduler yield or
        // an empty volatile range is not proof that final events were consumed.
        // A fresh module also fixes the macOS 26.3.1 repeated-file text leak.
        // The same analyzer remains prepared (see CAPTION_ENGINES.md).
        guard let locale else { throw Failure("Caption locale was released") }
        let fresh = SpeechTranscriber(locale:locale,preset:.timeIndexedProgressiveTranscription)
        try await a.setModules([fresh])
        try await reader?.value
        try Task.checkCancellation()
        module = fresh
        reader = Task {
            for try await result in fresh.results { self.receive(result) }
        }
        offset += file.length
        armIdle()
        session.emit(g,5)
    }
    func cancel() async {
        reader?.cancel()
        if let a = analyzer { await a.cancelAndFinishNow() }
    }
    func close() async {
        idleVersion &+= 1
        idle?.cancel(); idle = nil
        await cancel()
        _ = try? await reader?.value
        reader = nil; analyzer = nil; module = nil; prepared = false; offset = 0
        if let l = locale { _ = await AssetInventory.release(reservedLocale:l) }
        locale = nil
    }
}
private struct Failure: Error { let message: String; init(_ message:String) { self.message = message } }
private func session(_ p: UnsafeMutableRawPointer) -> Session { Unmanaged<Session>.fromOpaque(p).takeUnretainedValue() }
@_cdecl("wam_caption_create_v1")
public func create(_ cb: @escaping CaptionCallback, _ ctx: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let s = Session(cb,ctx)
    if #available(macOS 26, *) { s.core = Engine(s) }
    return Unmanaged.passRetained(s).toOpaque()
}
@_cdecl("wam_caption_query_v1")
public func query(_ p: UnsafeMutableRawPointer, _ g: UInt64, _ language: UnsafePointer<CChar>) {
    let s = session(p), locale = String(cString:language)
    s.launch(g) {
        if #available(macOS 26, *), let e = s.core as? Engine { try await e.query(locale,g) }
        else { s.emit(g,1,flags:0) }
    }
}
@_cdecl("wam_caption_prepare_v1")
public func prepare(_ p: UnsafeMutableRawPointer, _ g: UInt64, _ consent: Int32) {
    let s = session(p)
    s.launch(g) {
        if #available(macOS 26, *), let e = s.core as? Engine { try await e.prepare(consent != 0,g) }
        else { throw Failure("Apple Speech requires macOS 26") }
    }
}
@_cdecl("wam_caption_start_v1")
public func start(_ p: UnsafeMutableRawPointer, _ g: UInt64, _ path: UnsafePointer<CChar>) {
    let s = session(p), file = String(cString:path)
    s.launch(g) {
        if #available(macOS 26, *), let e = s.core as? Engine { try await e.start(file,g) }
        else { throw Failure("Apple Speech requires macOS 26") }
    }
}
@_cdecl("wam_caption_cancel_v1")
public func cancel(_ p: UnsafeMutableRawPointer) { session(p).cancel() }
@_cdecl("wam_caption_finish_v1")
public func finish(_ p: UnsafeMutableRawPointer, _ g: UInt64) {
    let s = session(p)
    s.lock.lock(); let active = s.task; s.lock.unlock()
    Task.detached {
        active?.cancel()
        if #available(macOS 26, *), let e = s.core as? Engine { await e.cancel() }
        await active?.value
        if #available(macOS 26, *), let e = s.core as? Engine { await e.resume(); await e.close() }
        s.emit(g,8)
    }
}
@_cdecl("wam_caption_release_v1")
public func release(_ p: UnsafeMutableRawPointer) {
    let s = session(p); s.core = nil
    Unmanaged<Session>.fromOpaque(p).release()
}
