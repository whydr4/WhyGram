import Foundation
import OSLog
import TDShim

/// Single seam between `ChatHistoryStore` and TDLib. Tests inject a fake; production
/// uses `TDLibChatHistoryLoader`.
///
/// `openChat` / `closeChat` notify TDLib that the chat is being viewed, which is required
/// for supergroup / channel updates to flow. `loadHistory` returns messages in reverse
/// chronological order (TDLib's contract); the store sorts ascending for display.
///
/// `downloadFile` / `cancelDownloadFile` drive viewport-based photo downloading. Both are
/// idempotent: TDLib short-circuits if the file is already on disk (download) or already
/// complete (cancel).
protocol ChatHistoryLoader: Sendable {
    func openChat(chatId: Int64) async throws
    func closeChat(chatId: Int64) async throws
    /// `offset`: pass 0 for "messages strictly older than fromMessageId" (default
    /// pagination call). Pass a negative N to additionally include N messages
    /// NEWER than fromMessageId — used for the open-at-unread anchor fetch and
    /// for newer-direction pagination. Mirrors TDLib's `getChatHistory` semantics.
    func loadHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message]
    /// Same contract as `loadHistory`, but served only from TDLib's local database
    /// (`onlyLocal: true`) with no network round-trip. May return fewer messages
    /// than requested, or none. The default implementation returns `[]`, so
    /// loaders without a local cache always fall through to `loadHistory`.
    func loadLocalHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message]
    func downloadFile(fileId: Int, priority: Int) async throws -> File
    func cancelDownloadFile(fileId: Int) async throws
    func sendText(chatId: Int64, text: String) async throws -> Message
    func sendVoiceNote(chatId: Int64, fileURL: URL, duration: Int, waveform: Data) async throws -> Message
    func setChatDraftMessage(chatId: Int64, draftText: String) async throws
    /// Marks the given message ids as viewed (read). `forceRead: false` matches
    /// the "user is currently looking at the chat" semantics — TDLib uses the
    /// `openChat` state to decide whether to actually mark read.
    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool) async throws
    /// Casts (or changes) the current user's answer to a poll. `optionIds` are
    /// 0-based option positions; multiple ids only when the poll allows it.
    func setPollAnswer(chatId: Int64, messageId: Int64, optionIds: [Int]) async throws
    /// Sends an installed sticker by its remote file id (`InputFileRemote`).
    /// No local download is required — TDLib resolves the remote reference.
    func sendSticker(chatId: Int64, remoteFileId: String, emoji: String, width: Int, height: Int) async throws -> Message
    /// Sends the given coordinate as a static location message (`livePeriod` 0).
    func sendLocation(chatId: Int64, latitude: Double, longitude: Double) async throws -> Message
    /// Adds (`isChosen` false) or removes (true) the user's reaction.
    func setReaction(chatId: Int64, messageId: Int64, type: ReactionType, add: Bool) async throws
    /// Reactions the user can add to a message (emoji ones, non-Premium), most used first.
    func availableReactions(chatId: Int64, messageId: Int64) async throws -> [ReactionType]
    /// Whether the message can be edited / deleted.
    func messageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties
    func deleteMessages(chatId: Int64, messageIds: [Int64], revoke: Bool) async throws
    func editMessageText(chatId: Int64, messageId: Int64, text: String) async throws
    /// Ids of unread messages mentioning the user, newest first (up to `limit`).
    func unreadMentionIds(chatId: Int64, limit: Int) async throws -> [Int64]
}

/// Thrown by loaders that don't implement an action (previews).
struct LoaderUnsupported: Error {}

extension ChatHistoryLoader {
    func loadLocalHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message] {
        []
    }
    func setReaction(chatId: Int64, messageId: Int64, type: ReactionType, add: Bool) async throws { throw LoaderUnsupported() }
    func availableReactions(chatId: Int64, messageId: Int64) async throws -> [ReactionType] { throw LoaderUnsupported() }
    func messageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties { throw LoaderUnsupported() }
    func deleteMessages(chatId: Int64, messageIds: [Int64], revoke: Bool) async throws { throw LoaderUnsupported() }
    func editMessageText(chatId: Int64, messageId: Int64, text: String) async throws { throw LoaderUnsupported() }
    func unreadMentionIds(chatId: Int64, limit: Int) async throws -> [Int64] { throw LoaderUnsupported() }
}

