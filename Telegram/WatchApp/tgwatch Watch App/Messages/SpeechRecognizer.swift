import AVFoundation
import Foundation
import Observation
import OpusKit
import WhisperKit

/// On-watch speech recognition for voice notes: Whisper through WhisperKit, running
/// on the Neural Engine (CPU in the simulator). Fork only.
///
/// The model is downloaded from Settings into Application Support (not Caches, which
/// the system may purge), loaded once (the first load compiles it for the Neural
/// Engine, which can take a while; later loads use the compiled cache), and kept in
/// memory while the app runs. Transcripts are kept by voice file id and saved to disk,
/// so a voice note is only recognized once.
@Observable @MainActor
final class SpeechRecognizer {
    static let shared = SpeechRecognizer()

    /// OpenAI's multilingual Tiny and Base (the sizes WhisperKit supports on Watch7 /
    /// Watch8), a Base fine-tuned on Russian speech (whitemouse84/whisper-base-ru,
    /// converted with whisperkittools; installed from the Mac until it has a download
    /// source), and Small quantized to 216 MB, which WhisperKit doesn't list for the
    /// watch: much better Russian (word errors 12% vs 20% for Base on read speech,
    /// 43% vs 54% on phone speech) if it fits in the watch's memory.
    enum Model: String, CaseIterable, Identifiable {
        case tiny = "openai_whisper-tiny"
        case base = "openai_whisper-base"
        case baseRussian = "whygram_whisper-base-ru"
        case small = "openai_whisper-small_216MB"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .tiny: return "Tiny"
            case .base: return "Base"
            case .baseRussian: return "Base Russian"
            case .small: return "Small (experimental)"
            }
        }

        /// Where the app downloads it from: the WhisperKit model repo and the OpenAI
        /// repo holding its tokenizer. nil: only installable from the Mac
        /// (`.claude/watchapp-pr/push-whisper-model.sh`).
        var remote: (repo: String, tokenizerRepo: String)? {
            switch self {
            case .tiny: return ("argmaxinc/whisperkit-coreml", "openai/whisper-tiny")
            case .base: return ("argmaxinc/whisperkit-coreml", "openai/whisper-base")
            case .baseRussian: return nil
            case .small: return ("argmaxinc/whisperkit-coreml", "openai/whisper-small")
            }
        }
    }

    /// What a transcribed file is: a voice note (Ogg/Opus) or a video note (MP4).
    enum MediaKind {
        case voice, videoNote
    }

    enum Language: String, CaseIterable, Identifiable {
        case russian = "ru"
        case auto = "auto"

        var id: String { rawValue }
        var title: String { self == .russian ? "Russian" : "Auto-detect" }
    }

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        /// Loading the model; the first time it's compiled for the Neural Engine.
        case loading
        case ready
        case failed(String)
    }

    struct Transcript: Codable, Equatable {
        var text: String?
        var error: String?
    }

    private(set) var state: State = .notDownloaded
    var model: Model {
        didSet {
            guard model != oldValue else { return }
            UserDefaults.standard.set(model.rawValue, forKey: Self.modelKey)
            pipe = nil
            refreshState()
        }
    }
    var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }
    /// Measurements of the last download / load / transcription, shown in Settings.
    private(set) var stats: [String] = []
    /// By TDLib file id (the voice file, or the video note's video file).
    private(set) var transcripts: [Int: Transcript] = [:]
    /// Files being transcribed or waiting in the queue.
    private(set) var inProgress: Set<Int> = []
    /// Transcribe voice and video notes as they show up in an open chat.
    var autoTranscribe: Bool {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: Self.autoKey) }
    }

    private struct Job {
        let fileId: Int
        let path: String
        let kind: MediaKind
    }
    /// Waiting jobs, run one at a time (one model, and the watch's Neural Engine).
    private var queue: [Job] = []
    private var worker: Task<Void, Never>?

    private var pipe: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    private static let modelKey = "speech.model"
    private static let languageKey = "speech.language"
    private static let autoKey = "speech.auto"
    private static let folderKeyPrefix = "speech.folder."

    private init() {
        model = UserDefaults.standard.string(forKey: Self.modelKey).flatMap(Model.init) ?? .base
        autoTranscribe = UserDefaults.standard.bool(forKey: Self.autoKey)
        language = UserDefaults.standard.string(forKey: Self.languageKey).flatMap(Language.init) ?? .russian
        transcripts = Self.loadTranscripts()
        refreshState()
    }

    // MARK: - Model files

    private static var baseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisper", isDirectory: true)
    }

    /// Where `WhisperKit.download` puts a model under `baseURL`; also where
    /// `.claude/watchapp-pr/push-whisper-model.sh` copies one from the Mac.
    private static func standardFolder(_ model: Model) -> URL {
        modelsRoot.appendingPathComponent(model.rawValue, isDirectory: true)
    }

    static var modelsRoot: URL {
        baseURL.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// The downloaded model's folder, if it's there.
    private func modelFolder(_ model: Model) -> URL? {
        let candidates = [
            UserDefaults.standard.string(forKey: Self.folderKeyPrefix + model.rawValue).map { URL(fileURLWithPath: $0) },
            Self.standardFolder(model),
        ].compactMap { $0 }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("AudioEncoder.mlmodelc").path)
        }
    }

    var isDownloaded: Bool { modelFolder(model) != nil }

    /// Size of the downloaded model on disk.
    var downloadedSize: String? {
        guard let folder = modelFolder(model) else { return nil }
        return ByteCountFormatter.string(fromByteCount: Self.directorySize(folder), countStyle: .file)
    }

    private func refreshState() {
        if pipe != nil {
            state = .ready
        } else if case .downloading = state {
            return
        } else {
            state = isDownloaded ? .ready : .notDownloaded
        }
    }

    /// Downloads the model with plain URLSession rather than `WhisperKit.download`:
    /// WhisperKit's hub client decides it's offline from `NWPathMonitor`, which watchOS
    /// reports as unsatisfied for ordinary apps (no low-level networking), and then
    /// fails with "Repository not available locally". The tokenizer goes into the model
    /// folder, where WhisperKit looks for it, so loading needs no network either.
    func download() {
        guard !isDownloadingOrLoading else { return }
        let model = self.model
        state = .downloading(0)
        Task {
            let started = Date()
            do {
                let folder = try await ModelFetcher.fetch(model: model) { fraction in
                    if case .downloading = SpeechRecognizer.shared.state {
                        SpeechRecognizer.shared.state = .downloading(fraction)
                    }
                }
                UserDefaults.standard.set(folder.path, forKey: Self.folderKeyPrefix + model.rawValue)
                record(String(format: "download %@: %.0fs, %@", model.title, Date().timeIntervalSince(started),
                              downloadedSize ?? "?"))
                // Load right away: the first load compiles the model for the Neural Engine.
                state = .loading
                _ = try await loadedPipe()
                state = .ready
            } catch {
                record("download failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func deleteModel() {
        guard let folder = modelFolder(model) else { return }
        pipe = nil
        loadTask = nil
        try? FileManager.default.removeItem(at: folder)
        UserDefaults.standard.removeObject(forKey: Self.folderKeyPrefix + model.rawValue)
        refreshState()
    }

    private var isDownloadingOrLoading: Bool {
        switch state {
        case .downloading, .loading: return true
        default: return false
        }
    }

    /// The loaded pipeline, loading it once if needed.
    private func loadedPipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        if let loadTask { return try await loadTask.value }
        guard let folder = modelFolder(model) else { throw RecognizerError.noModel }
        let model = self.model
        let task = Task { () throws -> WhisperKit in
            let started = Date()
            let config = WhisperKitConfig(
                model: model.rawValue,
                downloadBase: Self.baseURL,
                modelFolder: folder.path,
                tokenizerFolder: Self.baseURL,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            let pipe = try await WhisperKit(config)
            await MainActor.run {
                SpeechRecognizer.shared.record(String(format: "load %@: %.1fs, memory %@", model.title,
                                                      Date().timeIntervalSince(started), Self.memoryFootprint()))
            }
            return pipe
        }
        loadTask = task
        do {
            let pipe = try await task.value
            self.pipe = pipe
            loadTask = nil
            return pipe
        } catch {
            loadTask = nil
            throw error
        }
    }

    // MARK: - Transcription

    /// Result of the Settings test run.
    private(set) var testResult: String?
    private(set) var isTesting = false

    /// Diagnostics: recognizes the newest voice (or video) message in any chat.
    func testOnLatestNote(video: Bool, using client: TDClient) {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            do {
                guard let path = try await client.latestNote(video: video) else {
                    testResult = "No messages found."
                    return
                }
                transcripts[-2] = nil
                transcribe(fileId: -2, path: path, kind: video ? .videoNote : .voice)
                while inProgress.contains(-2) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let transcript = transcripts[-2]
                testResult = transcript?.text ?? transcript?.error ?? "?"
                transcripts[-2] = nil
            } catch {
                testResult = error.localizedDescription
            }
        }
    }

    /// Queues a voice or video note for recognition, once. A tap (`urgent`) goes ahead
    /// of notes queued automatically.
    func transcribe(fileId: Int, path: String, kind: MediaKind, urgent: Bool = true) {
        guard isDownloaded, !inProgress.contains(fileId), transcripts[fileId]?.text == nil else { return }
        inProgress.insert(fileId)
        transcripts[fileId] = nil
        let job = Job(fileId: fileId, path: path, kind: kind)
        if urgent { queue.insert(job, at: 0) } else { queue.append(job) }
        runQueue()
    }

    /// Automatic transcription of a note that came into view, when it's switched on.
    func autoTranscribeIfEnabled(fileId: Int, path: String?, kind: MediaKind) {
        guard autoTranscribe, let path, transcripts[fileId] == nil else { return }
        transcribe(fileId: fileId, path: path, kind: kind, urgent: false)
    }

    private func runQueue() {
        guard worker == nil else { return }
        worker = Task {
            while !queue.isEmpty {
                let job = queue.removeFirst()
                await run(job)
                inProgress.remove(job.fileId)
            }
            worker = nil
            saveTranscripts()
        }
    }

    private func run(_ job: Job) async {
        let language = self.language
        do {
            let pipe = try await loadedPipe()
            let started = Date()
            let samples = try await Task.detached(priority: .userInitiated) {
                try Self.samples16k(path: job.path, kind: job.kind)
            }.value
            let decoded = Date()
            let options = DecodingOptions(
                task: .transcribe,
                language: language == .auto ? nil : language.rawValue,
                temperatureFallbackCount: 2,
                usePrefillPrompt: language != .auto,
                detectLanguage: language == .auto,
                skipSpecialTokens: true,
                withoutTimestamps: true
            )
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            transcripts[job.fileId] = Transcript(text: text.isEmpty ? "…" : text)
            record(String(format: "%@ %.1fs %@: decode %.1fs, recognize %.1fs, memory %@",
                          model.title, Double(samples.count) / 16_000, job.kind == .voice ? "voice" : "video note",
                          decoded.timeIntervalSince(started), Date().timeIntervalSince(decoded),
                          Self.memoryFootprint()))
        } catch {
            transcripts[job.fileId] = Transcript(error: error.localizedDescription)
            record("transcribe failed: \(error.localizedDescription)")
        }
    }

    /// 16 kHz mono samples, as Whisper takes them: decoded from an Ogg/Opus voice note
    /// with OpusKit (AVAudioFile can't read Opus), or read from a video note's MP4
    /// audio track by WhisperKit's loader.
    private nonisolated static func samples16k(path: String, kind: MediaKind) throws -> [Float] {
        if kind == .videoNote {
            return try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        }
        let decoded = try OpusDecoder.decodePCM(url: URL(fileURLWithPath: path))
        guard let resampled = AudioProcessor.resampleAudio(fromBuffer: decoded.pcm, toSampleRate: 16_000, channelCount: 1) else {
            throw RecognizerError.resampleFailed
        }
        return AudioProcessor.convertBufferToArray(buffer: resampled)
    }

    enum RecognizerError: LocalizedError {
        case noModel, resampleFailed
        var errorDescription: String? {
            switch self {
            case .noModel: return "Download a speech model in Settings first."
            case .resampleFailed: return "Couldn't convert the audio."
            }
        }
    }

    // MARK: - Stats & persistence

    private func record(_ line: String) {
        stats.insert(line, at: 0)
        if stats.count > 6 { stats.removeLast() }
        DebugTrace.log("speech " + line)
    }

    private static var transcriptsURL: URL { baseURL.appendingPathComponent("transcripts.json") }

    private static func loadTranscripts() -> [Int: Transcript] {
        guard let data = try? Data(contentsOf: transcriptsURL),
              let stored = try? JSONDecoder().decode([Int: Transcript].self, from: data) else { return [:] }
        return stored.filter { $0.value.text != nil }
    }

    private func saveTranscripts() {
        let kept = transcripts.filter { $0.value.text != nil }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: Self.baseURL, withIntermediateDirectories: true)
        try? data.write(to: Self.transcriptsURL, options: .atomic)
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// The app's physical memory footprint (what watchOS's memory limit counts).
    nonisolated static func memoryFootprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "?" }
        return ByteCountFormatter.string(fromByteCount: Int64(info.phys_footprint), countStyle: .memory)
    }
}

