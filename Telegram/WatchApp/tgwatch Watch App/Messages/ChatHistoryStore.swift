import Foundation
import Observation
import OSLog
import TDShim

@Observable
@MainActor
final class ChatHistoryStore {

    private(set) var rows: [MessageRow] = []
    private(set) var loadState: LoadState = .notStarted
    private(set) var lastSendError: String? = nil
    private(set) var draftText: String = ""
    private(set) var unseenNewerCount: Int = 0
    /// Live mutable window — populated by start() and pagination methods.
    /// View reads from this for `initialScrollTargetId`, `reachesChatTail`, etc.
    private(set) var window: MessageWindow

    /// Frozen `lastReadInboxMessageId` from chat-metadata at construction. Always
    /// set (may be 0 for a brand-new chat). Used as the mark-as-read gate.
    /// Distinct from `window.unreadDividerAfterId` which is nil when no unreads.
    let unreadDividerAfterIdSnapshot: Int64

    /// Highest message id the recipient has read on the outgoing side. Drives the
    /// unread-outgoing dot. Updated live via `updateChatReadOutbox`.
    private(set) var lastReadOutboxMessageId: Int64

    let chatId: Int64
    private let chatType: ChatType
    private let chatTailIdAtOpen: Int64?
    private let loader: ChatHistoryLoader
    private let selfUserId: Int64?
    private let logger = Logger(subsystem: "org.telegram.TelegramWatch", category: "chathistory")

    let voicePlayback: VoicePlaybackController
    let audioPlayback: AudioPlaybackController

    private let userNames: UserNamesStore
    private var files: [Int: File] = [:]
    private var trackedFileIds: Set<Int> = []
    private var openChatSent: Bool = false
    private var closePending: Bool = false
    private var isLoading: Bool = false

    private static let halfLimit: Int = 15

    /// See `ChatListStore.coalesceUpdates` for rationale. Production
    /// (MessageListView) opts in; tests default to false.
    private let coalesceUpdates: Bool
    private var reprojectPending = false

    #if DEBUG
    private(set) var debugReprojectCount: Int = 0
    #endif

    init(
        chatId: Int64,
        chatType: ChatType,
        lastReadInboxMessageId: Int64,
        lastReadOutboxMessageId: Int64 = 0,
        unreadCount: Int,
        lastMessageId: Int64?,
        loader: ChatHistoryLoader,
        selfUserId: Int64? = nil,
        userNames: UserNamesStore? = nil,
        draftText: String = "",
        unreadMentionCount: Int = 0,
        coalesceUpdates: Bool = false,
        voicePlayback: VoicePlaybackController? = nil,
        audioPlayback: AudioPlaybackController? = nil
    ) {
        self.chatId = chatId
        self.chatType = chatType
        self.chatTailIdAtOpen = lastMessageId
        self.loader = loader
        self.selfUserId = selfUserId
        self.userNames = userNames ?? UserNamesStore()
        self.voicePlayback = voicePlayback ?? VoicePlaybackController(
            backend: AudioFilePlayerBackend(),
            decoder: OpusDecoderAdapter()
        )
        self.audioPlayback = audioPlayback ?? AudioPlaybackController(backend: AVPlayerBackend())
        self.draftText = draftText
        self.coalesceUpdates = coalesceUpdates
        self.unreadDividerAfterIdSnapshot = lastReadInboxMessageId
        self.lastReadOutboxMessageId = lastReadOutboxMessageId
        // Fork: always open at the chat tail so the newest messages load first.
        // The unread divider is kept; the view lands on it only when it falls
        // inside the loaded window (see `MessageWindow.initialScrollTargetId`).
        let anchor: MessageWindow.Anchor = .tail
        let dividerAfter: Int64? = unreadCount > 0 ? lastReadInboxMessageId : nil
        self.window = MessageWindow(
            anchor: anchor,
            halfLimit: Self.halfLimit,
            unreadDividerAfterId: dividerAfter
        )
        self.loadState = .loadingFirstPage
        self.unreadMentionCount = unreadMentionCount
        self.voicePlayback.onFinished = { [weak self] voiceFileId in
            self?.playVoice(after: voiceFileId)
        }
    }