struct TDLibChatHistoryLoader: ChatHistoryLoader {
    let client: TDLibClient

    func openChat(chatId: Int64) async throws {
        _ = try await client.openChat(chatId: chatId)
    }

    func closeChat(chatId: Int64) async throws {
        _ = try await client.closeChat(chatId: chatId)
    }

    func loadHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message] {
        // Resilient path: skip the atomic `client.getChatHistory(...)` decode (which
        // throws on the first message TDLibKit can't model) and decode messages
        // one-by-one, dropping any that fail. TDLib evolves faster than the pinned
        // TDLibKit version, so some chats contain message types (e.g. `messageGift`
        // with a `gift.background` that TDLibKit expects but the server no longer
        // provides) that would otherwise break the entire chat load.
        try await loadHistoryResilient(
            chatId: chatId,
            fromMessageId: fromMessageId,
            offset: offset,
            limit: limit,
            onlyLocal: false
        )
    }

    func loadLocalHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message] {
        try await loadHistoryResilient(
            chatId: chatId,
            fromMessageId: fromMessageId,
            offset: offset,
            limit: limit,
            onlyLocal: true
        )
    }

    private func loadHistoryResilient(
        chatId: Int64,
        fromMessageId: Int64,
        offset: Int,
        limit: Int,
        onlyLocal: Bool
    ) async throws -> [Message] {
        let query = GetChatHistory(
            chatId: chatId,
            fromMessageId: fromMessageId,
            limit: limit,
            offset: offset,
            onlyLocal: onlyLocal
        )
        let dto = DTO(query, encoder: client.encoder)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            do {
                try client.send(query: dto) { responseData in
                    continuation.resume(returning: responseData)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        return try decodeMessagesLeniently(data, chatId: chatId)
    }

    /// Decodes a `getChatHistory` response one message at a time, skipping any
    /// message TDLibKit can't model. A TDLib `error` response or a malformed body
    /// is thrown rather than collapsed to `[]`: callers treat an empty page as
    /// "no more history", so swallowing a transient failure (e.g. a timeout while
    /// the watch moves between the phone proxy and Wi-Fi/LTE) would permanently
    /// mark the window as exhausted and bypass the store's retry handling.
    private func decodeMessagesLeniently(_ data: Data, chatId: Int64) throws -> [Message] {
        let logger = Logger(subsystem: "org.telegram.TelegramWatch", category: "chathistory")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("getChatHistory chatId=\(chatId, privacy: .public) — response was not JSON object")
            throw TDError(code: 500, message: "Malformed getChatHistory response")
        }
        if let type = json["@type"] as? String, type == "error" {
            logger.warning("getChatHistory chatId=\(chatId, privacy: .public) — TDLib error response: \(String(describing: json), privacy: .public)")
            throw TDError(
                code: json["code"] as? Int ?? 500,
                message: json["message"] as? String ?? "getChatHistory failed"
            )
        }
        guard let rawMessages = json["messages"] as? [Any] else {
            logger.warning("getChatHistory chatId=\(chatId, privacy: .public) — response has no messages array")
            throw TDError(code: 500, message: "Malformed getChatHistory response")
        }
        var decoded: [Message] = []
        decoded.reserveCapacity(rawMessages.count)
        for (idx, entry) in rawMessages.enumerated() {
            // TDLib documents that `messages` entries may be null; skip them.
            guard let raw = entry as? [String: Any] else { continue }
            // Re-serialize each message dict to Data so TDLibKit's decoder can
            // consume it the same way it would the full Messages response.
            guard let perMessageData = try? JSONSerialization.data(withJSONObject: raw) else {
                logger.warning("getChatHistory chatId=\(chatId, privacy: .public) — re-serialize failed at index=\(idx, privacy: .public)")
                continue
            }
            do {
                let m = try client.decoder.decode(Message.self, from: perMessageData)
                decoded.append(m)
            } catch {
                logger.warning("getChatHistory chatId=\(chatId, privacy: .public) — skipping message index=\(idx, privacy: .public) due to decode error: \(String(describing: error), privacy: .public)")
            }
        }
        return decoded
    }

    func downloadFile(fileId: Int, priority: Int) async throws -> File {
        // synchronous=false → TDLib returns immediately and streams progress via updateFile.
        try await client.downloadFile(
            fileId: fileId,
            limit: 0,
            offset: 0,
            priority: priority,
            synchronous: false
        )
    }

    func cancelDownloadFile(fileId: Int) async throws {
        // onlyIfPending=false → cancel even if active.
        _ = try await client.cancelDownloadFile(fileId: fileId, onlyIfPending: false)
    }

    func sendText(chatId: Int64, text: String) async throws -> Message {
        try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: .inputMessageText(InputMessageText(
                clearDraft: true,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text)
            )),
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
    }

    func sendVoiceNote(chatId: Int64, fileURL: URL, duration: Int, waveform: Data) async throws -> Message {
        try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: .inputMessageVoiceNote(InputMessageVoiceNote(
                caption: nil,
                duration: duration,
                selfDestructType: nil,
                voiceNote: .inputFileLocal(InputFileLocal(path: fileURL.path)),
                waveform: waveform
            )),
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
    }

    func setChatDraftMessage(chatId: Int64, draftText: String) async throws {
        let draft: DraftMessage? = draftText.isEmpty ? nil : DraftMessage(
            date: Int(Foundation.Date().timeIntervalSince1970),
            effectId: 0,
            inputMessageText: .inputMessageText(InputMessageText(
                clearDraft: false,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: draftText)
            )),
            replyTo: nil,
            suggestedPostInfo: nil
        )
        _ = try await client.setChatDraftMessage(
            chatId: chatId,
            draftMessage: draft,
            topicId: nil
        )
    }

    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool) async throws {
        _ = try await client.viewMessages(
            chatId: chatId,
            forceRead: forceRead,
            messageIds: messageIds,
            source: nil
        )
    }

    func setPollAnswer(chatId: Int64, messageId: Int64, optionIds: [Int]) async throws {
        _ = try await client.setPollAnswer(chatId: chatId, messageId: messageId, optionIds: optionIds)
    }

    func setReaction(chatId: Int64, messageId: Int64, type: ReactionType, add: Bool) async throws {
        if add {
            try await client.addMessageReaction(chatId: chatId, messageId: messageId, reactionType: type)
        } else {
            try await client.removeMessageReaction(chatId: chatId, messageId: messageId, reactionType: type)
        }
    }

    func availableReactions(chatId: Int64, messageId: Int64) async throws -> [ReactionType] {
        let available = try await client.getMessageAvailableReactions(chatId: chatId, messageId: messageId, rowSize: 4)
        var seen = Set<ReactionType>()
        return (available.topReactions + available.recentReactions + available.popularReactions)
            .filter { reaction in
                guard !reaction.needsPremium, case .reactionTypeEmoji = reaction.type else { return false }
                return seen.insert(reaction.type).inserted
            }
            .map(\.type)
    }

    func messageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties {
        try await client.getMessageProperties(chatId: chatId, messageId: messageId)
    }

    func deleteMessages(chatId: Int64, messageIds: [Int64], revoke: Bool) async throws {
        try await client.deleteMessages(chatId: chatId, messageIds: messageIds, revoke: revoke)
    }

    func editMessageText(chatId: Int64, messageId: Int64, text: String) async throws {
        try await client.editMessageText(chatId: chatId, messageId: messageId, text: text)
    }

    func unreadMentionIds(chatId: Int64, limit: Int) async throws -> [Int64] {
        try await client.searchUnreadMentions(chatId: chatId, fromMessageId: 0, limit: limit).messages.map(\.id)
    }

    func sendSticker(chatId: Int64, remoteFileId: String, emoji: String, width: Int, height: Int) async throws -> Message {
        try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: .inputMessageSticker(InputMessageSticker(
                emoji: emoji,
                height: height,
                sticker: .inputFileRemote(InputFileRemote(id: remoteFileId)),
                thumbnail: nil,
                width: width
            )),
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
    }

    func sendLocation(chatId: Int64, latitude: Double, longitude: Double) async throws -> Message {
        try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: .inputMessageLocation(InputMessageLocation(
                heading: 0,
                livePeriod: 0,
                location: Location(horizontalAccuracy: 0, latitude: latitude, longitude: longitude),
                proximityAlertRadius: 0
            )),
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
    }
}