/// Downloads a WhisperKit model from Hugging Face file by file with URLSession.
@MainActor
private enum ModelFetcher {
    private struct Entry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    enum FetchError: LocalizedError {
        case http(Int, String)
        case noSource
        var errorDescription: String? {
            switch self {
            case .http(let code, let file): return "Download failed (HTTP \(code)) for \(file)"
            case .noSource: return "This model is installed from the Mac."
            }
        }
    }

    static func fetch(model: SpeechRecognizer.Model, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard let remote = model.remote else { throw FetchError.noSource }
        let repo = "https://huggingface.co/\(remote.repo)"
        let listURL = URL(string: "https://huggingface.co/api/models/\(remote.repo)/tree/main/\(model.rawValue)?recursive=true")!
        let (listData, listResponse) = try await URLSession.shared.data(from: listURL)
        try check(listResponse, file: "file list")
        var files = try JSONDecoder().decode([Entry].self, from: listData)
            .filter { $0.type == "file" }
            .map { (url: URL(string: "\(repo)/resolve/main/\($0.path)")!,
                    relative: String($0.path.dropFirst(model.rawValue.count + 1)),
                    size: $0.size ?? 0) }
        // The tokenizer lives in OpenAI's repo; WhisperKit also looks in the model folder.
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            files.append((URL(string: "https://huggingface.co/\(remote.tokenizerRepo)/resolve/main/\(name)")!, name, 0))
        }
        let total = max(files.reduce(0) { $0 + $1.size }, 1)

