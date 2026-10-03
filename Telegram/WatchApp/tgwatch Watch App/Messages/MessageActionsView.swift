import SwiftUI
import TDShim

/// Reactions under a bubble. Tapping one adds or removes the user's reaction.
struct ReactionChipsView: View {
    let messageId: Int64
    let chips: [ReactionChip]
    let isOutgoing: Bool

    @Environment(ChatHistoryStore.self) private var store: ChatHistoryStore?

    var body: some View {
        FlowLayout(spacing: 3, alignment: isOutgoing ? .trailing : .leading) {
            ForEach(chips, id: \.type) { chip in
                Button {
                    guard let store else { return }
                    Task { await store.toggleReaction(messageId: messageId, type: chip.type) }
                } label: {
                    Text(chip.count > 1 ? "\(chip.label) \(chip.count)" : chip.label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(chip.isChosen ? Color.accentColor : Color.gray.opacity(0.35))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Long-press menu for a message: quick reactions, and edit / delete for the user's
/// own messages when Telegram allows them.
struct MessageActionsView: View {
    let bubble: MessageBubble
    let store: ChatHistoryStore

    @Environment(\.dismiss) private var dismiss
    @State private var actions: MessageActions?
    @State private var pendingDelete: DeleteScope?

    private enum DeleteScope: Identifiable {
        case everyone, me
        var id: Self { self }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let actions {
                    reactionGrid(actions)
                    editAndDelete(actions)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .padding(.horizontal, 4)
        }
        .task { actions = await store.actions(forMessageId: bubble.messageId) }
        .confirmationDialog(
            "Delete message?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { scope in
            Button(scope == .everyone ? "Delete for everyone" : "Delete for me", role: .destructive) {
                let messageId = bubble.messageId
                Task {
                    await store.deleteMessage(messageId: messageId, forEveryone: scope == .everyone)
                    dismiss()
                }
            }
        }
    }

    private func reactionGrid(_ actions: MessageActions) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(actions.reactions.prefix(12), id: \.self) { type in
                let chosen = actions.chosenReactions.contains(type)
                Button {
                    let messageId = bubble.messageId
                    Task {
                        await store.toggleReaction(messageId: messageId, type: type)
                        dismiss()
                    }
                } label: {
                    Text(ReactionChip(type: type, count: 1, isChosen: chosen).label)
                        .font(.title3)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(chosen ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.25))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func editAndDelete(_ actions: MessageActions) -> some View {
        if let properties = actions.properties {
            if properties.canBeEdited, isPlainText {
                // TextFieldLink can't start from the old text; the prompt shows it.
                TextFieldLink(prompt: Text(bubble.body)) {
                    Label("Edit", systemImage: "pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } onSubmit: { text in
                    let messageId = bubble.messageId
                    Task {
                        await store.editMessageText(messageId: messageId, text: text)
                        dismiss()
                    }
                }
            }
            if properties.canBeDeletedForAllUsers {
                Button(role: .destructive) {
                    pendingDelete = .everyone
                } label: {
                    Label(properties.canBeDeletedOnlyForSelf ? "Delete for everyone" : "Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if properties.canBeDeletedOnlyForSelf {
                Button(role: .destructive) {
                    pendingDelete = .me
                } label: {
                    Label("Delete for me", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// A text message (no media), the only kind editMessageText changes.
    private var isPlainText: Bool {
        bubble.photo == nil && bubble.video == nil && bubble.videoNote == nil
            && bubble.voiceNote == nil && bubble.audio == nil && bubble.document == nil
            && bubble.sticker == nil && bubble.location == nil && bubble.poll == nil
            && !bubble.isUnsupported && !bubble.body.isEmpty
    }
}

/// Lays children out in rows, wrapping to a new row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