    func start() async {
        guard !isLoading else { return }
        isLoading = true
        loadState = .loadingFirstPage
        lastSendError = nil
        unseenNewerCount = 0
        defer { isLoading = false }
        do {
            if !openChatSent {
                try await loader.openChat(chatId: chatId)
                openChatSent = true
            }
            try await loadInitialWindow()
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            // Dump the full error description for DecodingError diagnostics —
            // the default `localizedDescription` collapses to a generic
            // "The data couldn't be read" string that hides the key/path.
            logger.warning("loadInitialWindow failed chatId=\(self.chatId, privacy: .public) error=\(String(describing: error), privacy: .public)")
            loadState = .failed(humanMessage(error))
        }
    }

    /// History-only initial load with NO side effects (no `openChat`). Safe to run
    /// before the user has committed to the chat (e.g. pre-warm on tap). Mirrors the
    /// load half of `start()`; `activate()` performs the `openChat` half separately.
    func warm() async {
        guard !isLoading else { return }
        isLoading = true
        loadState = .loadingFirstPage
        lastSendError = nil
        unseenNewerCount = 0
        defer { isLoading = false }
        do {
            try await loadInitialWindow()
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            logger.warning("warm failed chatId=\(self.chatId, privacy: .public) error=\(String(describing: error), privacy: .public)")
            loadState = .failed(humanMessage(error))
        }
    }

