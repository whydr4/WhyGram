//
//  ForkTDLibApi.swift
//  TDShim (WhyGram fork)
//
//  Hand-written TDLib functions and updates the fork uses that the generated subset
//  (Generated/, tree-shaken by tools/td-codegen's seed.txt, which isn't vendored here)
//  doesn't include. Same shape as the generated code: a request struct named after the
//  TDLib function (the DTO derives "@type" from the Swift type name; keys go to
//  snake_case through the client's encoder) and an async method on TDLibApi.
//

import Foundation

// MARK: - Functions

extension TDLibApi {

    /// Adds a reaction to a message.
    @discardableResult
    public final func addMessageReaction(chatId: Int64, messageId: Int64, reactionType: ReactionType, isBig: Bool = false, updateRecentReactions: Bool = true) async throws -> Ok {
        try await forkRun(AddMessageReaction(chatId: chatId, messageId: messageId, reactionType: reactionType, isBig: isBig, updateRecentReactions: updateRecentReactions))
    }

    /// Removes a reaction the user added to a message.
    @discardableResult
    public final func removeMessageReaction(chatId: Int64, messageId: Int64, reactionType: ReactionType) async throws -> Ok {
        try await forkRun(RemoveMessageReaction(chatId: chatId, messageId: messageId, reactionType: reactionType))
    }

    /// Reactions that can be added to a message.
    public final func getMessageAvailableReactions(chatId: Int64, messageId: Int64, rowSize: Int) async throws -> AvailableReactions {
        try await forkRun(GetMessageAvailableReactions(chatId: chatId, messageId: messageId, rowSize: rowSize))
    }

    /// What can be done with a message (edit, delete, ...).
    public final func getMessageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties {
        try await forkRun(GetMessageProperties(chatId: chatId, messageId: messageId))
    }

    /// Deletes messages; `revoke` deletes them for everyone where allowed.
    @discardableResult
    public final func deleteMessages(chatId: Int64, messageIds: [Int64], revoke: Bool) async throws -> Ok {
        try await forkRun(DeleteMessages(chatId: chatId, messageIds: messageIds, revoke: revoke))
    }

    /// Replaces the text of a text message.
    @discardableResult
    public final func editMessageText(chatId: Int64, messageId: Int64, text: String) async throws -> Message {
        let content = InputMessageContent.inputMessageText(InputMessageText(
            clearDraft: false,
            linkPreviewOptions: nil,
            text: FormattedText(entities: [], text: text)
        ))
        return try await forkRun(EditMessageText(chatId: chatId, messageId: messageId, inputMessageContent: content))
    }

    /// Starts speech recognition of a voice note or video note; the result arrives as
    /// an `updateMessageContent` with the note's `speechRecognitionResult` filled in.
    @discardableResult
    public final func recognizeSpeech(chatId: Int64, messageId: Int64) async throws -> Ok {
        try await forkRun(RecognizeSpeech(chatId: chatId, messageId: messageId))
    }

    /// Unread messages that mention the user, newest first, from `fromMessageId`
    /// (0 = the newest).
    public final func searchUnreadMentions(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> FoundChatMessages {
        try await forkRun(SearchChatMessages(
            chatId: chatId, query: "", fromMessageId: fromMessageId, offset: 0, limit: limit,
            filter: SearchMessagesFilter(type: "searchMessagesFilterUnreadMention")
        ))
    }

    /// Marks all mentions in a chat as read.
    @discardableResult
    public final func readAllChatMentions(chatId: Int64) async throws -> Ok {
        try await forkRun(ReadAllChatMentions(chatId: chatId))
    }

    /// Marks a chat as unread, or clears that mark.
    @discardableResult
    public final func toggleChatIsMarkedAsUnread(chatId: Int64, isMarkedAsUnread: Bool) async throws -> Ok {
        try await forkRun(ToggleChatIsMarkedAsUnread(chatId: chatId, isMarkedAsUnread: isMarkedAsUnread))
    }

    /// Changes a chat's notification settings.
    @discardableResult
    public final func setChatNotificationSettings(chatId: Int64, notificationSettings: ChatNotificationSettings) async throws -> Ok {
        try await forkRun(SetChatNotificationSettings(chatId: chatId, notificationSettings: notificationSettings))
    }

    /// Moves a chat to a chat list (e.g. `.chatListArchive` to archive it).
    @discardableResult
    public final func addChatToList(chatId: Int64, chatList: ChatList) async throws -> Ok {
        try await forkRun(AddChatToList(chatId: chatId, chatList: chatList))
    }

    /// Same as the generated `run(query:)`, which is private to its file.
    private func forkRun<Q: Codable, R: Codable>(_ query: Q) async throws -> R {
        let dto = DTO(query, encoder: self.encoder)
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try self.send(query: dto) { result in
                    if let error = try? self.decoder.decode(DTO<TDError>.self, from: result) {
                        continuation.resume(with: .failure(error.payload))
                    } else {
                        continuation.resume(with: self.decoder.tryDecode(DTO<R>.self, from: result).map { $0.payload })
                    }
                }
            } catch let error as TDError {
                continuation.resume(throwing: error)
            } catch {
                continuation.resume(throwing: TDError(code: 500, message: error.localizedDescription))
            }
        }
    }
}

