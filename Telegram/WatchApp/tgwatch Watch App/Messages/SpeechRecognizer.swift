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

    /// The Whisper variants WhisperKit supports on the watch (Watch7 / Watch8).
    enum Model: String, CaseIterable, Identifiable {
        case tiny = "openai_whisper-tiny"
        case base = "openai_whisper-base"

        var id: String { rawValue }
        var title: String { self == .tiny ? "Tiny" : "Base" }
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
    private(set) var transcripts: [Int: Transcript] = [:]
    private(set) var inProgress: Set<Int> = []

    private var pipe: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    private static let modelKey = "speech.model"
    private static let languageKey = "speech.language"
    private static let folderKeyPrefix = "speech.folder."

    private init() {
        model = UserDefaults.standard.string(forKey: Self.modelKey).flatMap(Model.init) ?? .tiny
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

    /// Settings' test: recognizes the newest voice message in any chat.
    func testOnLatestVoiceNote(using client: TDClient) {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            do {
                guard let voice = try await client.latestVoiceNote() else {
                    testResult = "No voice messages found."
                    return
                }
                transcribe(voiceFileId: -2, path: voice.path)
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

    /// Recognizes the voice note at `path` (an Ogg/Opus file), once.
    func transcribe(voiceFileId: Int, path: String) {
        guard !inProgress.contains(voiceFileId) else { return }
        inProgress.insert(voiceFileId)
        transcripts[voiceFileId] = nil
        let language = self.language
        Task {
            defer { inProgress.remove(voiceFileId) }
            do {
                let pipe = try await loadedPipe()
                let started = Date()
                let samples = try await Task.detached(priority: .userInitiated) {
                    try Self.samples16k(path: path)
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
                transcripts[voiceFileId] = Transcript(text: text.isEmpty ? "…" : text)
                record(String(format: "%@ %.1fs audio: decode %.1fs, recognize %.1fs, memory %@",
                              model.title, Double(samples.count) / 16_000,
                              decoded.timeIntervalSince(started), Date().timeIntervalSince(decoded),
                              Self.memoryFootprint()))
            } catch {
                transcripts[voiceFileId] = Transcript(error: error.localizedDescription)
                record("transcribe failed: \(error.localizedDescription)")
            }
            saveTranscripts()
        }
    }

    /// 16 kHz mono samples of an Ogg/Opus voice note, as Whisper takes them.
    private nonisolated static func samples16k(path: String) throws -> [Float] {
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
        var errorDescription: String? {
            switch self {
            case .http(let code, let file): return "Download failed (HTTP \(code)) for \(file)"
            }
        }
    }

    static func fetch(model: SpeechRecognizer.Model, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let repo = "https://huggingface.co/argmaxinc/whisperkit-coreml"
        let listURL = URL(string: "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main/\(model.rawValue)?recursive=true")!
        let (listData, listResponse) = try await URLSession.shared.data(from: listURL)
        try check(listResponse, file: "file list")
        var files = try JSONDecoder().decode([Entry].self, from: listData)
            .filter { $0.type == "file" }
            .map { (url: URL(string: "\(repo)/resolve/main/\($0.path)")!,
                    relative: String($0.path.dropFirst(model.rawValue.count + 1)),
                    size: $0.size ?? 0) }
        // The tokenizer lives in OpenAI's repo; WhisperKit also looks in the model folder.
        let size = model == .tiny ? "tiny" : "base"
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            files.append((URL(string: "https://huggingface.co/openai/whisper-\(size)/resolve/main/\(name)")!, name, 0))
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
