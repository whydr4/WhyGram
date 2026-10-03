import AVFoundation
import Foundation
import OpusKit

@MainActor
protocol VoicePlaybackBackend: AnyObject {
    func prepare() throws
    func play(buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) throws
    func pause()
    func resume()
    func stop()
    var elapsed: Double { get }
    var lastBufferDuration: Double { get }
    /// Moves playback to `fraction` (0…1) of the current buffer, keeping the
    /// playing/paused state.
    func seek(toFraction fraction: Double)
    /// Playback speed; pitch is preserved.
    func setRate(_ rate: Float)
}

extension VoicePlaybackBackend {
    func seek(toFraction fraction: Double) {}
    func setRate(_ rate: Float) {}
}

protocol VoiceDecoder: Sendable {
    func decodePCM(url: URL) async throws -> DecodedOpus
}

enum VoiceGlyph: Equatable {
    case play
    case pause
    case spinner
    case error
}

@Observable @MainActor
final class VoicePlaybackController {

    enum State: Equatable {
        case idle
        case preparing(voiceFileId: Int, progress: Double)
        case playing(voiceFileId: Int)
        case paused(voiceFileId: Int)
        case failed(voiceFileId: Int, message: String)
    }

    private(set) var state: State = .idle
    /// Observable progress tick that drives the bubble's waveform fill during
    /// playback. Updated by `startTicker(tok:)` while in `.playing`.
    private(set) var currentProgress: Double = 0
    /// Playback speed shared by every voice note, persisted across launches.
    private(set) var playbackRate: Float
    /// Called with the voice file id when a note plays to its end (not on
    /// pause, stop or tear-down). The chat uses it to start the next note.
    var onFinished: ((Int) -> Void)?

    private static let rateKey = "voicePlaybackRate"
    private static let rates: [Float] = [1, 1.5, 2]

    private let backend: VoicePlaybackBackend
    private let decoder: VoiceDecoder

    /// Identifies which decode/playback any pending completion belongs to.
    private var activeTok: Int = 0
    private var tickerTask: Task<Void, Never>? = nil
    private var decodeTask: Task<Void, Never>? = nil

    init(backend: VoicePlaybackBackend, decoder: VoiceDecoder) {
        self.backend = backend
        self.decoder = decoder
        let saved = UserDefaults.standard.float(forKey: Self.rateKey)
        self.playbackRate = Self.rates.contains(saved) ? saved : 1
    }

    /// True while `voiceFileId` is playing or paused, i.e. when seeking applies.
    func isSeekable(_ voiceFileId: Int) -> Bool {
        switch state {
        case .playing(let id), .paused(let id): return id == voiceFileId
        default: return false
        }
    }

    /// Steps the speed 1× → 1.5× → 2× → 1×; applies to the current note immediately.
    func cycleRate() {
        let index = Self.rates.firstIndex(of: playbackRate) ?? 0
        playbackRate = Self.rates[(index + 1) % Self.rates.count]
        UserDefaults.standard.set(playbackRate, forKey: Self.rateKey)
        backend.setRate(playbackRate)
    }

    /// Jumps the playing or paused note to `fraction` (0…1). No-op otherwise.
    func seek(voiceFileId: Int, fraction: Double) {
        guard isSeekable(voiceFileId) else { return }
        let clamped = min(max(fraction, 0), 1)
        backend.seek(toFraction: clamped)
        currentProgress = clamped
    }

    func isActive(_ voiceFileId: Int) -> Bool {
        switch state {
        case .preparing(let id, _), .playing(let id), .paused(let id), .failed(let id, _):
            return id == voiceFileId
        case .idle:
            return false
        }
    }

    func glyph(for voiceFileId: Int) -> VoiceGlyph {
        switch state {
        case .preparing(let id, _) where id == voiceFileId: return .spinner
        case .playing(let id) where id == voiceFileId:      return .pause
        case .paused(let id) where id == voiceFileId:       return .play
        case .failed(let id, _) where id == voiceFileId:    return .error
        default:                                            return .play
        }
    }

    func progress(for voiceFileId: Int) -> Double {
        guard isActive(voiceFileId) else { return 0 }
        return currentProgress
    }

    func tearDown() {
        activeTok &+= 1
        tickerTask?.cancel()
        tickerTask = nil
        decodeTask?.cancel()
        decodeTask = nil
        currentProgress = 0
        backend.stop()
        state = .idle
    }

    /// Entry point the bubble calls. If `note.localPath` is nil the controller
    /// transitions to `.preparing` and waits for the caller to call
    /// `resumeIfReady(note:)` once a path arrives.
    func toggle(note: VoiceNoteVisual) {
        switch state {
        case .playing(let id) where id == note.voiceFileId:
            backend.pause()
            tickerTask?.cancel()
            tickerTask = nil
            state = .paused(voiceFileId: id)
            return
        case .paused(let id) where id == note.voiceFileId:
            backend.resume()
            state = .playing(voiceFileId: id)
            startTicker(tok: activeTok)
            return
        case .preparing(let id, _) where id == note.voiceFileId:
            // Second tap during preparing = cancel.
            tearDown()
            return
        default:
            // Switch active (or fresh start).
            tearDown()
        }
        guard let path = note.localPath else {
            state = .preparing(voiceFileId: note.voiceFileId, progress: 0)
            return
        }
        startPlayback(note: note, path: path)
    }

