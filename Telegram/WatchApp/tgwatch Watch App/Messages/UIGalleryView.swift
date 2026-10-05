#if DEBUG
import SwiftUI
import TDShim
import UIKit

/// Settings ▸ UI Gallery (Debug builds only). A made-up chat that shows every kind of
/// message in the states its bubble can draw: both directions, group sender names,
/// replies, delivery status, reactions, media before and after download, transcripts,
/// polls. It goes through the real row views on the real chat background, so layout
/// breakage shows up without hunting for a chat that has it. Nothing here talks to
/// TDLib: downloads never finish, and taps open the real sheets in their empty states.
/// Fork only.
struct UIGalleryView: View {
    /// Section title (or its start, any case) to open at; nil or "1" = the top.
    var startSection: String? = nil

    @State private var store: ChatHistoryStore
    @State private var media: GalleryMedia?
    @State private var sections: [GallerySection] = []
    /// Messages typed into the reply bar: pending for a moment, then sent.
    @State private var typed: [MessageRow] = []
    @State private var showSections = false
    @State private var jumpRequest: String?
    @State private var presentedPhoto: PhotoVisual?
    @State private var presentedVideo: VideoVisual?
    @State private var presentedVideoNote: VideoNoteVisual?
    @State private var presentedPoll: PollVoteTarget?
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollGeometry = GalleryScrollGeometry()

    init(startSection: String? = nil) {
        self.startSection = startSection
        _store = State(initialValue: ChatHistoryStore(
            chatId: -1,
            chatType: .chatTypePrivate(ChatTypePrivate(userId: 0)),
            lastReadInboxMessageId: 0,
            unreadCount: 0,
            lastMessageId: nil,
            loader: GalleryLoader()
        ))
    }

    var body: some View {
        Group {
            if media == nil {
                ProgressView("Drawing samples…")
            } else {
                list
            }
        }
        .navigationTitle("UI Gallery")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSections = true } label: { Image(systemName: "list.bullet") }
                    .disabled(sections.isEmpty)
            }
        }
        .sheet(isPresented: $showSections) {
            List(sections) { section in
                Button(section.title) {
                    showSections = false
                    jumpRequest = section.id
                }
            }
        }
        .sheet(item: $presentedPhoto) { PhotoViewerView(photo: $0).environment(store) }
        .sheet(item: $presentedVideo) { VideoPlayerView(video: $0).environment(store) }
        .sheet(item: $presentedVideoNote) { VideoNotePlayerView(note: $0).environment(store) }
        .sheet(item: $presentedPoll) { target in
            PollVoteView(initialPoll: target.poll, currentPoll: { target.poll }, onVote: { _ in false })
        }
        .task {
            guard media == nil else { return }
            let rendered = GalleryMedia.render()
            seedTranscripts()
            sections = GallerySection.all(rendered)
            media = rendered
            if let start = startSection?.lowercased(),
               let section = sections.first(where: { $0.title.lowercased().hasPrefix(start) }) {
                try? await Task.sleep(for: .milliseconds(300))
                jumpRequest = section.id
            }
            if ProcessInfo.processInfo.environment["TGWATCH_UI_GALLERY_TOUR"] == "1" {
                await tour()
            }
        }
    }

    /// Screenshot pass (`gallery-tour.sh`): scrolls down about 80% of a screen at a
    /// time from wherever the gallery opened and, once each step has settled, writes
    /// the step number to `Caches/ui-gallery/tour-step` for the script to capture;
    /// "done" at the bottom.
    private func tour() async {
        let marker = GalleryMedia.directory.appendingPathComponent("tour-step")
        try? await Task.sleep(for: .seconds(1.5))
        var y = scrollGeometry.offset
        var step = 0
        while true {
            scrollPosition.scrollTo(y: y)
            try? await Task.sleep(for: .milliseconds(900))
            try? "\(step)".write(to: marker, atomically: true, encoding: .utf8)
            try? await Task.sleep(for: .milliseconds(900))
            let maxOffset = scrollGeometry.contentHeight - scrollGeometry.containerHeight
            if y >= maxOffset - 1 { break }
            y = min(y + scrollGeometry.containerHeight * 0.8, maxOffset)
            step += 1
        }
        try? "done".write(to: marker, atomically: true, encoding: .utf8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sections) { section in
                        GallerySectionHeader(title: section.title).id(section.id)
                        ForEach(section.rows, id: \.id) { row(for: $0) }
                    }
                    if !typed.isEmpty {
                        GallerySectionHeader(title: "Typed here")
                        ForEach(typed, id: \.id) { row(for: $0) }
                    }
                    ReplyBar(onAttachTap: {}, onSend: send)
                        .padding(.top, 8)
                    Color.clear.frame(height: 19)
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
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: GalleryScrollGeometry.self) { geometry in
                GalleryScrollGeometry(
                    offset: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height - geometry.contentInsets.top
                )
            } action: { _, new in
                scrollGeometry = new
            }
            .onChange(of: jumpRequest) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .top)
                jumpRequest = nil
            }
        }
    }

    private func row(for row: MessageRow) -> some View {
        MessageRowView(
            row: row,
            onPhotoTap: { presentedPhoto = $0 },
            onVideoTap: { presentedVideo = $0 },
            onVideoNoteTap: { presentedVideoNote = $0 },
            onPollTap: { id, poll in presentedPoll = PollVoteTarget(id: id, poll: poll) }
        )
    }

    private func send(_ text: String) {
        let id = Int64(100_000 + typed.count)
        typed.append(.bubble(GalleryBuilder.textBubble(id: id, body: text, state: .pending)))
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if let i = typed.firstIndex(where: { $0.id == "msg-\(id)" }) {
                typed[i] = .bubble(GalleryBuilder.textBubble(id: id, body: text, state: .sent, unread: true))
            }
        }
    }

    private func seedTranscripts() {
        let speech = SpeechRecognizer.shared
        speech.setGalleryState(key: "gallery-final", text: "Привет, я буду минут через десять, возьми кофе.")
        speech.setGalleryState(
            key: "gallery-final-long",
            text: "Короче, слушай. Я сегодня весь день просидел над этой штукой, и в итоге выяснилось, что проблема вообще не в сети, а в том, что кэш не сбрасывался после логаута. Завтра расскажу подробнее, сейчас уже засыпаю."
        )
        speech.setGalleryState(key: "gallery-partial", partial: "Слушай, я тут подумал, может")
        speech.setGalleryState(key: "gallery-progress", inProgress: true)
        speech.setGalleryState(key: "gallery-error", error: "Couldn't decode the audio")
        speech.setGalleryState(key: "gallery-out", text: "Ok, see you there.")
    }
}

