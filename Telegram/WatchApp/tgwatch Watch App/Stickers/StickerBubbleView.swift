import SwiftUI
import TDShim

/// One sticker bubble. No rounded-rect chat-bubble chrome — sticker renders directly
/// against the chat background, with sender name above (incoming groups only).
/// Drives the same visibility-based download flow as PhotoBubbleView.
struct StickerBubbleView: View {
    let sticker: StickerVisual
    let senderName: String?
    var senderColorIndex: Int? = nil
    let isOutgoing: Bool
    let replyHeader: ReplyHeader?

    @Environment(ChatHistoryStore.self) private var store
    @Environment(\.bubbleMetrics) private var metrics

    /// A lone animated emoji is drawn at about two thirds of a sticker, as in Telegram.
    private var maxEdgePt: CGFloat { metrics.stickerMaxEdge * (sticker.isAnimatedEmoji ? 0.7 : 1) }
    private var style: BubbleStyle { .resolve(isOutgoing: isOutgoing) }

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            if let name = senderName, !isOutgoing {
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(senderColorIndex.map { avatarPalette[$0] } ?? .secondary)
                    .padding(.horizontal, 4)
            }
            if let header = replyHeader {
                // Force incoming styling inside the gray card regardless of host outgoing —
                // the card itself provides the chrome.
                ReplyHeaderView(header: .init(
                    senderName: header.senderName,
                    snippet: header.snippet,
                    minithumbnail: header.minithumbnail,
                    isOutgoing: false,
                    senderColorIndex: header.senderColorIndex
                ), style: .incoming)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(BubbleStyle.incoming.fill)
                )
                .frame(maxWidth: metrics.stickerReplyCardMaxWidth)
            }
            stickerBody
        }
    }

    @ViewBuilder
    private var stickerBody: some View {
        switch sticker.format {
        case .webp:
            WebPStickerView(sticker: sticker, displaySize: displaySize)
        case .tgs:
            LottieAnimationView(sticker: sticker, displaySize: displaySize)
        case .unsupported:
            // Video (WEBM/VP9) stickers can't be decoded on watchOS. Show their still
            // raster thumbnail when they carry one (WebPStickerView falls back to it,
            // since the WEBM body is never downloaded), else the text placeholder.
            if sticker.thumbnailFileId != nil {
                WebPStickerView(sticker: sticker, displaySize: displaySize)
            } else {
                unsupportedBubble
            }
        }
    }

    /// No still to show: the sticker's emoji at jumbo size stands in for it, or a
    /// "Sticker" label when it has none.
    @ViewBuilder
    private var unsupportedBubble: some View {
        if sticker.emoji.isEmpty {
            Text("Sticker")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minWidth: BubbleShape.minSize, minHeight: BubbleShape.minSize)
                .background(
                    RoundedRectangle(cornerRadius: BubbleShape.cornerRadius)
                        .fill(style.fill)
                )
                .foregroundStyle(style.content)
        } else {
            Text(sticker.emoji).font(.system(size: 52))
        }
    }

    /// Aspect-fits the sticker's native dims into a `maxEdgePt × maxEdgePt` box.
    private var displaySize: CGSize {
        guard sticker.width > 0, sticker.height > 0 else {
            return CGSize(width: maxEdgePt, height: maxEdgePt)
        }
        let w = CGFloat(sticker.width)
        let h = CGFloat(sticker.height)
        let scale = min(maxEdgePt / w, maxEdgePt / h)
        return CGSize(width: w * scale, height: h * scale)
    }

}

#if DEBUG
// MARK: - Preview helpers

private struct NoopChatHistoryLoader: ChatHistoryLoader {
    func openChat(chatId: Int64) async throws {}
    func closeChat(chatId: Int64) async throws {}
    func loadHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message] { [] }
    func downloadFile(fileId: Int, priority: Int) async throws -> File {
        throw CancellationError()
    }
    func cancelDownloadFile(fileId: Int) async throws {}
    func sendText(chatId: Int64, text: String) async throws -> Message {
        throw CancellationError()
    }
    func sendVoiceNote(chatId: Int64, fileURL: URL, duration: Int, waveform: Data) async throws -> Message {
        throw CancellationError()
    }
    func setChatDraftMessage(chatId: Int64, draftText: String) async throws {}
    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool) async throws {}
    func setPollAnswer(chatId: Int64, messageId: Int64, optionIds: [Int]) async throws {}
    func sendSticker(chatId: Int64, remoteFileId: String, emoji: String, width: Int, height: Int) async throws -> Message {
        throw CancellationError()
    }
    func sendLocation(chatId: Int64, latitude: Double, longitude: Double) async throws -> Message { throw CancellationError() }
}

@MainActor
private func previewStore() -> ChatHistoryStore {
    ChatHistoryStore(
        chatId: 0,
        chatType: .chatTypePrivate(ChatTypePrivate(userId: 0)),
        lastReadInboxMessageId: 0,
        unreadCount: 0,
        lastMessageId: nil,
        loader: NoopChatHistoryLoader()
    )
}

