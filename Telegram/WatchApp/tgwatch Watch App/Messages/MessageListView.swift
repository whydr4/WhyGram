import SwiftUI

private struct ScrollSnapshot: Equatable {
    let contentOffsetY: CGFloat
    let contentSizeH: CGFloat
    let containerSizeH: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
}

struct MessageListView: View {
    @Environment(TDClient.self) private var client
    let row: ChatRow

    @State private var store: ChatHistoryStore
    @State private var presentedPhoto: PhotoVisual?
    @State private var presentedVideo: VideoVisual?
    @State private var presentedVideoNote: VideoNoteVisual?
    @State private var presentedPoll: PollVoteTarget?
    @State private var showAttachment: Bool = false
    @State private var stickerPickerStore: StickerPickerStore?
    // True when the user is parked within slop of the bottom edge. Updated only on
    // user-driven scrolls (see .onScrollGeometryChange filter), so it reflects intent
    // rather than instantaneous viewport position. Drives auto-scroll for incoming:
    // stay-anchored-when-at-bottom, leave-alone-when-scrolled-up. Chats open at the
    // tail, so this starts true; the initial-position `.task` sets it to false when the
    // view lands on the unread divider instead of the bottom.
    @State private var isAtBottom: Bool
    @State private var didApplyInitialScroll: Bool = false
    /// The last user scroll moved up (toward older messages) and the scroll hasn't come
    /// to rest. Picks which edge the content stays pinned to when its size changes.
    @State private var scrollingUp = false
    // Pagination triggers fire from `.onScrollVisibilityChange` on the top/bottom rows.
    // On initial layout — especially for all-unread chats where the divider lands at
    // row index 0 — the topmost rows are visible without any user gesture, which would
    // call loadOlder() repeatedly in a loop as each fetch prepends more content. Gate
    // pagination on having observed at least one user-driven scroll
    // (`.onScrollGeometryChange`'s contentSizeH-stable filter implies user-driven).
    @State private var userHasScrolled: Bool = false
    // Hard cool-down after each loadOlder/loadNewer. Without this, the row-visibility
    // callbacks for newly-prepended rows fire IMMEDIATELY after `reproject()` and re-
    // trigger pagination before the viewport is restored. The cool-down lets the
    // prepended rows settle off-screen before the next pagination is allowed; it is
    // short because paging now starts several rows before the edge.
    @State private var canPaginate: Bool = true
    private static let paginationCooldownNs: UInt64 = 300_000_000
    /// Rows currently on screen, fed by each row's visibility callback. Read when older
    /// rows are prepended, to keep the row the user was looking at in place.
    @State private var visibleRows = VisibleRowTracker()
    /// Set while an older page loads, so the prepend that follows restores the viewport
    /// (and a window rebuild by a reply jump doesn't).
    @State private var restoreAfterPrepend = false
    /// Bumped by the jump-to-bottom toolbar button; handled inside the ScrollViewReader.
    @State private var jumpToBottomRequest = 0
    /// Where each reply jump started, newest last. The jump-to-bottom button returns
    /// to these first, and goes to the bottom once they are used up.
    @State private var replyReturnStack: [ViewportAnchor] = []
    /// Row briefly highlighted after jumping to it from a reply header.
    @State private var highlightedRowId: String?
    /// Incoming messages that arrived below the viewport while the user was scrolled
    /// up; shown on the jump-to-bottom button with the store's `unseenNewerCount`.
    @State private var newBelowCount = 0

    init(row: ChatRow, store: ChatHistoryStore) {
        self.row = row
        self._store = State(initialValue: store)
        // Fork: chats always open at the tail → starts at bottom.
        self._isAtBottom = State(initialValue: true)
    }

