import TDShim

/// Abstraction over the TDLib requests `ChatListStore` needs, so the store
/// can be exercised in tests with a no-op or scripted loader.
protocol ChatListLoader: Sendable {
    /// Asks TDLib to surface up to `limit` more chats from `chatList`. TDLib responds by
    /// emitting `updateNewChat` or `updateChatAddedToList` events for any newly-surfaced
    /// chats. When TDLib has nothing more to surface, this method throws
    /// `TDError` with `code == 404`.
    func loadChats(chatList: ChatList, limit: Int) async throws
    /// Asks TDLib to download `fileId`. Returns immediately (synchronous=false);
    /// progress + completion stream back via `updateFile`.
    func downloadFile(fileId: Int, priority: Int) async throws -> File
    /// Cancels an in-flight or pending download.
    func cancelDownloadFile(fileId: Int) async throws
    /// Marks everything up to `lastMessageId` read, along with mentions.
    func markRead(chatId: Int64, lastMessageId: Int64?) async throws
    func setMarkedAsUnread(chatId: Int64, _ marked: Bool) async throws
    func setNotificationSettings(chatId: Int64, _ settings: ChatNotificationSettings) async throws
    func moveChat(chatId: Int64, to list: ChatList) async throws
}

extension ChatListLoader {
    func markRead(chatId: Int64, lastMessageId: Int64?) async throws { throw LoaderUnsupported() }
    func setMarkedAsUnread(chatId: Int64, _ marked: Bool) async throws { throw LoaderUnsupported() }
    func setNotificationSettings(chatId: Int64, _ settings: ChatNotificationSettings) async throws { throw LoaderUnsupported() }
    func moveChat(chatId: Int64, to list: ChatList) async throws { throw LoaderUnsupported() }
}

struct TDLibChatListLoader: ChatListLoader {
    let client: TDLibClient

    func loadChats(chatList: ChatList, limit: Int) async throws {
        _ = try await client.loadChats(chatList: chatList, limit: limit)
    }

    func downloadFile(fileId: Int, priority: Int) async throws -> File {
        // synchronous=false → TDLib returns immediately and streams progress via updateFile.
        try await client.downloadFile(
            fileId: fileId, limit: 0, offset: 0, priority: priority, synchronous: false
        )
    }

    func cancelDownloadFile(fileId: Int) async throws {
        // onlyIfPending=false → cancel even if active.
        _ = try await client.cancelDownloadFile(fileId: fileId, onlyIfPending: false)
    }

    func markRead(chatId: Int64, lastMessageId: Int64?) async throws {
        if let lastMessageId {
            // Viewing the newest message moves the read pointer past everything.
            _ = try await client.viewMessages(chatId: chatId, forceRead: true, messageIds: [lastMessageId], source: nil)
        }
        try await client.readAllChatMentions(chatId: chatId)
    }

    func setMarkedAsUnread(chatId: Int64, _ marked: Bool) async throws {
        try await client.toggleChatIsMarkedAsUnread(chatId: chatId, isMarkedAsUnread: marked)
    }

    func setNotificationSettings(chatId: Int64, _ settings: ChatNotificationSettings) async throws {
        try await client.setChatNotificationSettings(chatId: chatId, notificationSettings: settings)
    }

    func moveChat(chatId: Int64, to list: ChatList) async throws {
        try await client.addChatToList(chatId: chatId, chatList: list)
    }
}
