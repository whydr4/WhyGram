import SwiftUI

/// Compares by what it draws: the row, not the callbacks. The list
/// rebuilds the callbacks on every update, so without this each update (a highlight, a
/// badge count, a new page) re-rendered every built bubble. The callbacks only reach
/// shared state (the store, @State storage, the tracker), so a kept copy stays correct.
struct MessageRowView: View, Equatable {
    let row: MessageRow
    let onPhotoTap: (PhotoVisual) -> Void
    let onVideoTap: (VideoVisual) -> Void
    let onVideoNoteTap: (VideoNoteVisual) -> Void
    let onPollTap: (Int64, PollVisual) -> Void
    /// Reports the row entering or leaving the viewport, by row id. (The list pages in
    /// more from here when the row is one of the window's edge rows.)
    var onVisibilityChange: ((String, Bool) -> Void)? = nil
    /// Reports the row's frame in the scroll view's visible area, by row id.
    var onFrameChange: ((String, CGRect) -> Void)? = nil
    var onIncomingBubbleVisible: ((Int64) -> Void)? = nil
    /// Long press on a message bubble (opens its actions).
    var onLongPress: ((MessageBubble) -> Void)? = nil

    @Environment(\.openReplyTarget) private var openReplyTarget
    /// Only used from callbacks, so the row doesn't observe it.
    @Environment(ChatHistoryStore.self) private var store

    var body: some View {
        #if DEBUG
        let _ = RenderCounter.bump("row")
        #endif
        rowBody
            // Reply headers inside report this row as where the jump started.
            .environment(\.openReplyTarget, openReplyTarget?.from(rowId: row.id))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                onFrameChange?(row.id, frame)
            }
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                onVisibilityChange?(row.id, visible)
                filesVisibilityChanged(visible)
            }
            // The lazy stack destroys rows that scroll far enough away without a
            // visibility change to false, which left stale ids in the on-screen set.
            .onDisappear {
                onVisibilityChange?(row.id, false)
                filesVisibilityChanged(false)
            }
    }

    /// The bubble's files download while the row is on screen. One tracker for the row,
    /// rather than one in each media bubble view on top of the row's own.
    private func filesVisibilityChanged(_ visible: Bool) {
        guard case .bubble(let bubble) = row else { return }
        for file in bubble.screenFiles {
            if visible { store.fileRowAppeared(file.id) } else { store.fileRowDisappeared(file.id) }
        }
    }

    static func == (lhs: MessageRowView, rhs: MessageRowView) -> Bool {
        lhs.row == rhs.row
    }

    @ViewBuilder
    private var rowBody: some View {
        switch row {
        case .bubble(let b):
            MessageBubbleView(bubble: b, onPhotoTap: onPhotoTap, onVideoTap: onVideoTap, onVideoNoteTap: onVideoNoteTap, onPollTap: onPollTap)
                .onLongPressGesture(minimumDuration: 0.4) { onLongPress?(b) }
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