// MARK: - Requests

public struct AddMessageReaction: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let messageId: Int64
    public let reactionType: ReactionType
    public let isBig: Bool
    public let updateRecentReactions: Bool
}

public struct RemoveMessageReaction: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let messageId: Int64
    public let reactionType: ReactionType
}

public struct GetMessageAvailableReactions: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let messageId: Int64
    public let rowSize: Int
}

public struct GetMessageProperties: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let messageId: Int64
}

public struct DeleteMessages: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let messageIds: [Int64]
    public let revoke: Bool
}

public struct EditMessageText: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let messageId: Int64
    public let inputMessageContent: InputMessageContent
}

public struct RecognizeSpeech: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let messageId: Int64
}

public struct SearchChatMessages: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let query: String
    public let fromMessageId: Int64
    public let offset: Int
    public let limit: Int
    public let filter: SearchMessagesFilter
}

/// A `searchMessagesFilter*` object with no fields, by its TDLib type name.
public struct SearchMessagesFilter: Codable, Equatable, Hashable {
    public let type: String

    public init(type: String) { self.type = type }

    private enum CodingKeys: String, CodingKey { case type = "@type" }
}

public struct ReadAllChatMentions: Codable, Equatable, Hashable {
    public let chatId: Int64
}

public struct ToggleChatIsMarkedAsUnread: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let isMarkedAsUnread: Bool
}

public struct SetChatNotificationSettings: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let notificationSettings: ChatNotificationSettings
}

public struct AddChatToList: Codable, Equatable, Hashable {
    public let chatId: Int64
    public let chatList: ChatList
}

// MARK: - Results

/// Reactions that can be added to a message (only the fields the app reads).
public struct AvailableReactions: Codable, Equatable, Hashable {
    public let topReactions: [AvailableReaction]
    public let recentReactions: [AvailableReaction]
    public let popularReactions: [AvailableReaction]
}

public struct AvailableReaction: Codable, Equatable, Hashable {
    public let type: ReactionType
    public let needsPremium: Bool
}

/// What can be done with a message (only the fields the app reads).
public struct MessageProperties: Codable, Equatable, Hashable {
    public let canBeDeletedForAllUsers: Bool
    public let canBeDeletedOnlyForSelf: Bool
    public let canBeEdited: Bool
}

public struct FoundChatMessages: Codable, Equatable, Hashable {
    public let totalCount: Int
    public let messages: [Message]
    public let nextFromMessageId: Int64
}

// MARK: - Updates

/// Updates the generated `Update` enum doesn't carry (it decodes them as
/// `.unsupported`). Decode from the same update data when that happens.
public enum ForkUpdate: Decodable {
    /// A message's reactions (or views, forwards, replies) changed.
    case messageInteractionInfo(chatId: Int64, messageId: Int64, interactionInfo: MessageInteractionInfo?)
    /// The number of unread mentions in a chat changed.
    case chatUnreadMentionCount(chatId: Int64, unreadMentionCount: Int)
    /// A mention was read.
    case messageMentionRead(chatId: Int64, messageId: Int64, unreadMentionCount: Int)
    /// A chat was marked as unread, or the mark was cleared.
    case chatIsMarkedAsUnread(chatId: Int64, isMarkedAsUnread: Bool)
    case other

    private enum Kind: String {
        case updateMessageInteractionInfo, updateChatUnreadMentionCount, updateMessageMentionRead
        case updateChatIsMarkedAsUnread
    }

    private enum CodingKeys: String, CodingKey {
        case type = "@type"
        case chatId, messageId, interactionInfo, unreadMentionCount, isMarkedAsUnread
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch Kind(rawValue: try c.decode(String.self, forKey: .type)) {
        case .updateMessageInteractionInfo:
            self = .messageInteractionInfo(
                chatId: try c.decode(Int64.self, forKey: .chatId),
                messageId: try c.decode(Int64.self, forKey: .messageId),
                interactionInfo: try c.decodeIfPresent(MessageInteractionInfo.self, forKey: .interactionInfo)
            )
        case .updateChatUnreadMentionCount:
            self = .chatUnreadMentionCount(
                chatId: try c.decode(Int64.self, forKey: .chatId),
                unreadMentionCount: try c.decode(Int.self, forKey: .unreadMentionCount)
            )
        case .updateMessageMentionRead:
            self = .messageMentionRead(
                chatId: try c.decode(Int64.self, forKey: .chatId),
                messageId: try c.decode(Int64.self, forKey: .messageId),
                unreadMentionCount: try c.decode(Int.self, forKey: .unreadMentionCount)
            )
        case .updateChatIsMarkedAsUnread:
            self = .chatIsMarkedAsUnread(
                chatId: try c.decode(Int64.self, forKey: .chatId),
                isMarkedAsUnread: try c.decode(Bool.self, forKey: .isMarkedAsUnread)
            )
        case nil:
            self = .other
        }
    }
}
