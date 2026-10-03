import SwiftUI

struct MessageRowView: View {
    let row: MessageRow
    let onPhotoTap: (PhotoVisual) -> Void
    let onVideoTap: (VideoVisual) -> Void
    let onVideoNoteTap: (VideoNoteVisual) -> Void
    let onPollTap: (Int64, PollVisual) -> Void
    var index: Int = 0
    var count: Int = 1
    var onEnterTopEdge: (() -> Void)? = nil
    var onEnterBottomEdge: (() -> Void)? = nil
    var onIncomingBubbleVisible: ((Int64) -> Void)? = nil

    var body: some View {
        rowBody
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                guard visible else { return }
                // Start paging a few rows before the edge, so the next page is usually
                // in place by the time the user scrolls there.
                if index <= 8 { onEnterTopEdge?() }
                if index >= count - 9 { onEnterBottomEdge?() }
            }
    }

    @ViewBuilder
    private var rowBody: some View {
        switch row {
        case .bubble(let b):
            MessageBubbleView(bubble: b, onPhotoTap: onPhotoTap, onVideoTap: onVideoTap, onVideoNoteTap: onVideoNoteTap, onPollTap: onPollTap)
                .onScrollVisibilityChange(threshold: 0.5) { visible in
                    guard visible, !b.isOutgoing else { return }
                    onIncomingBubbleVisible?(b.messageId)
                }
        case .service(let s):      ServiceMessageView(line: s)
        case .daySeparator(let d): DaySeparatorView(label: d)
        case .unreadDivider:       UnreadDividerView()
        }
    }
}