private struct GalleryScrollGeometry: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var containerHeight: CGFloat = 0
}

private struct GallerySectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.yellow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.leading, 4)
    }
}

// MARK: - Samples

struct GallerySection: Identifiable {
    let title: String
    let rows: [MessageRow]
    var id: String { "gallery-section-\(title)" }

    @MainActor
    static func all(_ m: GalleryMedia) -> [GallerySection] {
        var b = GalleryBuilder()
        let alice = GallerySender(name: "Alice", userId: 101)
        let bob = GallerySender(name: "Bob", userId: 102)
        let longName = GallerySender(name: "Константин Константинопольский-Александровский", userId: 103)
        let thumbs = [alice, bob, longName, GallerySender(name: "Ира", userId: 104), GallerySender(name: "Max", userId: 105), GallerySender(name: "Zoë", userId: 106)]

        let replyIn = ReplyHeader(senderName: "Alice", snippet: "Are we still on for tonight?", minithumbnail: nil, isOutgoing: false)
        let replyOut = ReplyHeader(senderName: "You", snippet: "Sure", minithumbnail: nil, isOutgoing: true)
        let replyPhoto = ReplyHeader(senderName: "Bob", snippet: "Photo", minithumbnail: m.landscape.mini, isOutgoing: false)
        let replyLong = ReplyHeader(
            senderName: longName.name,
            snippet: "Очень длинное сообщение, на которое отвечают, чтобы проверить, как обрезается превью в заголовке ответа",
            minithumbnail: nil, isOutgoing: false,
            senderColorIndex: paletteIndex(for: longName.userId)
        )

        let thumbsUp = ReactionChip(type: .reactionTypeEmoji(ReactionTypeEmoji(emoji: "👍")), count: 1, isChosen: false)
        let many: [ReactionChip] = ["👍", "❤️", "🔥", "😂", "😮", "😢", "🎉", "🤔", "👏"].enumerated().map { i, e in
            ReactionChip(type: .reactionTypeEmoji(ReactionTypeEmoji(emoji: e)), count: i * 7 + 1, isChosen: i == 1)
        }

        var sections: [GallerySection] = []

        sections.append(.init(title: "Text", rows: [
            b.msg(false, "Hi!"),
            b.msg(true, "Hey"),
            b.msg(false, "Слушай, а ты помнишь, где мы в прошлый раз оставили зарядку от часов? Я всё обыскал, нигде нет, а часы уже на пяти процентах."),
            b.msg(true, "Кажется, в машине, в бардачке. Если нет, то у мамы на кухне, я её там точно видел в воскресенье."),
            b.msg(false, "https://example.com/a/very/long/path/without/any/spaces/that/has/to/wrap/somewhere?query=abcdefghijklmnopqrstuvwxyz0123456789"),
            b.msg(true, "Supercalifragilisticexpialidocious_without_any_breaks_at_all_1234567890"),
            b.msg(false, "Line one\nLine two\n\n\nAfter three newlines"),
            b.msg(false, "👍"),
            b.msg(true, "🔥🔥"),
            b.msg(false, "😂😂😂"),
            b.msg(false, "🎉🎉🎉🎉🎉"),
            b.msg(true, "Ок 👌"),
            b.msg(false, "مرحبا، كيف حالك اليوم؟ هذا نص طويل باللغة العربية"),
            b.msg(false, "これは日本語の長いメッセージです。折り返しを確認します。"),
            b.msg(false, "a"),
        ]))

        sections.append(.init(title: "Group senders", rows: thumbs.map { b.msg(false, "Message from \($0.name)", sender: $0) } + [
            b.msg(false, "👍", sender: alice),
            b.msg(false, "", sender: bob, sticker: m.sticker(.webp)),
            b.msg(false, "", sender: alice, photo: m.photo(m.landscape, b.file())),
            b.msg(false, "", sender: longName, voice: m.voice(b.file(), duration: 7)),
        ]))

        sections.append(.init(title: "Replies", rows: [
            b.msg(false, "Yes, at 8", reply: replyOut),
            b.msg(true, "Great, see you", reply: replyIn),
            b.msg(false, "Nice shot!", reply: replyPhoto),
            b.msg(true, "Ага", reply: replyLong),
            b.msg(false, "Reply in a group", sender: bob, reply: replyIn),
            b.msg(false, "👍", reply: replyIn),
        ]))

        sections.append(.init(title: "Delivery", rows: [
            b.msg(true, "Pending", state: .pending),
            b.msg(true, "Failed to send", state: .failed),
            b.msg(true, "Sent, not read yet", unread: true),
            b.msg(true, "Sent and read"),
            b.msg(true, "Pending, but a longer message that wraps over several lines", state: .pending),
            b.msg(true, "", photo: m.photo(m.square, b.file()), state: .failed),
            b.msg(true, "", voice: m.voice(b.file(), duration: 4), state: .pending),
            b.msg(true, "", sticker: m.sticker(.webp), state: .pending),
            b.msg(true, "", videoNote: m.round(b.file(), loaded: true), unread: true),
            b.msg(true, "🔥", state: .failed),
        ]))

        sections.append(.init(title: "Reactions", rows: [
            b.msg(false, "One reaction", reactions: [thumbsUp]),
            b.msg(true, "Mine", reactions: [ReactionChip(type: .reactionTypeEmoji(ReactionTypeEmoji(emoji: "❤️")), count: 2, isChosen: true)]),
            b.msg(false, "Lots of them", reactions: many),
            b.msg(true, "Lots, outgoing", reactions: many),
            b.msg(false, "Custom & paid", reactions: [
                ReactionChip(type: .reactionTypeCustomEmoji(ReactionTypeCustomEmoji(customEmojiId: 1)), count: 3, isChosen: false),
                ReactionChip(type: .reactionTypePaid, count: 1200, isChosen: false),
            ]),
            b.msg(false, "", photo: m.photo(m.landscape, b.file()), reactions: many),
            b.msg(false, "", sticker: m.sticker(.webp), reactions: [thumbsUp]),
            b.msg(false, "😂", reactions: [thumbsUp]),
            b.msg(false, "", videoNote: m.round(b.file(), loaded: true), reactions: many),
        ]))

        sections.append(.init(title: "Service rows", rows: [
            .daySeparator(DayLabel(key: "gallery-1", label: "Yesterday")),
            .service(ServiceLine(messageId: b.id(), text: "Alice joined the group")),
            .service(ServiceLine(messageId: b.id(), text: "Константин Константинопольский-Александровский added Alice, Bob, Ира, Max and 12 others")),
            .service(ServiceLine(messageId: b.id(), text: "Bob pinned «Очень длинное закреплённое сообщение, которое не помещается в одну строку»")),
            .service(ServiceLine(messageId: b.id(), text: "Photo has expired")),
            .service(ServiceLine(messageId: b.id(), text: "Voice message has expired")),
            .service(ServiceLine(messageId: b.id(), text: "Alice sent a gift 🎁 worth 50 ⭐️")),
            .service(ServiceLine(messageId: b.id(), text: "Bob sent a unique gift 🎁 Plush Pepe #1234")),
            .service(ServiceLine(messageId: b.id(), text: "Alice gifted Telegram Premium for 3 months")),
            .service(ServiceLine(messageId: b.id(), text: "You paid $4.99 for «Подписка на канал»")),
            .service(ServiceLine(messageId: b.id(), text: "Bob marked 3 tasks as done")),
            .service(ServiceLine(messageId: b.id(), text: "Giveaway winners — 10 winners")),
            .unreadDivider(afterMessageId: b.id()),
            .daySeparator(DayLabel(key: "gallery-2", label: "Wednesday, September 30")),
        ]))

        sections.append(.init(title: "Photos", rows: [
            b.msg(false, "", photo: m.photo(m.landscape, b.file())),
            b.msg(true, "", photo: m.photo(m.portrait, b.file())),
            b.msg(false, "Square with a caption", photo: m.photo(m.square, b.file())),
            b.msg(false, "", photo: m.photo(m.tall, b.file())),
            b.msg(true, "", photo: m.photo(m.wide, b.file())),
            b.msg(false, "", photo: m.photo(m.tiny, b.file())),
            b.msg(false, "Loading: minithumbnail only", photo: m.photo(m.landscape, b.file(), loaded: false)),
            b.msg(false, "", photo: m.photo(m.portrait, b.file(), loaded: false, mini: false)),
            b.msg(true, "Подпись под фото длинная-длинная, на несколько строк, чтобы проверить перенос внутри баббла", photo: m.photo(m.landscape, b.file())),
            b.msg(false, "With a reply", photo: m.photo(m.square, b.file()), reply: replyIn),
            b.msg(false, "", photo: m.photo(m.square, b.file()), reply: replyLong),
        ]))

        sections.append(.init(title: "Videos", rows: [
            b.msg(false, "", video: m.video(b.file(), m.landscape, duration: 7)),
            b.msg(true, "", video: m.video(b.file(), m.portrait, duration: 3753)),
            b.msg(false, "Loading, minithumbnail only", video: m.video(b.file(), m.landscape, duration: 42, loaded: false)),
            b.msg(false, "", video: m.video(b.file(), m.square, duration: 15, loaded: false, mini: false)),
            b.msg(true, "Видео с подписью", video: m.video(b.file(), m.landscape, duration: 125)),
            b.msg(false, "With a reply", video: m.video(b.file(), m.wide, duration: 9), reply: replyOut),
        ]))

        sections.append(.init(title: "Round videos", rows: [
            b.msg(false, "", videoNote: m.round(b.file(), loaded: true)),
            b.msg(true, "", videoNote: m.round(b.file(), loaded: true, duration: 59)),
            b.msg(false, "", videoNote: m.round(b.file(), loaded: false)),
            b.msg(false, "", videoNote: m.round(b.file(), loaded: false, mini: false)),
            b.msg(false, "", videoNote: m.round(b.file(), loaded: true), reply: replyLong),
            b.msg(false, "", sender: bob, videoNote: m.round(b.file(), loaded: true)),
        ]))

        sections.append(.init(title: "Voice", rows: [
            b.msg(false, "", voice: m.voice(b.file(), duration: 3)),
            b.msg(false, "", voice: m.voice(b.file(), duration: 165, listened: false)),
            b.msg(true, "", voice: m.voice(b.file(), duration: 12)),
            b.msg(false, "Голосовое с подписью", voice: m.voice(b.file(), duration: 21)),
            b.msg(false, "", voice: m.voice(b.file(), duration: 8, key: "gallery-final")),
            b.msg(false, "", voice: m.voice(b.file(), duration: 48, key: "gallery-final-long")),
            b.msg(false, "", voice: m.voice(b.file(), duration: 30, key: "gallery-partial")),
            b.msg(false, "", voice: m.voice(b.file(), duration: 14, key: "gallery-progress")),
            b.msg(false, "", voice: m.voice(b.file(), duration: 9, key: "gallery-error")),
            b.msg(true, "", voice: m.voice(b.file(), duration: 5, key: "gallery-out")),
            b.msg(false, "", voice: m.voice(b.file(), duration: 3900)),
            b.msg(false, "", voice: m.voice(b.file(), duration: 2, flat: true)),
            b.msg(false, "", voice: m.voice(b.file(), duration: 11), reply: replyIn),
        ]))

        sections.append(.init(title: "Music", rows: [
            b.msg(false, "", audio: m.audio(b.file(), title: "Bohemian Rhapsody", performer: "Queen", duration: 355, art: true)),
            b.msg(true, "", audio: m.audio(b.file(), title: "A Very Long Track Title (Extended Remastered Deluxe Version 2026)", performer: "Some Band With An Equally Long Name feat. Everyone", duration: 4210, art: true)),
            b.msg(false, "", audio: m.audio(b.file(), title: "voice_memo_final_v3.mp3", performer: "", duration: 61, art: false)),
            b.msg(false, "Трек с подписью", audio: m.audio(b.file(), title: "Кино — Группа крови", performer: "Кино", duration: 286, art: true)),
        ]))

        sections.append(.init(title: "Files", rows: [
            b.msg(false, "", document: m.document(b.file(), "report.pdf", 482_133)),
            b.msg(true, "", document: m.document(b.file(), "Очень_длинное_имя_файла_которое_точно_не_поместится_в_одну_строку_v2_final_FINAL.docx", 12_884_901_888)),
            b.msg(false, "", document: m.document(b.file(), "empty.txt", 0)),
            b.msg(false, "", document: m.document(b.file(), "archive.zip", 73_400_320, caption: "Here are the files you asked for")),
            b.msg(false, "", document: m.document(b.file(), "notes.md", 2048), reply: replyIn),
        ]))

        sections.append(.init(title: "Stickers", rows: [
            b.msg(false, "", sticker: m.sticker(.webp)),
            b.msg(true, "", sticker: m.sticker(.tgs)),
            b.msg(false, "", sticker: m.sticker(.unsupported, thumb: true)),
            b.msg(false, "", sticker: m.sticker(.unsupported, emoji: "🐸")),
            b.msg(false, "", sticker: m.sticker(.unsupported, emoji: "")),
            b.msg(false, "", sticker: m.sticker(.webp, loaded: false, thumb: true)),
            b.msg(false, "", sticker: m.sticker(.tgs, loaded: false, thumb: false)),
            b.msg(true, "", sticker: m.sticker(.webp), reply: replyIn),
        ]))

        sections.append(.init(title: "GIFs", rows: [
            b.msg(false, "", video: m.gif(b.file(), m.landscape)),
            b.msg(true, "GIF с подписью", video: m.gif(b.file(), m.square)),
            b.msg(false, "", video: m.gif(b.file(), m.portrait, loaded: false)),
            b.msg(false, "", sender: alice, video: m.gif(b.file(), m.wide)),
            b.msg(false, "Reply with a GIF", video: m.gif(b.file(), m.landscape), reply: replyIn),
        ]))

        sections.append(.init(title: "Animated emoji", rows: [
            b.msg(false, "", sticker: m.sticker(.tgs, emoji: "👍", animatedEmoji: true)),
            b.msg(true, "", sticker: m.sticker(.tgs, emoji: "❤️", animatedEmoji: true)),
            b.msg(false, "", sticker: m.sticker(.tgs, loaded: false, emoji: "😂", animatedEmoji: true)),
            // A skin-toned emoji, or one without an animation, stays a jumbo text emoji.
            b.msg(false, "👍🏽"),
            b.msg(false, "", sender: bob, sticker: m.sticker(.tgs, emoji: "🔥", animatedEmoji: true)),
            b.msg(true, "", sticker: m.sticker(.tgs, emoji: "🎉", animatedEmoji: true), reactions: [thumbsUp]),
        ]))

        sections.append(.init(title: "Dice", rows: [
            b.msg(false, "🎲 5", sticker: m.sticker(.tgs, emoji: "🎲")),
            b.msg(true, "🎯 6", sticker: m.sticker(.tgs, emoji: "🎯")),
            b.msg(false, diceText(emoji: "🎲", value: 0, isSlotMachine: false)),
            b.msg(false, diceText(emoji: "🏀", value: 4, isSlotMachine: false)),
            b.msg(false, diceText(emoji: "🎰", value: 64, isSlotMachine: true)),
            b.msg(true, diceText(emoji: "🎰", value: 23, isSlotMachine: true)),
            b.msg(false, diceText(emoji: "🎰", value: 1, isSlotMachine: true), sender: alice),
        ]))

        let now = Foundation.Date()
        sections.append(.init(title: "Locations", rows: [
            b.msg(false, "", location: LocationVisual(latitude: 55.7558, longitude: 37.6173, title: nil, address: nil, isLive: false, heading: 0, isExpired: false, liveUpdatedAt: nil)),
            b.msg(true, "", location: LocationVisual(latitude: 59.9343, longitude: 30.3351, title: "Кафе «Пышечная»", address: "Большая Конюшенная ул., 25", isLive: false, heading: 0, isExpired: false, liveUpdatedAt: nil)),
            b.msg(false, "", location: LocationVisual(latitude: 48.8584, longitude: 2.2945, title: "Very Long Venue Name That Keeps Going And Going", address: "Champ de Mars, 5 Avenue Anatole France, 75007 Paris, France", isLive: false, heading: 0, isExpired: false, liveUpdatedAt: nil)),
            b.msg(false, "", location: LocationVisual(latitude: 55.75, longitude: 37.62, title: nil, address: nil, isLive: true, heading: 90, isExpired: false, liveUpdatedAt: now.addingTimeInterval(-300))),
            b.msg(true, "", location: LocationVisual(latitude: 55.75, longitude: 37.62, title: nil, address: nil, isLive: true, heading: 0, isExpired: true, liveUpdatedAt: now.addingTimeInterval(-7200))),
            b.msg(false, "", location: LocationVisual(latitude: 55.75, longitude: 37.62, title: nil, address: nil, isLive: false, heading: 0, isExpired: false, liveUpdatedAt: nil), reply: replyIn),
        ]))

        sections.append(.init(title: "Polls", rows: [
            b.msg(false, "", poll: .gallery("Where do we eat tonight?", ["Pizza", "Sushi", "Burgers"], votes: nil)),
            b.msg(false, "", poll: .gallery("Where do we eat tonight?", ["Pizza", "Sushi", "Burgers"], votes: [12, 30, 3], chosen: [1])),
            b.msg(true, "", poll: .gallery("Pick any (multiple answers)", ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun", "Never"], votes: nil, multiple: true)),
            b.msg(false, "", poll: .gallery("2 + 2 = ?", ["3", "4", "22"], votes: [2, 40, 9], chosen: [1], correct: 1)),
            b.msg(false, "", poll: .gallery("Столица Австралии?", ["Сидней", "Канберра", "Мельбурн"], votes: [20, 15, 5], chosen: [0], correct: 1, explanation: "Канберра — столица с 1913 года, её построили как компромисс между Сиднеем и Мельбурном.")),
            b.msg(false, "", poll: .gallery("Closed poll", ["Yes", "No"], votes: [7, 3], closed: true)),
            b.msg(false, "", poll: .gallery(
                "Очень длинный вопрос опроса, который занимает несколько строк, чтобы проверить перенос заголовка?",
                ["Первый очень длинный вариант ответа, который не помещается", "Второй", "Третий вариант тоже довольно длинный, на две строки"],
                votes: [50, 25, 25], chosen: [0]
            )),
        ]))

        sections.append(.init(title: "Unsupported", rows: [
            b.msg(false, "", unsupported: true),
            b.msg(true, "", unsupported: true, reply: replyIn),
        ]))

        return sections
    }
}

struct GallerySender {
    let name: String
    let userId: Int64
}

private struct GalleryBuilder {
    private var nextId: Int64 = 1
    private var nextFile = 10_000

    mutating func id() -> Int64 {
        defer { nextId += 1 }
        return nextId
    }

    mutating func file() -> Int {
        defer { nextFile += 1 }
        return nextFile
    }

    mutating func msg(
        _ isOutgoing: Bool,
        _ body: String = "",
        sender: GallerySender? = nil,
        photo: PhotoVisual? = nil,
        video: VideoVisual? = nil,
        videoNote: VideoNoteVisual? = nil,
        voice: VoiceNoteVisual? = nil,
        audio: AudioVisual? = nil,
        document: DocumentVisual? = nil,
        sticker: StickerVisual? = nil,
        location: LocationVisual? = nil,
        poll: PollVisual? = nil,
        state: SendingState = .sent,
        unread: Bool = false,
        unsupported: Bool = false,
        reply: ReplyHeader? = nil,
        reactions: [ReactionChip] = []
    ) -> MessageRow {
        .bubble(MessageBubble(
            messageId: id(),
            isOutgoing: isOutgoing,
            senderName: sender?.name,
            body: body,
            photo: photo,
            video: video,
            videoNote: videoNote,
            voiceNote: voice,
            audio: audio,
            document: document,
            sticker: sticker,
            location: location,
            poll: poll,
            sendingState: state,
            replyHeader: reply,
            senderColorIndex: sender.map { paletteIndex(for: $0.userId) },
            isUnreadOutgoing: unread,
            isUnsupported: unsupported,
            reactions: reactions
        ))
    }

    static func textBubble(id: Int64, body: String, state: SendingState, unread: Bool = false) -> MessageBubble {
        MessageBubble(
            messageId: id, isOutgoing: true, senderName: nil, body: body,
            photo: nil, video: nil, videoNote: nil, voiceNote: nil, audio: nil, document: nil,
            sticker: nil, location: nil, poll: nil, sendingState: state, replyHeader: nil,
            isUnreadOutgoing: unread
        )
    }
}

private extension PollVisual {
    /// `votes` nil = not voted yet; `correct` makes it a quiz.
    static func gallery(
        _ question: String,
        _ options: [String],
        votes: [Int]?,
        chosen: Set<Int> = [],
        multiple: Bool = false,
        correct: Int? = nil,
        explanation: String? = nil,
        closed: Bool = false
    ) -> PollVisual {
        let counts = votes ?? Array(repeating: 0, count: options.count)
        let total = counts.reduce(0, +)
        return PollVisual(
            pollId: 1,
            question: question,
            isQuiz: correct != nil,
            isAnonymous: true,
            isClosed: closed,
            allowsMultipleAnswers: multiple,
            allowsRevoting: true,
            totalVoterCount: total,
            hasVoted: !chosen.isEmpty,
            explanation: explanation,
            options: options.enumerated().map { i, text in
                PollOptionVisual(
                    position: i,
                    text: text,
                    votePercentage: total == 0 ? 0 : counts[i] * 100 / total,
                    voterCount: counts[i],
                    isChosen: chosen.contains(i),
                    isBeingChosen: false,
                    isCorrect: correct.map { $0 == i }
                )
            }
        )
    }
}

// MARK: - Media

/// Placeholder pictures drawn once into Caches, so media bubbles have real files to
/// show in their downloaded state.
struct GalleryMedia {
    struct Picture {
        let width: Int
        let height: Int
        let path: String?
        let mini: Data?
    }

    let landscape: Picture
    let portrait: Picture
    let square: Picture
    let tall: Picture
    let wide: Picture
    let tiny: Picture
    let round: Picture
    let albumArt: Data?

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ui-gallery", isDirectory: true)
    }

    @MainActor
    static func render() -> GalleryMedia {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func picture(_ name: String, _ w: Int, _ h: Int, hue: Double, symbol: String) -> Picture {
            let url = dir.appendingPathComponent("\(name).jpg")
            // The drawn file is the "downloaded" photo; 40 px across is a minithumbnail.
            let scale = min(1, 480 / Double(max(w, h)))
            let full = draw(CGSize(width: Double(w) * scale, height: Double(h) * scale), hue: hue, symbol: symbol, label: "\(w)×\(h)")
            let miniScale = 40 / Double(max(w, h))
            let mini = draw(CGSize(width: max(4, Double(w) * miniScale), height: max(4, Double(h) * miniScale)), hue: hue, symbol: symbol, label: "")
            if let data = full?.jpegData(compressionQuality: 0.8) { try? data.write(to: url) }
            return Picture(
                width: w, height: h,
                path: FileManager.default.fileExists(atPath: url.path) ? url.path : nil,
                mini: mini?.jpegData(compressionQuality: 0.5)
            )
        }
        return GalleryMedia(
            landscape: picture("landscape", 1600, 900, hue: 0.55, symbol: "mountain.2.fill"),
            portrait: picture("portrait", 900, 1600, hue: 0.08, symbol: "figure.walk"),
            square: picture("square", 1080, 1080, hue: 0.8, symbol: "cat.fill"),
            tall: picture("tall", 400, 2400, hue: 0.33, symbol: "arrow.up.and.down"),
            wide: picture("wide", 3000, 400, hue: 0.0, symbol: "arrow.left.and.right"),
            tiny: picture("tiny", 48, 48, hue: 0.15, symbol: "star.fill"),
            round: picture("round", 384, 384, hue: 0.62, symbol: "face.smiling"),
            albumArt: draw(CGSize(width: 40, height: 40), hue: 0.9, symbol: "music.note", label: "")?
                .jpegData(compressionQuality: 0.6)
        )
    }

    @MainActor
    private static func draw(_ size: CGSize, hue: Double, symbol: String, label: String) -> UIImage? {
        let side = min(size.width, size.height)
        let content = ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.6, brightness: 0.95),
                    Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 0.4),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: side * 0.04) {
                Image(systemName: symbol).font(.system(size: side * 0.3))
                if !label.isEmpty {
                    Text(label).font(.system(size: max(8, side * 0.09), weight: .bold))
                }
            }
            .foregroundStyle(.white)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.cgImage.map { UIImage(cgImage: $0) }
    }

    func photo(_ p: Picture, _ fileId: Int, loaded: Bool = true, mini: Bool = true) -> PhotoVisual {
        PhotoVisual(
            fileId: fileId,
            width: p.width,
            height: p.height,
            minithumbnail: mini ? p.mini : nil,
            localPath: loaded ? p.path : nil
        )
    }

    func video(_ fileId: Int, _ p: Picture, duration: Int, loaded: Bool = true, mini: Bool = true) -> VideoVisual {
        VideoVisual(
            videoFileId: fileId,
            width: p.width,
            height: p.height,
            duration: duration,
            mimeType: "video/mp4",
            preview: VideoPreview(
                previewFileId: fileId + 50_000,
                previewWidth: p.width,
                previewHeight: p.height,
                minithumbnail: mini ? p.mini : nil,
                previewLocalPath: loaded ? p.path : nil
            ),
            videoLocalPath: nil
        )
    }

    /// A GIF; it plays the clip `gallery-sim.sh` / `gallery-tour.sh` put in Caches.
    func gif(_ fileId: Int, _ p: Picture, loaded: Bool = true) -> VideoVisual {
        let clip = GalleryMedia.directory.appendingPathComponent("gif.mp4").path
        return VideoVisual(
            videoFileId: fileId,
            width: p.width,
            height: p.height,
            duration: 2,
            mimeType: "video/mp4",
            preview: VideoPreview(
                previewFileId: nil,
                previewWidth: p.width,
                previewHeight: p.height,
                minithumbnail: p.mini,
                previewLocalPath: loaded ? p.path : nil
            ),
            videoLocalPath: FileManager.default.fileExists(atPath: clip) ? clip : nil,
            isAnimation: true
        )
    }

    func round(_ fileId: Int, loaded: Bool, mini: Bool = true, duration: Int = 12) -> VideoNoteVisual {
        VideoNoteVisual(
            videoFileId: fileId,
            length: 384,
            duration: duration,
            thumbFileId: fileId + 50_000,
            minithumbnail: mini ? round.mini : nil,
            thumbLocalPath: loaded ? round.path : nil,
            videoLocalPath: nil
        )
    }

    /// `key` is the transcript key (the voice file's unique id); "" keeps the note
    /// without one. `flat` gives an all-silent waveform.
    func voice(_ fileId: Int, duration: Int, listened: Bool = true, key: String = "", flat: Bool = false) -> VoiceNoteVisual {
        let amplitudes: [Float] = flat
            ? Array(repeating: 0, count: 32)
            : (0..<64).map { i in Float(0.15 + 0.85 * abs(sin(Double(i + fileId) * 0.45) * cos(Double(i) * 0.13))) }
        return VoiceNoteVisual(
            voiceFileId: fileId,
            duration: duration,
            mimeType: "audio/ogg",
            waveform: flat ? Data(count: WaveformPacker.byteCount) : WaveformPacker.pack(amplitudes),
            caption: "",
            localPath: nil,
            uniqueId: key,
            isListened: listened
        )
    }

    func audio(_ fileId: Int, title: String, performer: String, duration: Int, art: Bool) -> AudioVisual {
        AudioVisual(
            audioFileId: fileId,
            duration: duration,
            title: title,
            performer: performer,
            albumArt: art ? albumArt : nil,
            caption: "",
            localPath: nil
        )
    }

    func document(_ fileId: Int, _ name: String, _ size: Int64, caption: String = "") -> DocumentVisual {
        DocumentVisual(documentFileId: fileId, fileName: name, sizeBytes: size, localPath: nil, caption: caption)
    }

    func sticker(_ format: StickerFormatKind, loaded: Bool = true, thumb: Bool = false, emoji: String = "✨", animatedEmoji: Bool = false) -> StickerVisual {
        func sample(_ name: String, _ ext: String) -> String? {
            Bundle.main.path(forResource: name, ofType: ext, inDirectory: "SampleStickers")
                ?? Bundle.main.path(forResource: name, ofType: ext)
        }
        let path: String? = {
            guard loaded else { return nil }
            switch format {
            case .webp: return sample("sticker_raster", "webp")
            case .tgs: return sample("sticker_lottie", "tgs")
            case .unsupported: return sample("sticker_vp9", "webm")
            }
        }()
        // A video sticker's still is all that's ever downloaded for it, so show it ready.
        let thumbPath = thumb && format == .unsupported ? sample("sticker_raster", "webp") : nil
        return StickerVisual(
            fileId: Int.random(in: 1_000_000...9_000_000),
            isAnimatedEmoji: animatedEmoji,
            format: format,
            width: 512,
            height: 512,
            emoji: emoji,
            localPath: path,
            thumbnailFileId: thumb ? Int.random(in: 1_000_000...9_000_000) : nil,
            thumbnailLocalPath: thumbPath,
            thumbnailFormat: thumb ? .webp : nil
        )
    }
}

// MARK: - Loader

/// Nothing to load and nothing to send: downloads never finish, so media stays in
/// the state the sample was built with.
private struct GalleryLoader: ChatHistoryLoader {
    func openChat(chatId: Int64) async throws {}
    func closeChat(chatId: Int64) async throws {}
    func loadHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message] { [] }
    func downloadFile(fileId: Int, priority: Int) async throws -> File { throw CancellationError() }
    func cancelDownloadFile(fileId: Int) async throws {}
    func sendText(chatId: Int64, text: String) async throws -> Message { throw CancellationError() }
    func sendVoiceNote(chatId: Int64, fileURL: URL, duration: Int, waveform: Data) async throws -> Message { throw CancellationError() }
    func setChatDraftMessage(chatId: Int64, draftText: String) async throws {}
    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool) async throws {}
    func setPollAnswer(chatId: Int64, messageId: Int64, optionIds: [Int]) async throws {}
    func sendSticker(chatId: Int64, remoteFileId: String, emoji: String, width: Int, height: Int) async throws -> Message { throw CancellationError() }
    func sendLocation(chatId: Int64, latitude: Double, longitude: Double) async throws -> Message { throw CancellationError() }
}
#endif
