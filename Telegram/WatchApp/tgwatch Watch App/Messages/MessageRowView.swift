import SwiftUI

/// Compares by what it draws: the row and its edge flags, not the callbacks. The list
/// rebuilds the callbacks on every update, so without this each update (a highlight, a
/// badge count, a new page) re-rendered every built bubble. The callbacks only reach
/// shared state (the store, @State storage, the tracker), so a kept copy stays correct.
struct MessageRowView: View, Equatable {
    let row: MessageRow
    let onPhotoTap: (PhotoVisual) -> Void
    let onVideoTap: (VideoVisual) -> Void
    let onVideoNoteTap: (VideoNoteVisual) -> Void
    let onPollTap: (Int64, PollVisual) -> Void
    /// Among the first / last rows of the loaded window: entering the screen pages in
    /// more, a few rows before the edge so the next page is usually in place in time.
    var isNearTop = false
    var isNearBottom = false
    var onEnterTopEdge: (() -> Void)? = nil
    var onEnterBottomEdge: (() -> Void)? = nil
    /// Reports the row entering or leaving the viewport, by row id.
    var onVisibilityChange: ((String, Bool) -> Void)? = nil
    /// Reports the row's frame in the scroll view's visible area, by row id.
    var onFrameChange: ((String, CGRect) -> Void)? = nil
    var onIncomingBubbleVisible: ((Int64) -> Void)? = nil

    @Environment(\.openReplyTarget) private var openReplyTarget

    var body: some View {
        rowBody
            // Reply headers inside report this row as where the jump started.
            .environment(\.openReplyTarget, openReplyTarget?.from(rowId: row.id))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                onFrameChange?(row.id, frame)
            }
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                onVisibilityChange?(row.id, visible)
                guard visible else { return }
                if isNearTop { onEnterTopEdge?() }
                if isNearBottom { onEnterBottomEdge?() }
            }
            // The lazy stack destroys rows that scroll far enough away without a
            // visibility change to false, which left stale ids in the on-screen set.
            .onDisappear { onVisibilityChange?(row.id, false) }
    }

    static func == (lhs: MessageRowView, rhs: MessageRowView) -> Bool {
        lhs.row == rhs.row && lhs.isNearTop == rhs.isNearTop && lhs.isNearBottom == rhs.isNearBottom
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