    var body: some View {
        content(store: store)
        .navigationTitle(row.title)
        .accessibilityIdentifier("messageListView")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AvatarView(
                    avatar: row.avatar,
                    onRequestDownload: { fileId in store.requestFileDownload(fileId: fileId) },
                    onCancelDownload:  { fileId in store.cancelFileDownload(fileId: fileId) },
                    size: 36
                )
                .glassEffect(in: Circle())
            }
            // In the system bottom bar: an overlay button over the chat never received
            // taps on the watch (confirmed with the on-device trace).
            if showsJumpToBottom {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button {
                        jumpToBottomRequest += 1
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .overlay(alignment: .topTrailing) { unseenBadge }
                    .accessibilityIdentifier("jumpToBottom")
                }
            }
        }
        .sheet(item: $presentedPhoto) { photo in
            PhotoViewerView(photo: photo).environment(store)
        }
        .sheet(item: $presentedVideo) { video in
            VideoPlayerView(video: video).environment(store)
        }
        .sheet(item: $presentedVideoNote) { note in
            VideoNotePlayerView(note: note).environment(store)
        }
        .sheet(item: $presentedPoll) { target in
            PollVoteView(
                initialPoll: target.poll,
                currentPoll: { store.poll(forMessageId: target.id) },
                onVote: { await store.setPollAnswer(messageId: target.id, optionIds: $0) }
            )
        }
        .sheet(isPresented: $showAttachment) {
            AttachmentSheet(
                stickerPickerStore: stickerPickerStore,
                onSendSticker: { await store.sendSticker($0) },
                onSendVoiceNote: { await store.sendVoiceNote($0) },
                onPrepareVoice: {
                    store.voicePlayback.tearDown()
                    store.audioPlayback.tearDown()
                },
                onSendLocation: { latitude, longitude in
                    await store.sendLocation(latitude: latitude, longitude: longitude)
                }
            )
            .environment(client)
            // Inject the picker store at the sheet-content root (above
            // AttachmentSheet's NavigationStack), mirroring `client`. The
            // store must live above the stack so pushed destinations —
            // StickerSetDetailView and its StickerCellViews — inherit it;
            // injecting only inside StickerPickerView (below the stack)
            // left pushed set-detail views with no store and trapped on
            // the `@Environment(StickerPickerStore.self)` lookup.
            .environment(stickerPickerStore)
        }
        .task {
            client.setActiveHistory(store)
            // Defer openChat to here (the store was warmed without it). Independent
            // of warm: if the window is still loading, openChat proceeds anyway.
            await store.activate()
            // Build the picker store HERE (not lazily in the attachment-tap closure):
            // creating an @State and flipping a sheet-present flag in the same closure
            // races the .sheet's `if let pickerStore` against a nil snapshot.
            if stickerPickerStore == nil, let pl = client.makeStickerPickerLoader() {
                stickerPickerStore = StickerPickerStore(loader: pl)
            }
        }
        .onDisappear {
            let s = self.store
            client.setActiveHistory(nil)
            Task { await s.stop() }
        }
    }

    @ViewBuilder
    private func content(store: ChatHistoryStore) -> some View {
        switch store.loadState {
        case .loadingFirstPage:
            // Keep the spinner up for the entire initial load. TDLib's cold cache
            // routinely splits `getChatHistory` into multiple round-trips (iter=1
            // returns 1 message, iter=2 returns the rest). If we fall through to
            // the ScrollView mid-load, the user sees: brief render with iter=1's
            // content → iter=2 prepends 29 messages (content jumps) → final scroll
            // fires. Showing the spinner until `.loaded` collapses that into one
            // clean transition.
            LoadingView(label: "Loading messages…")
        case .failed(let message):
            VStack(spacing: 6) {
                Text(message)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await store.start() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        default:
            // ScrollViewReader wraps the list so the initial-position `.task`,
            // loadOlder scroll-preservation, and tail auto-scroll handlers can capture
            // `proxy` and call `proxy.scrollTo(...)`.
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if let err = store.lastSendError {
                        HStack(spacing: 4) {
                            Text(err)
                                .font(.caption2)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            Button {
                                store.dismissSendError()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(6)
                        .background(Capsule().fill(.red.opacity(0.2)))
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                    }
                    if let err = store.lastPaginationError {
                        HStack(spacing: 4) {
                            Text(err).font(.caption2).lineLimit(2)
                            Spacer(minLength: 0)
                            Button { store.dismissPaginationError() } label: {
                                Image(systemName: "xmark").font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(6)
                        .background(Capsule().fill(.orange.opacity(0.2)))
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                    }
                    ScrollView {
                        // Lazy so only rows near the viewport are built: with a plain VStack
                        // every loaded message was laid out on each update, which made long
                        // sessions sluggish on the watch.
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(store.rows.enumerated()), id: \.element.id) { idx, messageRow in
                                MessageRowView(
                                    row: messageRow,
                                    onPhotoTap: { presentedPhoto = $0 },
                                    onVideoTap: { presentedVideo = $0 },
                                    onVideoNoteTap: { presentedVideoNote = $0 },
                                    onPollTap: { id, poll in presentedPoll = PollVoteTarget(id: id, poll: poll) },
                                    isNearTop: idx <= 8,
                                    isNearBottom: idx >= store.rows.count - 9,
                                    onEnterTopEdge: {
                                        guard userHasScrolled, canPaginate else { return }
                                        canPaginate = false
                                        restoreAfterPrepend = true
                                        DebugTrace.log("loadOlder trigger row=\(messageRow.id) rows=\(store.rows.count) visible=\(visibleRows.ids.count)")
                                        Task {
                                            await store.loadOlder()
                                            DebugTrace.log("loadOlder done rows=\(store.rows.count)")
                                            try? await Task.sleep(nanoseconds: Self.paginationCooldownNs)
                                            restoreAfterPrepend = false
                                            canPaginate = true
                                        }
                                    },
                                    onEnterBottomEdge: {
                                        guard userHasScrolled, canPaginate, !store.window.reachesChatTail else { return }
                                        canPaginate = false
                                        DebugTrace.log("loadNewer trigger row=\(messageRow.id) rows=\(store.rows.count)")
                                        Task {
                                            await store.loadNewer()
                                            DebugTrace.log("loadNewer done rows=\(store.rows.count)")
                                            try? await Task.sleep(nanoseconds: Self.paginationCooldownNs)
                                            canPaginate = true
                                        }
                                    },
                                    onVisibilityChange: { id, visible in
                                        if visible {
                                            visibleRows.ids.insert(id)
                                        } else {
                                            visibleRows.ids.remove(id)
                                            visibleRows.frames[id] = nil
                                        }
                                    },
                                    onFrameChange: { id, frame in visibleRows.frames[id] = frame },
                                    onIncomingBubbleVisible: { id in
                                        guard id > store.unreadDividerAfterIdSnapshot else { return }
                                        store.markVisible(messageId: id)
                                    }
                                )
                                .equatable()
                                .background {
                                    if highlightedRowId == messageRow.id {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.accentColor.opacity(0.3))
                                    }
                                }
                                .id(messageRow.id)
                            }
                            if row.canSend {
                                ReplyBar(
                                    onAttachTap: { showAttachment = true },
                                    onSend: { snapshot in
                                        Task { await store.sendText(snapshot) }
                                    }
                                )
                                .padding(.top, 8)
                            }
                            // 19pt bottom content inset so the ReplyBar's "+" and pill sit
                            // 19pt above the *physical* screen edge when the chat is scrolled
                            // to the tail. Combined with .ignoresSafeArea(edges: .bottom) on
                            // the ScrollView below — without that, the system bottom safe-area
                            // adds extra space and the total inset overshoots. Carried as an
                            // id'd zero-content spacer (not `.padding(.bottom, 19)` on the
                            // stack) so it's part of the scrollable content and
                            // `proxy.scrollTo("bottomAnchor", .bottom)` reaches the TRUE
                            // content bottom — anchoring to the ReplyBar instead stops 19pt
                            // short, landing the chat just above the real tail.
                            Color.clear
                                .frame(height: 19)
                                .id("bottomAnchor")
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .scrollContentBackground(.hidden)
                    .background {
                        Image("ChatBG")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .ignoresSafeArea()
                    }
                    .environment(store)
                    .environment(\.openReplyTarget, OpenReplyTargetAction { messageId, sourceRowId in
                        jumpToMessage(messageId, from: sourceRowId, proxy: proxy)
                    })
                    .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
                        ScrollSnapshot(
                            contentOffsetY: geometry.contentOffset.y,
                            contentSizeH: geometry.contentSize.height,
                            containerSizeH: geometry.containerSize.height,
                            topInset: geometry.contentInsets.top,
                            bottomInset: geometry.contentInsets.bottom
                        )
                    } action: { old, new in
                        visibleRows.viewport = new
                        // isAtBottom means "user intends to be parked at bottom", NOT "the
                        // bottom edge is visible right now". When a new message arrives while
                        // the user is at the bottom, contentSize grows but contentOffset stays
                        // — a naive "is the bottom edge visible" check would flip false even
                        // though the user hasn't moved. Skipping callbacks where contentSize
                        // changed preserves the last user-driven state.
                        //
                        // The .top inset (translucent nav bar overlay, ~62pt on the 46mm sim)
                        // shrinks the maximum scroll offset; subtract it from bottomOffset or
                        // the check is off by ~62pt and isAtBottom never reaches true. Verified
                        // empirically — when at the bottom, contentOffset.y ==
                        // contentSize.height - containerSize.height - contentInsets.top.
                        guard old.contentSizeH == new.contentSizeH else { return }
                        let bottomOffset = new.contentSizeH - new.containerSizeH - new.topInset
                        // This runs on every scroll frame: write state only when it
                        // changes, or each frame re-renders the whole list.
                        let atBottom = new.contentOffsetY >= bottomOffset - 8
                        if isAtBottom != atBottom { isAtBottom = atBottom }
                        // contentSize-stable changes imply user-driven scroll; arm
                        // pagination so it only fires after the user actually moved.
                        if !userHasScrolled { userHasScrolled = true }
                        if new.contentOffsetY != old.contentOffsetY {
                            let up = new.contentOffsetY < old.contentOffsetY
                            if scrollingUp != up { scrollingUp = up }
                        }
                    }
                    .onScrollPhaseChange { _, phase in
                        if !phase.isScrolling, scrollingUp { scrollingUp = false }
                    }
                    // Which edge keeps still when the content changes size. Rows built
                    // above the viewport while scrolling up settle their real heights,
                    // and older pages are prepended there: pinning the bottom keeps the
                    // rows on screen in place without any scrolling of our own. Scrolling
                    // down (newer pages appended, rows below settling) and at rest
                    // (incoming messages while reading history) pin the top instead.
                    .defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)
                    // Dedicated content-height tracker for the settle loops (kept in the
                    // tracker, not @State, so growth doesn't re-render the list). The ScrollSnapshot observer above bails early on
                    // contentSize changes (to preserve user-driven isAtBottom), so it
                    // can't be used to watch growth; this one records height on every
                    // change, including the async bubble-sizing growth we wait out.
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, newValue in
                        visibleRows.contentHeight = newValue
                    }
                    .task {
                        // Initial positioning. This `default` branch only renders once the
                        // store is `.loaded` (the `.loadingFirstPage` case keeps the spinner
                        // up), so `store.rows` is fully populated — true for BOTH the fast
                        // path (warmed before push) and the slow path (warm finished after
                        // push, swapping this branch in).
                        //
                        // We drive BOTH the unread (→ divider, `.top`) and the read (→ tail,
                        // `.bottom`) cases imperatively. We do NOT use
                        // `.defaultScrollAnchor(.bottom)`: it latches the bottom offset at the
                        // first, too-short layout and reverts to that stale offset as content
                        // grows — landing ~1 screen above the true tail. In the lazy stack the
                        // heights of rows that haven't been built yet are estimates, which makes
                        // the first `scrollTo` land short in the same way; the re-pin loop
                        // below absorbs both.
                        //
                        // The hard part is TIMING: bubble heights settle a few frames AFTER
                        // first layout — media (photos, videos, maps, stickers) async-size well
                        // past any fixed delay. A guessed sleep fires the scroll while
                        // contentSize is still too short; as bubbles above the anchor then
                        // grow, `bottomAnchor` is pushed down and we're left parked ~1 screen
                        // above the tail (the original regression — a fixed 50ms sleep was not
                        // enough for media-heavy chats). So instead of guessing, re-pin every
                        // frame until contentSize stops changing (stable for a few consecutive
                        // frames), capped so a never-settling chat still reveals. The `.overlay`
                        // cover (gated on `!didApplyInitialScroll`) hides the whole settle so
                        // there's no visible movement.
                        guard !didApplyInitialScroll else { return }
                        let applyInitialPosition: @MainActor () -> Void = {
                            if let target = store.window.initialScrollTargetId {
                                proxy.scrollTo(target, anchor: .top)
                            } else {
                                proxy.scrollTo("bottomAnchor", anchor: .bottom)
                            }
                        }
                        var lastHeight: CGFloat = -1
                        var stableFrames = 0
                        for _ in 0..<90 {                       // ~1.5s cap at one frame each
                            applyInitialPosition()
                            try? await Task.sleep(nanoseconds: 16_000_000)
                            let height = visibleRows.contentHeight
                            if height == lastHeight {
                                stableFrames += 1
                                if stableFrames >= 3 { break }  // settled for ~3 frames
                            } else {
                                stableFrames = 0
                                lastHeight = height
                            }
                        }
                        // Final pin once content has settled, plus one runloop pass to catch
                        // any last residual growth between the final sleep and reveal.
                        applyInitialPosition()
                        await Task.yield()
                        applyInitialPosition()
                        // Parked on the unread divider → not at the bottom, so incoming
                        // messages must not pull the list down past what the user is reading.
                        isAtBottom = store.window.initialScrollTargetId == nil
                        didApplyInitialScroll = true
                    }
                    // Keyed on the first message, not the first row: that is a day separator,
                    // which keeps its id when the prepended page is from the same day.
                    .onChange(of: store.rows.first(where: { $0.messageId != nil })?.id) { oldId, newId in
                        // Older rows were prepended. The scroll view keeps its absolute
                        // offset, which would leave the user looking at the top of the new
                        // page. Put the topmost message that was on screen back at the top.
                        // The visibility set still describes the old layout here: callbacks
                        // for the new layout arrive after this update. Separators are
                        // skipped as anchors because a same-day one moves up with the page.
                        guard restoreAfterPrepend, let oldId, oldId != newId else { return }
                        // The bottom-pinned size-change anchor (see .defaultScrollAnchor)
                        // keeps the rows in place. Check that it did, and fall back to
                        // scrolling the anchor row back if it didn't.
                        guard let anchor = viewportAnchor() else {
                            proxy.scrollTo(oldId, anchor: .top)
                            DebugTrace.log("prepend restore fallback=\(oldId) visible=\(visibleRows.ids.count)")
                            return
                        }
                        let pinned = sizeChangeAnchor == .bottom ? "bottom" : "top"
                        Task {
                            try? await Task.sleep(nanoseconds: 33_000_000)
                            let drift = visibleRows.frames[anchor.rowId].map { $0.minY - anchor.top }
                            if drift.map({ abs($0) > 40 }) ?? true {
                                proxy.scrollTo(anchor.rowId, anchor: .top)
                            }
                            DebugTrace.log("prepend keep anchor=\(anchor.rowId) drift=\(drift.map { String(format: "%.1f", $0) } ?? "gone") pinned=\(pinned) visible=\(visibleRows.ids.count)")
                        }
                    }
                    .onChange(of: jumpToBottomRequest) {
                        if let back = replyReturnStack.popLast() {
                            returnFromReply(to: back, proxy: proxy)
                        } else {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                    .onChange(of: store.rows.last?.id) { _, newId in
                        // Telegram convention: outgoing always pulls to bottom; incoming only
                        // pulls if the user was already parked there. Only auto-scroll when we
                        // actually have the chat tail loaded — otherwise rows.last is just the
                        // bottom of the current window, not the latest message. Also gate on
                        // didApplyInitialScroll so the initial fill (where rows.last?.id
                        // transitions from nil → some-id mid-load) doesn't double-fire with
                        // the .task initial-scroll handler.
                        guard didApplyInitialScroll,
                              newId != nil,
                              store.window.reachesChatTail,
                              case .bubble(let bubble) = store.rows.last else { return }
                        guard bubble.isOutgoing || isAtBottom else {
                            newBelowCount += 1
                            return
                        }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottomAnchor", anchor: .bottom)
                        }
                    }
                    .onChange(of: isAtBottom) { _, atBottom in
                        guard atBottom else { return }
                        newBelowCount = 0
                        replyReturnStack.removeAll()
                    }
                }
            }
            // Cover the first-layout→settle window (the `.task` above re-pins to the final
            // position until contentSize stabilizes) so the user never sees the jump.
            // Covers BOTH cases: the unread divider (`.top`) and the read tail (`.bottom`)
            // are both placed imperatively after the content settles, because there is no
            // `.defaultScrollAnchor(.bottom)` to hold position while bubbles async-grow
            // (it reverts to a stale first-layout offset — see the `.task` comment).
            .overlay {
                if !didApplyInitialScroll {
                    LoadingView(label: "Loading messages…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.ignoresSafeArea())
                }
            }
        }
    }

    /// The chat isn't showing its newest messages: the user scrolled up, jumped to a
    /// reply, or opened on the unread divider.
    private var showsJumpToBottom: Bool {
        didApplyInitialScroll && (!isAtBottom || !store.window.reachesChatTail)
    }

    @ViewBuilder
    private var unseenBadge: some View {
        let unseen = newBelowCount + store.unseenNewerCount
        if unseen > 0 {
            Text(unseen > 99 ? "99+" : "\(unseen)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(Color.accentColor))
                .offset(x: 4, y: -4)
                .allowsHitTesting(false)
        }
    }

    /// Jump-to-bottom tap: reloads the chat tail first when the window was moved away
    /// from it (a reply jump, or paging up far), then pins the bottom while the lazy
    /// rows above it settle their heights.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        DebugTrace.log("jumpToBottom tap atBottom=\(isAtBottom) tail=\(store.window.reachesChatTail) rows=\(store.rows.count)")
        Task {
            await store.jumpToBottom()
            DebugTrace.log("jumpToBottom loaded tail=\(store.window.reachesChatTail) rows=\(store.rows.count)")
            // The lazy stack can only resolve ids of rows it hasn't built yet through its
            // ForEach data, so `bottomAnchor` (a static view) is unreachable from far up.
            // Scroll to the last message first, which builds the bottom of the stack.
            if let lastId = store.rows.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            // Same settle loop as the initial positioning: re-pin every frame until the
            // lazy rows above the bottom stop changing the content height.
            var lastHeight: CGFloat = -1
            var stableFrames = 0
            for _ in 0..<45 {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
                try? await Task.sleep(nanoseconds: 16_000_000)
                if visibleRows.contentHeight == lastHeight {
                    stableFrames += 1
                    if stableFrames >= 3 { break }
                } else {
                    stableFrames = 0
                    lastHeight = visibleRows.contentHeight
                }
            }
            proxy.scrollTo("bottomAnchor", anchor: .bottom)
            isAtBottom = true
            newBelowCount = 0
            replyReturnStack.removeAll()
            DebugTrace.log("jumpToBottom done")
        }
    }

    /// Reply-header tap: loads the replied-to message if needed, scrolls it into the
    /// middle of the screen and flashes its row. Remembers where the tapped message was,
    /// so the jump-to-bottom button can bring the user back there first.
    private func jumpToMessage(_ messageId: Int64, from sourceRowId: String?, proxy: ScrollViewProxy) {
        let origin = sourceRowId.flatMap { viewportAnchor(rowId: $0) } ?? viewportAnchor()
        Task {
            guard await store.reveal(messageId: messageId),
                  let rowId = store.rows.first(where: { $0.messageId == messageId })?.id else { return }
            if let origin { replyReturnStack.append(origin) }
            // The replied-to message is above the tail: offer the way back down.
            isAtBottom = false
            let settled = await scrollAndSettle(on: rowId, proxy: proxy)
            DebugTrace.log("reply jump to=\(rowId) from=\(origin?.rowId ?? "nil") stack=\(replyReturnStack.count) \(settled)")
            await flash(rowId)
        }
    }

    /// Scrolls `rowId` to the middle of the screen and keeps it there until it stops
    /// moving. A lazy stack only estimates the heights of rows it hasn't built, so one
    /// `scrollTo` into far rows lands off once those rows are built and measured.
    /// Returns a summary for the trace.
    private func scrollAndSettle(on rowId: String, proxy: ScrollViewProxy) async -> String {
        // Let a rebuilt window lay out before scrolling into it.
        try? await Task.sleep(nanoseconds: 50_000_000)
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(rowId, anchor: .center)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let middle = (visibleRows.viewport?.containerSizeH ?? 0) / 2
        let missBefore = visibleRows.frames[rowId].map { $0.midY - middle }
        var lastY: CGFloat?
        var stableFrames = 0
        var pins = 0
        while pins < 45 {
            let y = visibleRows.frames[rowId]?.midY
            if let y, abs(y - middle) < 2 { break }
            if let y, let lastY, abs(y - lastY) < 0.5 {
                // Parked off-middle but still: the row can't reach the middle (near
                // an end of the content).
                stableFrames += 1
                if stableFrames >= 3 { break }
            } else {
                stableFrames = 0
            }
            lastY = y
            proxy.scrollTo(rowId, anchor: .center)
            pins += 1
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        let missAfter = visibleRows.frames[rowId].map { $0.midY - middle }
        func fmt(_ v: CGFloat?) -> String { v.map { String(format: "%.1f", $0) } ?? "unbuilt" }
        return "miss=\(fmt(missBefore))->\(fmt(missAfter)) pins=\(pins)"
    }

    /// Briefly highlights a row the user was brought to.
    private func flash(_ rowId: String) async {
        highlightedRowId = rowId
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if highlightedRowId == rowId {
            withAnimation(.easeOut(duration: 0.4)) { highlightedRowId = nil }
        }
    }

    /// The edge pinned when the content size changes (see `.defaultScrollAnchor`).
    private var sizeChangeAnchor: UnitPoint {
        // Parked at the chat's tail: stay there as messages arrive and rows settle.
        if isAtBottom && store.window.reachesChatTail { return .bottom }
        // An older page is loading or just landed above the viewport.
        if restoreAfterPrepend { return .bottom }
        return scrollingUp ? .bottom : .top
    }

    // MARK: - Viewport anchors

    /// Where a message sits on screen now, to put it back there after the rows around it
    /// change. Uses `rowId` when it's on screen, else the visible message nearest the
    /// middle of the screen (an anchor near the top edge may be almost scrolled off).
    /// Separators are never anchors: a same-day one moves up with a prepended page.
    private func viewportAnchor(rowId: String? = nil) -> ViewportAnchor? {
        let frames = visibleRows.frames
        let candidate: String?
        if let rowId, frames[rowId] != nil {
            candidate = rowId
        } else {
            let middle = visibleRows.viewport.map { $0.containerSizeH / 2 } ?? 0
            candidate = store.rows
                .filter { $0.messageId != nil && visibleRows.ids.contains($0.id) && frames[$0.id] != nil }
                .min { abs(frames[$0.id]!.midY - middle) < abs(frames[$1.id]!.midY - middle) }?
                .id
        }
        guard let id = candidate, let frame = frames[id],
              let messageId = store.rows.first(where: { $0.id == id })?.messageId else { return nil }
        return ViewportAnchor(rowId: id, messageId: messageId, top: frame.minY, height: frame.height)
    }

    /// Jump-to-bottom tap after a reply jump: reloads the window around the message the
    /// jump started from, if it was replaced, and brings it to the middle of the screen.
    private func returnFromReply(to anchor: ViewportAnchor, proxy: ScrollViewProxy) {
        DebugTrace.log("reply return to=\(anchor.rowId) left=\(replyReturnStack.count)")
        Task {
            guard await store.reveal(messageId: anchor.messageId) else {
                replyReturnStack.removeAll()
                scrollToBottom(proxy: proxy)
                return
            }
            let settled = await scrollAndSettle(on: anchor.rowId, proxy: proxy)
            DebugTrace.log("reply returned to=\(anchor.rowId) \(settled)")
            await flash(anchor.rowId)
        }
    }
}

/// A message's place on screen: its row's top edge in the scroll view's visible area.
private struct ViewportAnchor {
    let rowId: String
    let messageId: Int64
    let top: CGFloat
    let height: CGFloat
}

private extension MessageRow {
    /// Message id behind a bubble or service row; nil for separators and the divider.
    var messageId: Int64? {
        switch self {
        case .bubble(let bubble): return bubble.messageId
        case .service(let line): return line.messageId
        case .daySeparator, .unreadDivider: return nil
        }
    }
}

/// Rows currently on screen and their frames. A plain reference held in `@State` so
/// the per-row callbacks, which fire on every scroll step, don't invalidate the view;
/// it is only read to anchor the viewport (older-page prepend, reply jumps).
private final class VisibleRowTracker {
    var ids: Set<String> = []
    /// Frames of built rows in the scroll view's visible area.
    var frames: [String: CGRect] = [:]
    var viewport: ScrollSnapshot?
    /// Content height, polled by the settle loops to tell when rows stop resizing.
    var contentHeight: CGFloat = 0
}
