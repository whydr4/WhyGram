import Foundation
import Observation
import OpusKit
import WatchKit
import WhisperKit

/// On-watch speech recognition for voice notes: Whisper through WhisperKit, running
/// on the Neural Engine (CPU in the simulator). Fork only.
///
/// The model is downloaded from Settings into Application Support (not Caches, which
/// the system may purge). The first load after a download compiles it for the Neural
/// Engine; later loads use the compiled cache. It's loaded when a note needs it (or a
/// little ahead, when an incoming note shows up in an open chat) and unloaded after two
/// idle minutes or when the app goes to the background, so the watch doesn't keep a
/// hundred-plus megabytes for it. Transcripts are kept by the voice file's remote
/// unique id and saved to disk, so a voice note is only recognized once.
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

    struct Transcript: Equatable {
        var text: String?
        var error: String?
    }

    /// Automatic transcription skips longer notes: on Base a minute of speech takes
    /// about 25 s of Neural Engine time. A tap transcribes any length.
    static let autoMaxDuration = 60
    /// Automatic attempts per note after which only a tap retries it.
    private static let maxAutoAttempts = 2
    private static let idleUnloadDelay: Duration = .seconds(120)
    /// How long an incoming note has to stay on screen before the model is loaded for
    /// it, so scrolling past or popping in and out of a chat doesn't load it.
    private static let preloadDwell: Duration = .seconds(1.5)
    private static let partialInterval: Duration = .milliseconds(300)
    private static let keptTranscripts = 500
    private static let diagnosticsKey = "diagnostics"

    private(set) var state: State = .notDownloaded
    var model: Model {
        didSet {
            guard model != oldValue else { return }
            UserDefaults.standard.set(model.rawValue, forKey: Self.modelKey)
            modelChanged()
        }
    }
    var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }
    /// Diagnostics: run the text decoder on the CPU instead of the Neural Engine, to
    /// compare speed on the watch (small decoders can be faster on the CPU).
    var decoderOnCPU: Bool {
        didSet {
            guard decoderOnCPU != oldValue else { return }
            UserDefaults.standard.set(decoderOnCPU, forKey: Self.decoderCPUKey)
            modelChanged()
        }
    }
    /// Measurements of the last download / load / transcription, shown in Settings.
    private(set) var stats: [String] = []
    /// By the voice file's `remote.uniqueId`. Errors live only for this run.
    private(set) var transcripts: [String: Transcript] = [:]
    /// Text recognized so far for the note being transcribed.
    private(set) var partials: [String: String] = [:]
    /// Notes being transcribed or waiting in the queue.
    private(set) var inProgress: Set<String> = []
    /// Transcribe incoming voice notes not listened to yet (up to `autoMaxDuration`)
    /// as they show up in an open chat.
    var autoTranscribe: Bool {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: Self.autoKey) }
    }

    private struct Job {
        let key: String
        let path: String
        /// The chat it was asked for in: closing the chat drops it. 0 for diagnostics.
        let chatId: Int64
    }
    /// Waiting jobs, run one at a time (one model, and the watch's Neural Engine).
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var current: (job: Job, task: Task<Void, Never>)?
    /// Failed attempts per note this run.
    @ObservationIgnored private var failures: [String: Int] = [:]
    /// Latest partial text per decoding window of the running job, from WhisperKit's
    /// callback; copied into `partials` every `partialInterval`.
    @ObservationIgnored private var windowTexts: [Int: String] = [:]
    /// Bumped per job, so callbacks still in flight from the last job are ignored.
    @ObservationIgnored private var jobGeneration = 0
    @ObservationIgnored private var firstPartialAt: Date?
    /// When each transcript was made, for keeping the newest `keptTranscripts`.
    @ObservationIgnored private var transcriptDates: [String: Date] = [:]

    @ObservationIgnored private var pipe: WhisperKit?
    @ObservationIgnored private var loadTask: Task<WhisperKit, Error>?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    /// Incoming notes without a transcript on screen now; the model is preloaded once
    /// one of them has stayed for `preloadDwell`.
    @ObservationIgnored private var preloadCandidates: Set<String> = []
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var isInBackground = false

    private static let modelKey = "speech.model"
    private static let languageKey = "speech.language"
    private static let autoKey = "speech.auto"
    private static let decoderCPUKey = "speech.decoderCPU"
    private static let folderKeyPrefix = "speech.folder."

    private init() {
        model = UserDefaults.standard.string(forKey: Self.modelKey).flatMap(Model.init) ?? .base
        autoTranscribe = UserDefaults.standard.bool(forKey: Self.autoKey)
        language = UserDefaults.standard.string(forKey: Self.languageKey).flatMap(Language.init) ?? .russian
        decoderOnCPU = UserDefaults.standard.bool(forKey: Self.decoderCPUKey)
        loadTranscripts()
        refreshState()
        let center = NotificationCenter.default
        center.addObserver(forName: WKApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SpeechRecognizer.shared.enteredBackground() }
        }
        center.addObserver(forName: WKApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SpeechRecognizer.shared.isInBackground = false }
        }
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
        if case .downloading = state { return }
        state = isDownloaded ? .ready : .notDownloaded
    }

    /// Another model or decoder setting: drop the loaded one, and let notes that
    /// failed try again with the new one.
    private func modelChanged() {
        unload(reason: "settings changed")
        failures = [:]
        transcripts = transcripts.filter { $0.value.text != nil }
        refreshState()
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
                // Load right away: the first load compiles the model for the Neural
                // Engine, with WhisperKit's prewarm pass to keep that compile's peak
                // memory down. Later loads skip prewarm (it would load everything twice).
                state = .loading
                _ = try await loadedPipe(prewarm: true)
                state = .ready
                scheduleIdleUnload()
            } catch {
                record("download failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func deleteModel() {
        guard let folder = modelFolder(model) else { return }
        unload(reason: "deleted")
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
    private func loadedPipe(prewarm: Bool = false) async throws -> WhisperKit {
        idleTask?.cancel()
        if let pipe { return pipe }
        if let loadTask { return try await loadTask.value }
        guard let folder = modelFolder(model) else { throw RecognizerError.noModel }
        let model = self.model
        let decoderOnCPU = self.decoderOnCPU
        let task = Task { () throws -> WhisperKit in
            let started = Date()
            let config = WhisperKitConfig(
                model: model.rawValue,
                downloadBase: Self.baseURL,
                modelFolder: folder.path,
                tokenizerFolder: Self.baseURL,
                computeOptions: ModelComputeOptions(textDecoderCompute: decoderOnCPU ? .cpuOnly : .cpuAndNeuralEngine),
                verbose: false,
                logLevel: .error,
                prewarm: prewarm,
                load: true,
                download: false
            )
            let pipe = try await WhisperKit(config)
            await MainActor.run {
                SpeechRecognizer.shared.record(String(format: "load %@%@: %.1fs, memory %@", model.title,
                                                      prewarm ? " (prewarm)" : "", Date().timeIntervalSince(started),
                                                      Self.memoryFootprint()))
            }
            return pipe
        }
        loadTask = task
        do {
            let pipe = try await task.value
            loadTask = nil
            // The settings may have changed while it loaded.
            guard model == self.model, decoderOnCPU == self.decoderOnCPU else {
                await pipe.unloadModels()
                return try await loadedPipe()
            }
            self.pipe = pipe
            return pipe
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// Loads the model ahead of a likely tap: an incoming note without a transcript
    /// stayed on screen for `preloadDwell`. Unloaded again after two idle minutes.
    func setPreloadCandidate(_ key: String, visible: Bool) {
        if visible { preloadCandidates.insert(key) } else { preloadCandidates.remove(key) }
        if preloadCandidates.isEmpty {
            preloadTask?.cancel()
            preloadTask = nil
            return
        }
        guard isDownloaded, pipe == nil, loadTask == nil, preloadTask == nil, !isDownloadingOrLoading else { return }
        preloadTask = Task {
            try? await Task.sleep(for: Self.preloadDwell)
            guard !Task.isCancelled else { return }
            preloadTask = nil
            guard pipe == nil, !isInBackground, !preloadCandidates.isEmpty else { return }
            do {
                _ = try await loadedPipe()
                record("preloaded: memory \(Self.memoryFootprint())")
                if worker == nil { scheduleIdleUnload() }
            } catch {
                record("preload failed: \(error.localizedDescription)")
            }
        }
    }

    /// Frees the model's memory; the next note loads it again from the compiled cache.
    private func unload(reason: String) {
        idleTask?.cancel()
        idleTask = nil
        guard let pipe else { return }
        self.pipe = nil
        // A running job still holds it; it's freed when that job lets go.
        guard current == nil else { return }
        Task {
            await pipe.unloadModels()
            record("unload (\(reason)): memory \(Self.memoryFootprint())")
        }
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        guard pipe != nil else { return }
        if isInBackground {
            unload(reason: "background")
            return
        }
        idleTask = Task {
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled, worker == nil else { return }
            unload(reason: "idle")
        }
    }

    /// A suspended app holding the model is the first the system kills for memory, and
    /// TDLib goes with it. A running job finishes first (the app may be suspended
    /// mid-way and resume it later); the model is unloaded once the queue is empty.
    private func enteredBackground() {
        isInBackground = true
        preloadTask?.cancel()
        preloadTask = nil
        if worker == nil { unload(reason: "background") }
    }

    // MARK: - Transcription

    /// Result of the Settings test run.
    private(set) var testResult: String?
    private(set) var isTesting = false

    /// Diagnostics: recognizes the newest voice message in any chat.
    func testOnLatestNote(using client: TDClient) {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil
        let key = Self.diagnosticsKey
        Task {
            defer { isTesting = false }
            do {
                guard let path = try await client.latestVoiceNotePath() else {
                    testResult = "No messages found."
                    return
                }
                transcripts[key] = nil
                transcribe(key: key, path: path, chatId: 0)
                while inProgress.contains(key) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let transcript = transcripts[key]
                testResult = transcript?.text ?? transcript?.error ?? "Cancelled."
                transcripts[key] = nil
                failures[key] = nil
            } catch {
                testResult = error.localizedDescription
            }
        }
    }

    /// Queues a voice note for recognition, once. A tap (`urgent`) goes ahead of notes
    /// queued automatically.
    func transcribe(key: String, path: String, chatId: Int64, urgent: Bool = true) {
        guard !key.isEmpty, isDownloaded, !inProgress.contains(key), transcripts[key]?.text == nil else { return }
        inProgress.insert(key)
        let job = Job(key: key, path: path, chatId: chatId)
        if urgent { queue.insert(job, at: 0) } else { queue.append(job) }
        runQueue()
    }

    /// Automatic transcription of a note that came into view, when it's switched on:
    /// only incoming notes not listened to yet and at most `autoMaxDuration` long, and
    /// a note that failed is retried up to `maxAutoAttempts` times in all.
    func autoTranscribeIfEnabled(_ note: VoiceNoteVisual, isOutgoing: Bool, chatId: Int64) {
        guard autoTranscribe, !isOutgoing, !note.isListened, note.duration <= Self.autoMaxDuration,
              let path = note.localPath, failures[note.uniqueId, default: 0] < Self.maxAutoAttempts else { return }
        transcribe(key: note.uniqueId, path: path, chatId: chatId, urgent: false)
    }

    /// The chat was closed: its queued notes are dropped and the running one is stopped
    /// (WhisperKit checks for cancellation after every token).
    func cancel(chatId: Int64) {
        preloadCandidates = []
        preloadTask?.cancel()
        preloadTask = nil
        let dropped = queue.filter { $0.chatId == chatId }
        guard !dropped.isEmpty || current?.job.chatId == chatId else { return }
        queue.removeAll { $0.chatId == chatId }
        for job in dropped { inProgress.remove(job.key) }
        if let current, current.job.chatId == chatId { current.task.cancel() }
    }

    private func runQueue() {
        guard worker == nil else { return }
        preloadTask?.cancel()
        preloadTask = nil
        idleTask?.cancel()
        worker = Task {
            while !queue.isEmpty {
                let job = queue.removeFirst()
                let task = Task { await run(job) }
                current = (job, task)
                await task.value
                current = nil
                inProgress.remove(job.key)
                partials[job.key] = nil
            }
            worker = nil
            scheduleIdleUnload()
        }
    }

    private func run(_ job: Job) async {
        let language = self.language
        let started = Date()
        jobGeneration += 1
        let generation = jobGeneration
        windowTexts = [:]
        firstPartialAt = nil
        // Partial text arrives on a background task per token; it's shown in steps of
        // `partialInterval` so the bubble doesn't relayout on every token.
        let publisher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.partialInterval)
                let text = windowTexts.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, partials[job.key] != text {
                    if firstPartialAt == nil { firstPartialAt = Date() }
                    partials[job.key] = text
                }
            }
        }
        defer { publisher.cancel() }
        do {
            let pipe = try await loadedPipe()
            let loaded = Date()
            let samples = try await Task.detached(priority: .userInitiated) {
                try OpusDecoder.decodeMonoSamples(url: URL(fileURLWithPath: job.path), sampleRate: Int32(WhisperKit.sampleRate))
            }.value
            let decoded = Date()
            try Task.checkCancellation()
            let options = DecodingOptions(
                task: .transcribe,
                language: language == .auto ? nil : language.rawValue,
                // One retry at a higher temperature for a window that came out as a
                // repetition loop or low-confidence; each retry decodes the window again.
                temperatureFallbackCount: 1,
                usePrefillPrompt: language != .auto,
                detectLanguage: language == .auto,
                skipSpecialTokens: true,
                withoutTimestamps: true
            )
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options) { progress in
                let window = progress.windowId, text = progress.text
                Task { @MainActor in
                    let recognizer = SpeechRecognizer.shared
                    if recognizer.jobGeneration == generation { recognizer.windowTexts[window] = text }
                }
                return nil
            }
            try Task.checkCancellation()
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            setTranscript(Transcript(text: text.isEmpty ? "…" : text), for: job.key)
            failures[job.key] = nil
            let firstText = firstPartialAt.map { String(format: ", first text %.1fs", $0.timeIntervalSince(decoded)) } ?? ""
            record(String(format: "%@ %@ %.1fs voice: load %.1fs, decode %.2fs, recognize %.1fs%@, memory %@",
                          model.title, decoderOnCPU ? "CPU" : "ANE", Double(samples.count) / 16_000,
                          loaded.timeIntervalSince(started), decoded.timeIntervalSince(loaded),
                          Date().timeIntervalSince(decoded), firstText, Self.memoryFootprint()))
        } catch let error where Task.isCancelled || error is CancellationError {
            record(String(format: "cancelled after %.1fs", Date().timeIntervalSince(started)))
        } catch {
            transcripts[job.key] = Transcript(error: error.localizedDescription)
            failures[job.key, default: 0] += 1
            record("transcribe failed: \(error.localizedDescription)")
        }
    }

    enum RecognizerError: LocalizedError {
        case noModel
        var errorDescription: String? {
            switch self {
            case .noModel: return "Download a speech model in Settings first."
            }
        }
    }

    // MARK: - Stats & persistence

    private func record(_ line: String) {
        stats.insert(line, at: 0)
        if stats.count > 6 { stats.removeLast() }
        DebugTrace.log("speech " + line)
    }

    private struct StoredTranscript: Codable {
        let key: String
        let text: String
        let date: Date
    }

    private static var transcriptsURL: URL { baseURL.appendingPathComponent("transcripts-v2.json") }

    private func loadTranscripts() {
        // v1 was keyed by TDLib file ids, which another login reuses for other files.
        try? FileManager.default.removeItem(at: Self.baseURL.appendingPathComponent("transcripts.json"))
        guard let data = try? Data(contentsOf: Self.transcriptsURL),
              let stored = try? JSONDecoder().decode([StoredTranscript].self, from: data) else { return }
        for entry in stored {
            transcripts[entry.key] = Transcript(text: entry.text)
            transcriptDates[entry.key] = entry.date
        }
    }

    /// Keeps a recognized text and saves right away, so a job finished before the app
    /// is killed isn't lost; only the newest `keptTranscripts` are saved.
    private func setTranscript(_ transcript: Transcript, for key: String) {
        transcripts[key] = transcript
        guard key != Self.diagnosticsKey else { return }
        transcriptDates[key] = Date()
        let kept = transcriptDates.sorted { $0.value > $1.value }.prefix(Self.keptTranscripts)
        let stored = kept.compactMap { key, date in
            transcripts[key]?.text.map { StoredTranscript(key: key, text: $0, date: date) }
        }
        if transcriptDates.count > Self.keptTranscripts {
            let keep = Set(kept.map(\.key))
            for key in transcriptDates.keys where !keep.contains(key) {
                transcriptDates[key] = nil
                transcripts[key] = nil
            }
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
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

#if DEBUG
extension SpeechRecognizer {
    /// UI gallery: puts a made-up voice note into a recognition state. In memory only,
    /// never saved with the real transcripts.
    func setGalleryState(key: String, text: String? = nil, partial: String? = nil, error: String? = nil, inProgress: Bool = false) {
        transcripts[key] = (text != nil || error != nil) ? Transcript(text: text, error: error) : nil
        partials[key] = partial
        if inProgress { self.inProgress.insert(key) } else { self.inProgress.remove(key) }
    }
}
#endif