    /// Called by ChatHistoryStore when a fileSnapshot update lands for a voice
    /// that's currently in `.preparing`. Advances to `.playing` if the path is
    /// now available.
    func resumeIfReady(note: VoiceNoteVisual) {
        guard case .preparing(let id, _) = state, id == note.voiceFileId else { return }
        guard let path = note.localPath else { return }
        startPlayback(note: note, path: path)
    }

    /// Called by ChatHistoryStore with download progress (0…1) while preparing.
    func updateDownloadProgress(voiceFileId: Int, progress: Double) {
        guard case .preparing(let id, _) = state, id == voiceFileId else { return }
        state = .preparing(voiceFileId: id, progress: progress)
    }

    // MARK: - Private

    private func startPlayback(note: VoiceNoteVisual, path: String) {
        activeTok &+= 1
        let tok = activeTok
        state = .preparing(voiceFileId: note.voiceFileId, progress: 1)

        let url = URL(fileURLWithPath: path)
        let decoder = self.decoder
        decodeTask?.cancel()
        decodeTask = Task { [weak self] in
            do {
                let decoded = try await decoder.decodePCM(url: url)
                self?.handleDecoded(tok: tok, note: note, decoded: decoded)
            } catch {
                self?.handleDecodeError(tok: tok, note: note, error: error)
            }
        }
    }

    private func handleDecoded(tok: Int, note: VoiceNoteVisual, decoded: DecodedOpus) {
        guard tok == activeTok else { return }
        do {
            try backend.prepare()
            backend.setRate(playbackRate)
            try backend.play(buffer: decoded.pcm) { [weak self] in
                self?.handlePlaybackEnded(tok: tok, voiceFileId: note.voiceFileId)
            }
            state = .playing(voiceFileId: note.voiceFileId)
            startTicker(tok: tok)
        } catch {
            state = .failed(voiceFileId: note.voiceFileId, message: "Audio unavailable")
        }
    }

    private func handleDecodeError(tok: Int, note: VoiceNoteVisual, error: Error) {
        guard tok == activeTok else { return }
        state = .failed(voiceFileId: note.voiceFileId, message: "Could not play voice note")
    }

    private func handlePlaybackEnded(tok: Int, voiceFileId: Int) {
        guard tok == activeTok else { return }
        tickerTask?.cancel()
        tickerTask = nil
        currentProgress = 0
        backend.stop()
        state = .idle
        onFinished?(voiceFileId)
    }

    /// Drives `currentProgress` updates at 20 Hz so the bubble's waveform fill
    /// is observable. Stops when the active token changes or state leaves
    /// `.playing`.
    private func startTicker(tok: Int) {
        tickerTask?.cancel()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard tok == self.activeTok else { return }
                guard case .playing = self.state else { return }
                let total = self.backend.lastBufferDuration
                if total > 0 {
                    self.currentProgress = min(1, max(0, self.backend.elapsed / total))
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            }
        }
    }
}

// MARK: - Production wiring

/// Plays a decoded note with AVAudioPlayer. watchOS has no AVAudioUnitTimePitch, but
/// AVAudioPlayer offers a pitch-preserving `rate` and seeking via `currentTime`. It
/// can't read Opus, so the decoded PCM is first written to a temporary CAF file.
@MainActor
final class AudioFilePlayerBackend: NSObject, VoicePlaybackBackend {

    private struct PlaybackFailed: Error {}

    private var player: AVAudioPlayer?
    private var fileURL: URL?
    private var pendingCompletion: (@MainActor () -> Void)?
    private var rate: Float = 1
    private(set) var lastBufferDuration: Double = 0

    var elapsed: Double { player?.currentTime ?? 0 }

    func prepare() throws {}

    func play(buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) throws {
        stop()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).caf")
        // 16-bit PCM keeps the file small; AVAudioFile converts from the decoder's
        // float32 processing format on write.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: buffer.format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: fileSettings,
            commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved
        )
        try file.write(from: buffer)
        file.close()
        fileURL = url

        // Like music playback: watchOS routes audio to the speaker only under an
        // active `.playback` session.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.enableRate = true
        player.rate = rate
        guard player.prepareToPlay(), player.play() else { throw PlaybackFailed() }
        self.player = player
        lastBufferDuration = player.duration
        pendingCompletion = completion
    }

    func pause()  { player?.pause() }
    func resume() { player?.play() }

    func stop() {
        pendingCompletion = nil
        player?.stop()
        player = nil
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func seek(toFraction fraction: Double) {
        guard let player else { return }
        // Stay a hair before the end so a seek to 100% still finishes normally.
        player.currentTime = min(max(fraction, 0), 0.999) * player.duration
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player?.rate = rate
    }

    fileprivate func playerFinished(_ finished: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == finished,
              let completion = pendingCompletion else { return }
        pendingCompletion = nil
        completion()
    }
}

extension AudioFilePlayerBackend: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in self.playerFinished(finished) }
    }
}

struct OpusDecoderAdapter: VoiceDecoder {
    func decodePCM(url: URL) async throws -> DecodedOpus {
        try await Task.detached(priority: .userInitiated) {
            try OpusKit.OpusDecoder.decodePCM(url: url)
        }.value
    }
}