        // Into a staging folder, renamed at the end, so a cut-off download never
        // looks like a complete model.
        let final = SpeechRecognizer.modelsRoot.appendingPathComponent(model.rawValue, isDirectory: true)
        let staging = SpeechRecognizer.modelsRoot.appendingPathComponent(model.rawValue + ".partial", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var done: Int64 = 0
        for file in files {
            let destination = staging.appendingPathComponent(file.relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            try await download(file.url, to: destination) { received in
                progress(min(Double(base + received) / Double(total), 1))
            }
            done += file.size
        }
        try? fm.removeItem(at: final)
        try fm.moveItem(at: staging, to: final)
        progress(1)
        return final
    }

    /// Downloads one file, reporting bytes received so far while it runs.
    private static func download(_ url: URL, to destination: URL, received: @escaping @MainActor (Int64) -> Void) async throws {
        var task: URLSessionDownloadTask?
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                if let task { received(task.countOfBytesReceived) }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poller.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let downloadTask = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error { continuation.resume(throwing: error); return }
                do {
                    try check(response, file: url.lastPathComponent)
                    guard let location else { throw URLError(.cannotOpenFile) }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task = downloadTask
            downloadTask.resume()
        }
    }

    private nonisolated static func check(_ response: URLResponse?, file: String) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw FetchError.http(code, file) }
    }
}