    /// Notifies TDLib the chat is being viewed (`openChat`), guarded to run once.
    /// Called from the view's `.task` once the user actually lands on the chat.
    /// An `openChat` failure is logged but does NOT blank already-loaded history —
    /// the worst case is delayed supergroup/channel live updates, not a dead screen.
    func activate() async {
        guard !openChatSent, !closePending else { return }
        do {
            try await loader.openChat(chatId: chatId)
            openChatSent = true
            // If stop() landed while openChat was in flight (the view popped during the
            // round-trip), honor the close now so the chat doesn't leak open on TDLib.
            if closePending {
                try? await loader.closeChat(chatId: chatId)
                openChatSent = false
                closePending = false
            }
        } catch {
            logger.warning("openChat chatId=\(self.chatId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Anchored initial fill: when `unreadDividerAfterId != nil`, we call
    /// `getChatHistory(fromMessageId: divider, offset: -(halfLimit+1), limit: 2*halfLimit)`
    /// → up to (halfLimit+1) newer + divider + ~(halfLimit-1) older. Otherwise we
    /// fetch from the tail with offset 0. Loop retries on the same anchor up to
    /// 10× (TDLib returns < requested on cold cache).
    ///
    /// A tail-anchored fill first asks TDLib's local database (no network). The
    /// local batch is kept only if it reaches the chat's last message; a stale
    /// cache that stops short would leave a gap below it, so it is discarded and
    /// the network loop fills the window from the tail as before. Rows are
    /// projected once at the end: the spinner covers the whole initial load, so
    /// per-iteration projections were never visible.
    private func loadInitialWindow() async throws {
        let targetCount = 2 * Self.halfLimit
        let maxIterations = 10
        var iter = 0
        if case .tail = window.anchor, window.cache.isEmpty, let tailId = chatTailIdAtOpen {
            let local = (try? await loader.loadLocalHistory(
                chatId: chatId, fromMessageId: 0, offset: 0, limit: targetCount
            )) ?? []
            logger.info("loadInitialWindow local returned=\(local.count, privacy: .public)")
            if let localHighest = local.map(\.id).max(), localHighest >= tailId {
                for m in local { primeFiles(from: m.content) }
                window.extendInitial(local.map(CachedMessage.init), chatTailId: chatTailIdAtOpen)
            }
        }
        while !Task.isCancelled, iter < maxIterations, window.cache.count < targetCount {
            iter += 1
            let from: Int64
            let offset: Int
            switch window.anchor {
            case .tail:
                from = window.loadedLowestId ?? 0
                offset = 0
            case .messageId(let anchorId):
                if window.loadedHighestId == nil {
                    from = anchorId
                    offset = -(Self.halfLimit + 1)
                } else if let highest = window.loadedHighestId, highest <= anchorId {
                    // Still missing newer side; pull from anchor with negative offset.
                    from = anchorId
                    offset = -(Self.halfLimit + 1)
                } else {
                    from = window.loadedLowestId ?? anchorId
                    offset = 0
                }
            }
            let limit = max(1, targetCount - window.cache.count)
            let messages = try await loader.loadHistory(
                chatId: chatId, fromMessageId: from, offset: offset, limit: limit
            )
            logger.info("loadInitialWindow iter=\(iter, privacy: .public) returned=\(messages.count, privacy: .public)")
            if messages.isEmpty {
                // Empty terminator. For a `.tail`-anchored initial fill, an empty
                // batch on `fromMessageId = loadedHighestId` means TDLib has nothing
                // newer than what we already have — i.e. we are at the chat tail.
                if case .tail = window.anchor { window.markReachesChatTail() }
                break
            }
            let cached = messages.map(CachedMessage.init)
            for m in messages { primeFiles(from: m.content) }
            window.extendInitial(cached, chatTailId: chatTailIdAtOpen)
            // For a `.tail`-anchored fill, the very first batch (`from == 0`) is
            // by definition anchored at the chat tail — TDLib returns the latest
            // messages in descending id order. Mark `reachesChatTail` so live
            // `updateNewMessage` can extend the window without spurious gap probes.
            if case .tail = window.anchor, from == 0 { window.markReachesChatTail() }
        }
        reproject()
    }

    func stop() async {
        voicePlayback.tearDown()
        audioPlayback.tearDown()
        SpeechRecognizer.shared.cancel(chatId: chatId)
        // Drain task was scheduled by markVisible during scroll; cancel so it
        // doesn't fire viewMessages against a soon-to-be-closed chat.
        viewDrainTask?.cancel()
        viewDrainTask = nil
        pendingViewIds.removeAll()
        guard openChatSent else {
            // activate() may have openChat in flight (the view popped before it
            // returned). Mark so activate() closes the chat once openChat completes —
            // otherwise it leaks open on TDLib.
            closePending = true
            return
        }
        do {
            try await loader.closeChat(chatId: chatId)
        } catch {
            logger.warning("closeChat chatId=\(self.chatId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pagination

    private(set) var lastPaginationError: String? = nil
    private var isLoadingOlder = false
    private var isLoadingNewer = false
    private var olderFailureStreak = 0
    private var newerFailureStreak = 0
    private static let paginationLimit = 30
    /// Most messages kept in memory while paging up (five pages).
    private static let windowLimit = 150
    private static let failureStreakCap = 3

    /// Loads the page above the window. `beforeApply` runs once the page has arrived and
    /// before it's shown: the list waits there for the scroll to come to rest, because a
    /// prepend during momentum isn't offset-compensated and throws the content around.
    func loadOlder(beforeApply: @MainActor () async -> Void = {}) async {
        guard !isLoadingOlder, window.hasOlder, let from = window.loadedLowestId else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let messages = try await loader.loadHistory(
                chatId: chatId, fromMessageId: from, offset: 0, limit: Self.paginationLimit
            )
            await beforeApply()
            for m in messages { primeFiles(from: m.content) }
            window.extendOlder(messages.map(CachedMessage.init))
            // The dropped newest rows sit far below the viewport, so this doesn't move
            // what's on screen.
            let dropped = window.trimNewest(keeping: Self.windowLimit)
            if dropped > 0 {
                logger.info("loadOlder trimmed newest=\(dropped, privacy: .public)")
                DebugTrace.log("loadOlder trimmed newest=\(dropped) window=\(window.cache.count) tail=\(window.reachesChatTail)")
            }
            olderFailureStreak = 0
            logger.info("loadOlder chatId=\(self.chatId, privacy: .public) returned=\(messages.count, privacy: .public)")
            reproject()
        } catch {
            olderFailureStreak += 1
            logger.warning("loadOlder failure streak=\(self.olderFailureStreak, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if olderFailureStreak >= Self.failureStreakCap {
                window.markHasOlderFalse()
                lastPaginationError = humanMessage(error)
            }
        }
    }

    func loadNewer() async {
        guard !isLoadingNewer, !window.reachesChatTail, let from = window.loadedHighestId else { return }
        isLoadingNewer = true
        defer { isLoadingNewer = false }
        do {
            let messages = try await loader.loadHistory(
                chatId: chatId, fromMessageId: from, offset: -Self.paginationLimit, limit: Self.paginationLimit
            )
            for m in messages { primeFiles(from: m.content) }
            window.extendNewer(messages.map(CachedMessage.init), chatTailId: chatTailIdAtOpen)
            newerFailureStreak = 0
            reproject()
        } catch {
            newerFailureStreak += 1
            logger.warning("loadNewer failure streak=\(self.newerFailureStreak, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if newerFailureStreak >= Self.failureStreakCap {
                window.markReachesChatTail()
                lastPaginationError = humanMessage(error)
            }
        }
    }

    func dismissPaginationError() {
        lastPaginationError = nil
        olderFailureStreak = 0
        newerFailureStreak = 0
    }

    // MARK: - Mark-as-read

    private var pendingViewIds: Set<Int64> = []
    private var viewDrainTask: Task<Void, Never>? = nil
    private static let viewDrainDelayNs: UInt64 = 300_000_000  // 300ms

    func markVisible(messageId: Int64) {
        pendingViewIds.insert(messageId)
        viewDrainTask?.cancel()
        viewDrainTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.viewDrainDelayNs)
            if Task.isCancelled { return }
            await self?.drainPendingViews()
        }
    }

    private func drainPendingViews() async {
        let ids = pendingViewIds.sorted()
        pendingViewIds.removeAll()
        guard !ids.isEmpty else { return }
        do {
            try await loader.viewMessages(chatId: chatId, messageIds: ids, forceRead: false)
        } catch {
            logger.warning("viewMessages chatId=\(self.chatId, privacy: .public) ids=\(ids.count, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Jump-to-bottom

    /// Caller (the view) is responsible for the actual `proxy.scrollTo` after this
    /// returns. Two paths:
    ///   - `reachesChatTail` already true: cheap; just zero the counter.
    ///   - else: clear window, re-build at the tail, then return.
    /// Like `reveal(messageId:)`, it keeps the old window when the tail can't be
    /// loaded (or a load is already running) instead of failing the whole chat.
    func jumpToBottom() async {
        if window.reachesChatTail {
            unseenNewerCount = 0
            return
        }
        guard !isLoading, !isLoadingOlder, !isLoadingNewer else { return }
        isLoading = true
        defer { isLoading = false }

        // Rebuild window with anchor=.tail and no divider.
        let previous = window
        window = MessageWindow(anchor: .tail, halfLimit: Self.halfLimit, unreadDividerAfterId: nil)

        do {
            try await loadInitialWindow()
            unseenNewerCount = 0
        } catch {
            logger.warning("jumpToBottom failed: \(String(describing: error), privacy: .public)")
            window = previous
            reproject()
        }
    }

    // MARK: - Jump to a message

    /// Makes sure `messageId` is in the loaded window (e.g. the target of a tapped reply).
    /// If it isn't, the window is rebuilt around it, the same way a chat opens at its
    /// unread divider. Returns false, keeping the old window, when it can't be loaded,
    /// or when a load is already running: a pagination result landing in the rebuilt
    /// window would break its contiguity.
    func reveal(messageId: Int64) async -> Bool {
        if window.cache[messageId] != nil { return true }
        guard !isLoading, !isLoadingOlder, !isLoadingNewer else { return false }
        isLoading = true
        defer { isLoading = false }

        let previous = window
        window = MessageWindow(
            anchor: .messageId(messageId),
            halfLimit: Self.halfLimit,
            unreadDividerAfterId: previous.unreadDividerAfterId
        )
        do {
            try await loadInitialWindow()
        } catch {
            logger.warning("reveal messageId=\(messageId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        guard window.cache[messageId] != nil else {
            // Deleted, or not reachable right now: stay where the user was.
            window = previous
            reproject()
            return false
        }
        unseenNewerCount = 0
        return true
    }

    // MARK: - Send / draft

    /// Sending lands at the chat's tail. When the window was moved away from it (a reply
    /// jump, or older pages trimming the newest), reload the tail first, so the sent
    /// message doesn't sit right after older ones with the messages between unloaded.
    /// If that can't happen now, mark the window as reaching the tail anyway (the
    /// previous behavior) so the sent message still shows.
    private func pullToTail() async {
        if !window.reachesChatTail { await jumpToBottom() }
        window.markReachesChatTail()
        unseenNewerCount = 0
    }

    func sendText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastSendError = nil
        // Pull-to-tail: sending implicitly means "user is at the bottom". Done BEFORE
        // the optimistic updateNewMessage from sendMessage lands.
        await pullToTail()
        do {
            _ = try await loader.sendText(chatId: chatId, text: trimmed)
        } catch {
            lastSendError = humanMessage(error)
            logger.warning("sendText chatId=\(self.chatId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func sendVoiceNote(_ draft: VoiceRecordingDraft) async -> Bool {
        lastSendError = nil
        await pullToTail()
        do {
            _ = try await loader.sendVoiceNote(
                chatId: chatId,
                fileURL: draft.fileURL,
                duration: draft.duration,
                waveform: draft.waveform
            )
            return true
        } catch {
            lastSendError = humanMessage(error)
            logger.warning("sendVoiceNote chatId=\(self.chatId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Sends an installed sticker (chosen in the picker) by remote file id.
    /// Mirrors `sendVoiceNote`: pull-to-tail, clear unseen, capture error.
    func sendSticker(_ sticker: PickerSticker) async -> Bool {
        lastSendError = nil
        await pullToTail()
        do {
            _ = try await loader.sendSticker(
                chatId: chatId,
                remoteFileId: sticker.remoteFileId,
                emoji: sticker.emoji,
                width: sticker.width,
                height: sticker.height
            )
            return true
        } catch {
            lastSendError = humanMessage(error)
            logger.warning("sendSticker chatId=\(self.chatId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Sends the user's current coordinate as a static location.
    /// Mirrors `sendSticker`: pull-to-tail, clear unseen, capture error.
    func sendLocation(latitude: Double, longitude: Double) async -> Bool {
        lastSendError = nil
        await pullToTail()
        do {
            _ = try await loader.sendLocation(chatId: chatId, latitude: latitude, longitude: longitude)
            return true
        } catch {
            lastSendError = humanMessage(error)
            logger.warning("sendLocation chatId=\(self.chatId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Casts the user's poll answer. `optionIds` are 0-based option positions.
    /// Mirrors `sendText`'s error capture; returns success. Result refresh comes
    /// asynchronously via `updatePoll`.
    func setPollAnswer(messageId: Int64, optionIds: [Int]) async -> Bool {
        lastSendError = nil
        do {
            try await loader.setPollAnswer(chatId: chatId, messageId: messageId, optionIds: optionIds)
            return true
        } catch {
            lastSendError = humanMessage(error)
            logger.warning("setPollAnswer chatId=\(self.chatId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Mentions

    /// Unread messages in this chat that mention the user.
    private(set) var unreadMentionCount = 0

    /// The oldest unread mention, the one to read first; nil if there's none.
    func oldestUnreadMention() async -> Int64? {
        do {
            return try await loader.unreadMentionIds(chatId: chatId, limit: 100).last
        } catch {
            logger.warning("unread mentions failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Reactions, edit, delete

    /// Adds the reaction, or removes it if the user already chose it.
    func toggleReaction(messageId: Int64, type: ReactionType) async {
        let chosen = window.cache[messageId]?.reactions.contains { $0.type == type && $0.isChosen } ?? false
        do {
            try await loader.setReaction(chatId: chatId, messageId: messageId, type: type, add: !chosen)
        } catch {
            lastSendError = humanMessage(error)
            logger.warning("setReaction failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What the long-press menu offers for a message.
    func actions(forMessageId messageId: Int64) async -> MessageActions {
        async let reactions = try? loader.availableReactions(chatId: chatId, messageId: messageId)
        async let properties = try? loader.messageProperties(chatId: chatId, messageId: messageId)
        let chosen = Set(window.cache[messageId]?.reactions.filter(\.isChosen).map(\.type) ?? [])
        return MessageActions(
            reactions: (await reactions) ?? MessageActions.fallbackReactions,
            chosenReactions: chosen,
            properties: await properties
        )
    }

    func deleteMessage(messageId: Int64, forEveryone: Bool) async {
        do {
            try await loader.deleteMessages(chatId: chatId, messageIds: [messageId], revoke: forEveryone)
        } catch {
            lastSendError = humanMessage(error)
            logger.warning("deleteMessages failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func editMessageText(messageId: Int64, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await loader.editMessageText(chatId: chatId, messageId: messageId, text: trimmed)
        } catch {
            lastSendError = humanMessage(error)
            logger.warning("editMessageText failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Updates the generated `Update` enum doesn't carry (see `ForkUpdate`).
    func handle(_ update: ForkUpdate) {
        switch update {
        case .messageInteractionInfo(let chatId, let messageId, let info) where chatId == self.chatId:
            window.applyInteractionInfo(id: messageId, info: info)
            scheduleReproject()
        case .messageMentionRead(let chatId, let messageId, let count) where chatId == self.chatId:
            window.applyMentionRead(id: messageId)
            unreadMentionCount = count
        case .chatUnreadMentionCount(let chatId, let count) where chatId == self.chatId:
            unreadMentionCount = count
        default:
            break
        }
    }

    /// Looks up the currently-projected poll for a message id (for the Vote
    /// screen's post-vote quiz reveal — reads the latest `updatePoll`-patched state).
    func poll(forMessageId id: Int64) -> PollVisual? {
        for row in rows {
            if case .bubble(let b) = row, b.messageId == id { return b.poll }
        }
        return nil
    }

    func dismissSendError() { lastSendError = nil }

    func saveDraft(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == draftText { return }
        draftText = trimmed
        do {
            try await loader.setChatDraftMessage(chatId: chatId, draftText: trimmed)
        } catch {
            logger.warning("setChatDraftMessage chatId=\(self.chatId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func fileSnapshot(fileId: Int) -> File? { files[fileId] }

    func requestFileDownload(fileId: Int, priority: Int = 1) {
        trackedFileIds.insert(fileId)
        logger.info("requestFileDownload fileId=\(fileId, privacy: .public) priority=\(priority, privacy: .public)")
        Task { [logger, loader] in
            do {
                _ = try await loader.downloadFile(fileId: fileId, priority: priority)
            } catch {
                logger.warning("downloadFile fileId=\(fileId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func togglePlayback(_ note: VoiceNoteVisual) {
        audioPlayback.tearDown()
        if note.localPath == nil {
            requestFileDownload(fileId: note.voiceFileId, priority: 2)
        }
        voicePlayback.toggle(note: note)
    }

    /// Tap on a voice note's waveform: jumps there if the note is playing or
    /// paused, otherwise behaves like a tap on the play button.
    func seekPlayback(_ note: VoiceNoteVisual, fraction: Double) {
        guard voicePlayback.isSeekable(note.voiceFileId) else {
            togglePlayback(note)
            return
        }
        voicePlayback.seek(voiceFileId: note.voiceFileId, fraction: fraction)
    }

    /// Auto-advance: when a voice note finishes, play the next voice note below
    /// it in the loaded history (downloading it first if needed).
    /// The voice message that just started playing on its own after the previous one;
    /// the list scrolls it into view.
    private(set) var autoplayedMessageId: Int64?

    private func playVoice(after voiceFileId: Int) {
        var passedFinished = false
        for row in rows {
            guard case .bubble(let bubble) = row, let voice = bubble.voiceNote else { continue }
            if passedFinished {
                togglePlayback(voice)
                autoplayedMessageId = bubble.messageId
                return
            }
            if voice.voiceFileId == voiceFileId { passedFinished = true }
        }
    }

    func toggleAudioPlayback(_ audio: AudioVisual) {
        voicePlayback.tearDown()
        if audio.localPath == nil {
            requestFileDownload(fileId: audio.audioFileId, priority: 2)
        }
        audioPlayback.toggle(audio: audio)
    }

    func cancelFileDownload(fileId: Int) {
        trackedFileIds.remove(fileId)
        logger.info("cancelFileDownload fileId=\(fileId, privacy: .public)")
        Task { [logger, loader] in
            do {
                try await loader.cancelDownloadFile(fileId: fileId)
            } catch {
                logger.warning("cancelDownloadFile fileId=\(fileId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Update dispatch

    func handle(_ update: Update) {
        switch update {
        case .updateNewMessage(let upd) where upd.message.chatId == chatId:
            let cached = CachedMessage(upd.message)
            let inserted = window.tryInsertLive(cached)
            if inserted {
                primeFiles(from: upd.message.content)
                scheduleReproject()
            } else {
                unseenNewerCount += 1
            }
        case .updateMessageSendSucceeded(let upd) where upd.message.chatId == chatId:
            guard window.cache[upd.oldMessageId] != nil else { return }
            window.applySendSucceeded(oldId: upd.oldMessageId, message: CachedMessage(upd.message))
            primeFiles(from: upd.message.content)
            scheduleReproject()
        case .updateMessageSendFailed(let upd) where upd.message.chatId == chatId:
            guard window.cache[upd.oldMessageId] != nil else { return }
            window.applySendFailed(oldId: upd.oldMessageId, message: CachedMessage(upd.message))
            scheduleReproject()
            logger.warning("send failed chatId=\(self.chatId, privacy: .public) errorCode=\(upd.error.code, privacy: .public) error=\(upd.error.message, privacy: .public)")
        case .updateMessageContent(let upd) where upd.chatId == chatId:
            window.applyContentUpdate(id: upd.messageId, newContent: upd.newContent)
            primeFiles(from: upd.newContent)
            scheduleReproject()
        case .updateDeleteMessages(let upd) where upd.chatId == chatId && upd.isPermanent:
            window.applyDelete(ids: upd.messageIds)
            scheduleReproject()
        case .updateUser:
            // UserNamesStore (owned by TDClient) absorbed the update before
            // it reached us. Just repaint with the new cache snapshot.
            scheduleReproject()
        case .updatePoll(let upd):
            window.applyPollUpdate(poll: upd.poll)
            scheduleReproject()
        case .updateFile(let upd):
            // Only this chat's files (primed from its messages, or requested here);
            // TDLib reports every download in the app, avatars included.
            let previous = files[upd.file.id]
            guard previous != nil || trackedFileIds.contains(upd.file.id) else { return }
            files[upd.file.id] = upd.file
            // Rows only show finished files, so progress ticks don't need a reprojection
            // of the whole history; viewers that show progress read `fileSnapshot`.
            guard trackedFileIds.contains(upd.file.id),
                  previous?.local.isDownloadingCompleted != upd.file.local.isDownloadingCompleted
                    || previous?.local.path != upd.file.local.path else { return }
            scheduleReproject()
        case .updateChatReadOutbox(let upd) where upd.chatId == chatId:
            lastReadOutboxMessageId = upd.lastReadOutboxMessageId
            scheduleReproject()
        default:
            break
        }
    }

    // MARK: - File priming (unchanged from prior implementation)

    private func primeFiles(from content: MessageContent) {
        switch content {
        case .messagePhoto(let m):
            guard let size = selectPhotoSize(m.photo.sizes) else { return }
            primeFile(size.photo)
        case .messageVideo(let m):
            let chosen = selectVideoQuality(primary: m.video, alternatives: m.alternativeVideos)
            primeFile(chosen.file)
            if let cover = m.cover, let s = selectVideoCoverSize(cover.sizes) {
                primeFile(s.photo)
            } else if let thumb = m.video.thumbnail {
                primeFile(thumb.file)
            }
        case .messageVideoNote(let m):
            primeFile(m.videoNote.video)
            if let thumb = m.videoNote.thumbnail {
                primeFile(thumb.file)
            }
        case .messageSticker(let m):
            primeFile(m.sticker.sticker)
            if let thumb = m.sticker.thumbnail,
               thumbnailFormatKind(thumb.format) != .unsupported {
                primeFile(thumb.file)
            }
        case .messageVoiceNote(let m):
            primeFile(m.voiceNote.voice)
        case .messageAudio(let m):
            primeFile(m.audio.audio)
        default:
            break
        }
    }

    private func primeFile(_ file: File) {
        if files[file.id]?.local.isDownloadingCompleted == true { return }
        files[file.id] = file
    }

    /// See `ChatListStore.scheduleReproject`. Tail-of-runloop deferral for
    /// production; passthrough for tests (default).
    private func scheduleReproject() {
        guard coalesceUpdates else {
            reproject()
            return
        }
        guard !reprojectPending else { return }
        reprojectPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.reprojectPending else { return }
            self.reproject()
        }
    }

    #if DEBUG
    /// Synchronously runs any pending coalesced reproject. Test hook.
    func flushPendingReproject() {
        guard reprojectPending else { return }
        reproject()
    }
    #endif

    private func reproject() {
        reprojectPending = false
        #if DEBUG
        debugReprojectCount += 1
        #endif
        let newRows = messageRows(
            messages: Array(window.cache.values),
            userNames: userNames.names,
            fileLocals: files,
            chatType: chatType,
            chatId: chatId,
            today: Foundation.Date(),
            calendar: Calendar.current,
            selfUserId: selfUserId,
            unreadDividerAfterId: window.unreadDividerAfterId,
            lastReadOutboxMessageId: lastReadOutboxMessageId
        )
        // Many updates (a user's name, a file for a row out of the window) project to
        // the same rows; assigning anyway would re-render the whole list.
        if newRows != rows { rows = newRows }
        // If a voice playback is awaiting its file, advance it now that the
        // projection has the freshest `localPath`.
        if case .preparing(let pendingId, _) = voicePlayback.state {
            for row in rows {
                if case .bubble(let b) = row, let v = b.voiceNote, v.voiceFileId == pendingId {
                    voicePlayback.resumeIfReady(note: v)
                    break
                }
            }
        }
        // Same resume-on-file-arrival hook for music playback.
        if case .preparing(let pendingId) = audioPlayback.state {
            for row in rows {
                if case .bubble(let b) = row, let a = b.audio, a.audioFileId == pendingId {
                    audioPlayback.resumeIfReady(audio: a)
                    break
                }
            }
        }
    }
}

#if DEBUG
extension ChatHistoryStore {
    /// Test-only: prime the window's `reachesChatTail` so `updateNewMessage`
    /// inserts without a prior `start()` call. Never call from production code.
    func testHook_markReachesChatTail() { window.markReachesChatTail() }
}
#endif

/// What the long-press menu offers for one message.
struct MessageActions {
    /// Emoji reactions the user can add here, most used first.
    let reactions: [ReactionType]
    /// The user's current reactions on the message.
    let chosenReactions: Set<ReactionType>
    /// Edit / delete permissions; nil when they couldn't be loaded.
    let properties: MessageProperties?

    /// Used when the chat's available reactions can't be loaded.
    static let fallbackReactions: [ReactionType] = ["👍", "❤️", "🔥", "😁", "😢", "🙏", "👎", "🤯"]
        .map { .reactionTypeEmoji(ReactionTypeEmoji(emoji: $0)) }
}