/// Marker class used to locate the host app bundle from within previews. `Bundle.main`
/// points at the test runner in SnapshotPreviews context, so we use Bundle(for:) on a
/// host-target class instead.
private final class PreviewBundleMarker {}

private func previewSticker(format: StickerFormatKind, withFile: Bool, withThumb: Bool = false) -> StickerVisual {
    let bundle = Bundle(for: PreviewBundleMarker.self)
    let mainPath: String? = {
        guard withFile else { return nil }
        switch format {
        case .webp: return bundle.path(forResource: "sticker_raster", ofType: "webp", inDirectory: "SampleStickers")
        case .tgs:  return bundle.path(forResource: "sticker_lottie", ofType: "tgs", inDirectory: "SampleStickers")
        case .unsupported: return nil
        }
    }()
    let thumbPath: String? = withThumb ? bundle.path(forResource: "sticker_raster", ofType: "webp", inDirectory: "SampleStickers") : nil
    return StickerVisual(
        fileId: 1, format: format,
        width: 512, height: 512,
        emoji: "✨",
        localPath: mainPath,
        thumbnailFileId: withThumb ? 2 : nil,
        thumbnailLocalPath: thumbPath,
        thumbnailFormat: withThumb ? .webp : nil
    )
}

#Preview("WEBP — downloaded") {
    StickerBubbleView(
        sticker: previewSticker(format: .webp, withFile: true),
        senderName: nil, isOutgoing: false, replyHeader: nil
    )
    .bubblePreview()
    .environment(previewStore())
}

#Preview("WEBP — downloading, thumbnail available") {
    StickerBubbleView(
        sticker: previewSticker(format: .webp, withFile: false, withThumb: true),
        senderName: nil, isOutgoing: false, replyHeader: nil
    )
    .bubblePreview()
    .environment(previewStore())
}

#Preview("WEBP — downloading, no thumbnail") {
    StickerBubbleView(
        sticker: previewSticker(format: .webp, withFile: false),
        senderName: nil, isOutgoing: false, replyHeader: nil
    )
    .bubblePreview()
    .environment(previewStore())
}

#Preview("TGS — downloaded") {
    StickerBubbleView(
        sticker: previewSticker(format: .tgs, withFile: true),
        senderName: nil, isOutgoing: false, replyHeader: nil
    )
    .bubblePreview()
    .environment(previewStore())
}

#Preview("TGS — downloading, thumbnail available") {
    StickerBubbleView(
        sticker: previewSticker(format: .tgs, withFile: false, withThumb: true),
        senderName: nil, isOutgoing: false, replyHeader: nil
    )
    .bubblePreview()
    .environment(previewStore())
}

#Preview("WEBM — unsupported fallback") {
    StickerBubbleView(
        sticker: previewSticker(format: .unsupported, withFile: false),
        senderName: nil, isOutgoing: false, replyHeader: nil
    )
    .bubblePreview()
    .environment(previewStore())
}

#Preview("Group sticker — sender name above") {
    StickerBubbleView(
        sticker: previewSticker(format: .webp, withFile: true),
        senderName: "Alice", isOutgoing: false, replyHeader: nil
    )
    .bubblePreview()
    .environment(previewStore())
}

#Preview("Group sticker — colored sender name") {
    StickerBubbleView(
        sticker: previewSticker(format: .webp, withFile: true),
        senderName: "Alice", senderColorIndex: paletteIndex(for: 200),
        isOutgoing: false, replyHeader: nil
    )
    .bubblePreview()
    .environment(previewStore())
}

#Preview("Outgoing sticker") {
    StickerBubbleView(
        sticker: previewSticker(format: .webp, withFile: true),
        senderName: nil, isOutgoing: true, replyHeader: nil
    )
    .bubblePreview()
    .environment(previewStore())
}

// MARK: - Reply-header previews

private func previewReplyHeader(toText: String = "anchor", isOutgoing: Bool = false) -> ReplyHeader {
    ReplyHeader(
        senderName: "Bob",
        snippet: toText,
        minithumbnail: nil,
        isOutgoing: isOutgoing
    )
}

#Preview("Sticker WEBP — with reply card above") {
    StickerBubbleView(
        sticker: previewSticker(format: .webp, withFile: true),
        senderName: nil, isOutgoing: false,
        replyHeader: previewReplyHeader(toText: "anchor message")
    )
    .bubblePreview()
    .environment(previewStore())
}

#Preview("Sticker TGS — with reply card above") {
    StickerBubbleView(
        sticker: previewSticker(format: .tgs, withFile: true),
        senderName: nil, isOutgoing: false,
        replyHeader: previewReplyHeader(toText: "look at this clip")
    )
    .bubblePreview()
    .environment(previewStore())
}

#Preview("Sticker outgoing — with reply card above") {
    StickerBubbleView(
        sticker: previewSticker(format: .webp, withFile: true),
        senderName: nil, isOutgoing: true,
        replyHeader: previewReplyHeader(toText: "thanks!", isOutgoing: true)
    )
    .bubblePreview()
    .environment(previewStore())
}
#endif
