#if DEBUG
import Foundation
import SwiftUI
import TDShim

// Fork-only performance bench for the chat list (`MessageListView`'s LazyVStack) and
// the history loading behind it. Launch with `TGWATCH_PERF_BENCH=<scenario>` (see
// `.claude/watchapp-pr/perf-sim.sh`):
//
// - Synthetic scenarios (`ui`, `mixed`, `slow`, `crown`) open a made-up chat of a few
//   thousand messages through the REAL `ChatHistoryStore` and `MessageListView`. Only
//   TDLib is replaced, by `PerfBenchLoader`, which models what the network costs:
//   history round trips, TDLib's partial pages on a cold cache, and file downloads with
//   a limited number of parallel slots. Pages go through the production JSON decode.
// - `real` opens a real chat (`TGWATCH_PERF_CHAT=<chat id>`) in the logged-in app, so
//   real TDLib, network and update traffic are measured the same way.
//
// The bench then scrolls the chat by itself (flicks with pauses, or a steady crown-like
// glide) up through `depth` messages of history, back down a few screens, and taps
// the jump-to-bottom button, while it records frame gaps, main-thread stalls, page
// timings, the time spent stuck at the top of the content waiting for a page, row
// re-renders, downloads and memory. The summary goes to
// `Library/Caches/perf-bench/result.json`, then the marker `done` is written next to it.

// MARK: - Configuration

struct PerfBenchConfig: Codable {
    enum Scroll: String, Codable { case flicks, crown }

    var scenario: String
    /// Messages in the synthetic chat.
    var messageCount = 2000
    /// Share of messages with media (photos, voice notes, stickers).
    var mediaShare = 0.35
    /// A history request TDLib has to send to the server: round trip, and its jitter.
    var historyLatencyMs = 300
    var historyJitterMs = 120
    /// A history request TDLib can answer from its database.
    var localLatencyMs = 15
    /// TDLib on a cold cache: a request for messages it doesn't have yet returns only
    /// this many (it fetches the rest from the server for the next request). 0 = full pages.
    var coldPageSize = 0
    /// Newest messages already in TDLib's database when the chat opens.
    var localTailCount = 60
    /// One file download (photo / sticker), and how many run at once.
    var downloadMs = 700
    var downloadSlots = 3
    var scroll: Scroll = .flicks
    /// Flick start speed (pt/s; it decays like a scroll view's), crown glide speed (pt/s).
    var flickSpeed = 1500.0
    var crownSpeed = 260.0
    /// Messages of history to page through on the way up.
    var depth = 600
    /// Hard cap for the whole run (s).
    var timeLimit = 90.0
    /// `real` only: the chat to open, by id or by part of its title.
    var chatId: Int64 = 0
    var chatTitle = ""
    /// A/B switch: no fetching of media ahead of the scroll.
    var noMediaPrefetch = false

    var isReal: Bool { scenario == "real" }

    func matches(_ row: ChatRow) -> Bool {
        if chatId != 0 { return row.id == chatId }
        return !chatTitle.isEmpty && row.title.localizedCaseInsensitiveContains(chatTitle)
    }

    static func fromEnvironment() -> PerfBenchConfig? {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["TGWATCH_PERF_BENCH"], !name.isEmpty else { return nil }
        var c = PerfBenchConfig(scenario: name)
        switch name {
        case "ui":
            // Pure UI cost: everything is in the database and downloads finish at once.
            c.historyLatencyMs = 0; c.historyJitterMs = 0; c.localLatencyMs = 0
            c.localTailCount = .max; c.downloadMs = 0; c.downloadSlots = 64
        case "slow":
            // Watch on the phone's Bluetooth proxy, chat not opened for a while.
            c.historyLatencyMs = 1300; c.historyJitterMs = 500; c.coldPageSize = 5
            c.localTailCount = 30; c.downloadMs = 2500; c.downloadSlots = 2
        case "crown":
            c.scroll = .crown
        default:
            break   // "mixed", "real"
        }
        func int(_ key: String) -> Int? { env["TGWATCH_PERF_\(key)"].flatMap { Int($0) } }
        func double(_ key: String) -> Double? { env["TGWATCH_PERF_\(key)"].flatMap { Double($0) } }
        if let v = int("MESSAGES") { c.messageCount = v }
        if let v = double("MEDIA") { c.mediaShare = v }
        if let v = int("LATENCY") { c.historyLatencyMs = v }
        if let v = int("COLD") { c.coldPageSize = v }
        if let v = int("LOCAL") { c.localTailCount = v }
        if let v = int("DOWNLOAD") { c.downloadMs = v }
        if let v = int("SLOTS") { c.downloadSlots = v }
        if let v = int("DEPTH") { c.depth = v }
        if let v = double("SPEED") { c.flickSpeed = v; c.crownSpeed = v }
        if let v = env["TGWATCH_PERF_SCROLL"].flatMap(Scroll.init(rawValue:)) { c.scroll = v }
        if let v = env["TGWATCH_PERF_CHAT"].flatMap({ Int64($0) }) { c.chatId = v }
        if let v = env["TGWATCH_PERF_CHAT_TITLE"] { c.chatTitle = v }
        if env["TGWATCH_PERF_NO_PREFETCH"] == "1" { c.noMediaPrefetch = true }
        return c
    }
}

// MARK: - Recorder

/// Collects the measurements. Thread-safe: pages decode and downloads finish off the
/// main thread.
final class PerfBench: @unchecked Sendable {
    static let shared: PerfBench? = PerfBenchConfig.fromEnvironment().map(PerfBench.init)

    let config: PerfBenchConfig
    private let lock = NSLock()
    private let t0 = DispatchTime.now().uptimeNanoseconds

    init(config: PerfBenchConfig) {
        self.config = config
        startStallWatchdog()
    }

    /// Milliseconds since launch.
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 }

    // Per-phase accumulators: "open", "up", "down", "jump".
    private struct Phase: Codable {
        var startMs = 0.0
        var durationMs = 0.0
        var frames = 0
        /// Frames that came more than 1.5 refreshes late, and the time they were late by.
        var hitches = 0
        var hitchMs = 0.0
        var worstFrameMs = 0.0
        var stalls50 = 0
        var stalls100 = 0
        var worstStallMs = 0.0
        var renders: [String: Int] = [:]
        var reprojects = 0
        var reprojectMs = 0.0
        var worstReprojectMs = 0.0
        var topWaits = 0
        var topWaitMs = 0.0
        var scrolledPt = 0.0
    }

    struct Page: Codable {
        let kind: String
        let atMs: Double
        let fetchMs: Double
        let count: Int
        var applyWaitMs: Double = 0
        var applyMs: Double = 0
    }

    private var phases: [String: Phase] = [:]
    private var phaseOrder: [String] = []
    private(set) var phase = "idle"
    private var lastFrame: UInt64 = 0
    private(set) var pages: [Page] = []
    private var decodes: [Double] = []
    private var decodedMessages = 0
    private var drifts: [Double] = []
    private var downloadsRequested = 0
    private var downloadsCancelled = 0
    private var downloadsRestarted = 0
    private var downloadLatencies: [Double] = []
    private var mediaShownTotal = 0
    private var mediaShownReady = 0
    private var updates: [String: Int] = [:]
    private var updateDecodeMs = 0.0
    private var updateMainMs = 0.0
    private var notes: [String] = []

    var olderMessagesReceived: Int {
        lock.lock(); defer { lock.unlock() }
        return pages.filter { $0.kind == "older" }.reduce(0) { $0 + $1.count }
    }

    func setPhase(_ name: String) {
        lock.lock()
        let t = now()
        if var p = phases[phase] { p.durationMs = t - p.startMs; phases[phase] = p }
        phase = name
        if phases[name] == nil, name != "idle", name != "done" {
            phases[name] = Phase(startMs: t)
            phaseOrder.append(name)
        }
        lastFrame = 0
        lock.unlock()
        DebugTrace.log("perf phase \(name)")
    }

    private func mutatePhase(_ body: (inout Phase) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var p = phases[phase] else { return }
        body(&p)
        phases[phase] = p
    }

    /// One display frame, from `PerfFrameMeter`.
    func frameTick() {
        let t = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let last = lastFrame
        lastFrame = t
        lock.unlock()
        guard last != 0 else { return }
        let gap = Double(t - last) / 1_000_000
        mutatePhase { p in
            p.frames += 1
            p.worstFrameMs = max(p.worstFrameMs, gap)
            if gap > 25 {
                p.hitches += 1
                p.hitchMs += gap - 16.7
            }
        }
    }

    func render(_ name: String, by count: Int = 1) { mutatePhase { $0.renders[name, default: 0] += count } }

    func reproject(ms: Double, rows: Int) {
        mutatePhase { p in
            p.reprojects += 1
            p.reprojectMs += ms
            p.worstReprojectMs = max(p.worstReprojectMs, ms)
        }
    }

    func scrolled(_ pt: Double) { mutatePhase { $0.scrolledPt += abs(pt) } }

    func topWait(ms: Double) {
        mutatePhase { p in p.topWaits += 1; p.topWaitMs += ms }
        DebugTrace.log(String(format: "perf topWait %.0fms", ms))
    }

    /// A history page arrived (`fetchMs`: request to decoded messages). Returns its index
    /// for `pageApplied`.
    @discardableResult
    func pageFetched(_ kind: String, fetchMs: Double, count: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        pages.append(Page(kind: kind, atMs: now(), fetchMs: fetchMs, count: count))
        return pages.count - 1
    }

    func pageApplied(_ index: Int, waitMs: Double, applyMs: Double) {
        lock.lock(); defer { lock.unlock() }
        guard pages.indices.contains(index) else { return }
        pages[index].applyWaitMs = waitMs
        pages[index].applyMs = applyMs
    }

    func decoded(ms: Double, messages: Int) {
        lock.lock(); defer { lock.unlock() }
        decodes.append(ms)
        decodedMessages += messages
    }

    func drift(_ pt: Double) { lock.lock(); drifts.append(pt); lock.unlock() }

    func download(requested fileId: Int, restart: Bool) {
        lock.lock(); downloadsRequested += 1; if restart { downloadsRestarted += 1 }; lock.unlock()
    }
    func downloadCancelled() { lock.lock(); downloadsCancelled += 1; lock.unlock() }
    /// A media row came on screen with its file already downloaded, or not.
    func mediaShown(ready: Bool) { lock.lock(); mediaShownTotal += 1; if ready { mediaShownReady += 1 }; lock.unlock() }
    func downloadFinished(ms: Double) { lock.lock(); downloadLatencies.append(ms); lock.unlock() }

    /// A TDLib update (real mode): its type, the decode time off the main thread.
    func update(_ type: String, decodeMs: Double) {
        lock.lock(); updates[type, default: 0] += 1; updateDecodeMs += decodeMs; lock.unlock()
    }
    func updateHandled(mainMs: Double) { lock.lock(); updateMainMs += mainMs; lock.unlock() }

    /// The `@type` of a TDLib JSON object, read from its first bytes.
    static func jsonType(_ data: Data) -> String {
        let head = data.prefix(80)
        let text = String(decoding: head, as: UTF8.self)
        guard let range = text.range(of: #""@type":""#) else { return "?" }
        return String(text[range.upperBound...].prefix { $0 != "\"" })
    }

    func note(_ text: String) {
        lock.lock(); notes.append(String(format: "%.0f ", now()) + text); lock.unlock()
        DebugTrace.log("perf " + text)
    }

    // MARK: Main-thread stalls

    /// Pings the main thread every 10ms from a background queue; how late the ping runs
    /// is how long the main thread was busy.
    private func startStallWatchdog() {
        let queue = DispatchQueue(label: "perf-bench.watchdog", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        final class Flag { var pending = false }
        let flag = Flag()
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard !flag.pending else { return }
            flag.pending = true
            let sent = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let late = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                queue.async { flag.pending = false }
                guard late >= 50 else { return }
                if late >= 100 { self?.note(String(format: "main stall %.0fms", late)) }
                self?.mutatePhase { p in
                    p.stalls50 += 1
                    if late >= 100 { p.stalls100 += 1 }
                    p.worstStallMs = max(p.worstStallMs, late)
                }
            }
        }
        timer.resume()
        watchdog = timer
    }
    private var watchdog: DispatchSourceTimer?

    // MARK: Result

    private struct Result: Codable {
        let config: PerfBenchConfig
        let phases: [String: Phase]
        let phaseOrder: [String]
        let pages: [Page]
        let decodeMsAvg: Double
        let decodeMsMax: Double
        let decodedMessages: Int
        let driftsMaxAbs: Double
        let prepends: Int
        let downloadsRequested: Int
        let downloadsCancelled: Int
        let downloadsRestarted: Int
        let downloadMsAvg: Double
        let mediaShown: Int
        let mediaShownReady: Int
        let updates: [String: Int]
        let updateDecodeMs: Double
        let updateMainMs: Double
        let footprintMB: Double
        let notes: [String]
    }

    func finish() {
        setPhase("done")
        lock.lock()
        let result = Result(
            config: config,
            phases: phases,
            phaseOrder: phaseOrder,
            pages: pages,
            decodeMsAvg: decodes.isEmpty ? 0 : decodes.reduce(0, +) / Double(decodes.count),
            decodeMsMax: decodes.max() ?? 0,
            decodedMessages: decodedMessages,
            driftsMaxAbs: drifts.map(abs).max() ?? 0,
            prepends: drifts.count,
            downloadsRequested: downloadsRequested,
            downloadsCancelled: downloadsCancelled,
            downloadsRestarted: downloadsRestarted,
            downloadMsAvg: downloadLatencies.isEmpty ? 0 : downloadLatencies.reduce(0, +) / Double(downloadLatencies.count),
            mediaShown: mediaShownTotal,
            mediaShownReady: mediaShownReady,
            updates: updates,
            updateDecodeMs: updateDecodeMs,
            updateMainMs: updateMainMs,
            footprintMB: Self.footprintMB(),
            notes: notes
        )
        lock.unlock()
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result) {
            try? data.write(to: dir.appendingPathComponent("result.json"))
        }
        try? "done".write(to: dir.appendingPathComponent("done"), atomically: true, encoding: .utf8)
        DebugTrace.log("perf done")
    }

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("perf-bench", isDirectory: true)
    }

    /// Clears the previous run's result before a new one starts.
    static func resetOutput() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("result.json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("done"))
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// Ticks the recorder once per display frame. Invisible; put it over the screen measured.
struct PerfFrameMeter: View {
    var body: some View {
        TimelineView(.animation) { _ in
            let _ = PerfBench.shared?.frameTick()
            Color.clear.frame(width: 1, height: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Driver

/// What the bench needs from `MessageListView` to scroll it like a user would.
struct PerfBenchHooks {
    struct Viewport {
        let offset: CGFloat
        let contentHeight: CGFloat
        let containerHeight: CGFloat
        let topInset: CGFloat
        var atTop: Bool { offset + topInset <= 1 }
        var atBottom: Bool { offset >= contentHeight - containerHeight - topInset - 2 }
    }
    struct VisibleRow {
        let id: String
        let top: CGFloat
        let height: CGFloat
    }
    let viewport: () -> Viewport?
    /// The visible message row nearest the middle of the screen.
    let middleRow: () -> VisibleRow?
    /// The row's current frame top, if it's built.
    let rowTop: (String) -> CGFloat?
    /// Scrolls so the row's top lands at `top` (in the scroll view's visible area).
    let placeRow: (String, CGFloat, CGFloat) -> Void
    /// Marks the scroll view as moving because of the user (what the scroll phases say).
    let setUserScrolling: (Bool) -> Void
    let jumpToBottom: () -> Void
    /// An older page just went in and its position is being compensated.
    let prependInFlight: () -> Bool
}

extension PerfBench {
    /// Runs the scripted scroll on the opened chat, then writes the result.
    @MainActor
    func run(store: ChatHistoryStore, hooks: PerfBenchHooks) async {
        guard phase == "open" || phase == "idle" else { return }
        let driver = PerfBenchDriver(bench: self, store: store, hooks: hooks)
        await driver.run()
    }
}

@MainActor
private final class PerfBenchDriver {
    let bench: PerfBench
    let store: ChatHistoryStore
    let hooks: PerfBenchHooks
    /// Difference between where `placeRow` puts a row and where it was asked to; measured
    /// once, then subtracted.
    private var bias: CGFloat = 0

    init(bench: PerfBench, store: ChatHistoryStore, hooks: PerfBenchHooks) {
        self.bench = bench
        self.store = store
        self.hooks = hooks
    }

    private var config: PerfBenchConfig { bench.config }

    func run() async {
        bench.setPhase("settle")
        try? await Task.sleep(for: .milliseconds(1200))
        await calibrate()
        let start = bench.now()
        let deadline = start + config.timeLimit * 1000

        // Up through history.
        bench.setPhase("up")
        let startReceived = bench.olderMessagesReceived
        while bench.now() < deadline, bench.olderMessagesReceived - startReceived < config.depth {
            if let v = hooks.viewport(), v.atTop {
                if !store.window.hasOlder {
                    bench.note("history start reached")
                    break
                }
                await waitAtTop(deadline: deadline)
                continue
            }
            switch config.scroll {
            case .flicks:
                await flick(direction: 1)
                try? await Task.sleep(for: .milliseconds(250))
            case .crown:
                await glide(direction: 1, seconds: 1)
            }
        }
        // Wait for the last page in flight before leaving the phase.
        try? await Task.sleep(for: .milliseconds(500))

        // Back down a few screens: the newest rows were trimmed, so this pages newer.
        bench.setPhase("down")
        for _ in 0..<8 where bench.now() < deadline {
            if let v = hooks.viewport(), v.atBottom, store.window.reachesChatTail { break }
            switch config.scroll {
            case .flicks:
                await flick(direction: -1)
                try? await Task.sleep(for: .milliseconds(250))
            case .crown:
                await glide(direction: -1, seconds: 1)
            }
        }

        // The jump-to-bottom button.
        bench.setPhase("jump")
        let jumpStart = bench.now()
        hooks.jumpToBottom()
        var stable = 0
        while bench.now() - jumpStart < 8000 {
            try? await Task.sleep(for: .milliseconds(16))
            if let v = hooks.viewport(), v.atBottom, store.window.reachesChatTail {
                stable += 1
                if stable >= 10 { break }
            } else {
                stable = 0
            }
        }
        bench.note(String(format: "jumpToBottom settled in %.0fms", bench.now() - jumpStart - 160))
        try? await Task.sleep(for: .milliseconds(600))
        bench.finish()
    }

    /// Measures `bias`: asks for the middle row to stay where it is and sees where it goes.
    private func calibrate() async {
        for _ in 0..<2 {
            guard let row = hooks.middleRow() else { return }
            hooks.placeRow(row.id, row.top - bias, row.height)
            try? await Task.sleep(for: .milliseconds(50))
            guard let top = hooks.rowTop(row.id) else { return }
            bias += top - row.top
        }
        bench.note(String(format: "calibrated bias=%.1f", bias))
    }

    /// Moves the content by `dy` (positive: down, i.e. toward older messages). False at an edge.
    private var lastStuckNote = -10_000.0

    private func stuck(_ why: String) -> Bool {
        if bench.now() - lastStuckNote > 2000 {
            lastStuckNote = bench.now()
            bench.note("step stuck: " + why)
        }
        return false
    }

    private func step(_ dy: CGFloat) -> Bool {
        guard let v = hooks.viewport() else { return stuck("no viewport") }
        if dy > 0, v.atTop { return false }
        if dy < 0, v.atBottom { return false }
        guard let row = hooks.middleRow() else { return stuck("no visible row") }
        hooks.placeRow(row.id, row.top + dy - bias, row.height)
        bench.scrolled(Double(dy))
        return true
    }

    /// Doesn't touch the screen while a prepend is being compensated, so the drift it
    /// measures is the prepend's alone (a user grabbing the list cancels the compensation).
    private func waitForPrepend() async {
        let start = bench.now()
        while hooks.prependInFlight(), bench.now() - start < 1500 {
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// A flick: starts at `flickSpeed` and decays like UIScrollView's normal deceleration.
    private func flick(direction: CGFloat) async {
        await waitForPrepend()
        hooks.setUserScrolling(true)
        defer { hooks.setUserScrolling(false) }
        var speed = config.flickSpeed
        var last = bench.now()
        while speed > 40 {
            try? await Task.sleep(for: .milliseconds(16))
            let t = bench.now()
            let dt = (t - last) / 1000
            last = t
            speed *= pow(0.998, dt * 1000)
            if !step(direction * CGFloat(speed * dt)) { break }
        }
    }

    /// A steady scroll, like turning the crown.
    private func glide(direction: CGFloat, seconds: Double) async {
        await waitForPrepend()
        hooks.setUserScrolling(true)
        defer { hooks.setUserScrolling(false) }
        let end = bench.now() + seconds * 1000
        var last = bench.now()
        while bench.now() < end {
            try? await Task.sleep(for: .milliseconds(16))
            let t = bench.now()
            let dt = (t - last) / 1000
            last = t
            if !step(direction * CGFloat(config.crownSpeed * dt)) { break }
        }
    }

    /// Stuck at the top of the loaded content: waits for the next page to go in above.
    private func waitAtTop(deadline: Double) async {
        let start = bench.now()
        while bench.now() < deadline {
            try? await Task.sleep(for: .milliseconds(16))
            if let v = hooks.viewport(), !v.atTop { break }
            if !store.window.hasOlder { break }
        }
        bench.topWait(ms: bench.now() - start)
    }
}

// MARK: - Synthetic chat

/// Root view for the synthetic scenarios: a made-up chat in the real chat screen.
struct PerfBenchRootView: View {
    @State private var setup: PerfBenchSetup?

    var body: some View {
        NavigationStack {
            if let setup {
                MessageListView(row: setup.row, store: setup.store)
                    .environment(setup.client)
            } else {
                ProgressView()
            }
        }
        .task {
            guard setup == nil, let bench = PerfBench.shared else { return }
            PerfBench.resetOutput()
            bench.setPhase("open")
            setup = PerfBenchSetup(config: bench.config)
        }
    }
}

@MainActor
private final class PerfBenchSetup {
    let world: PerfBenchWorld
    let store: ChatHistoryStore
    let row: ChatRow
    let client: TDClient
    private let delegate = NoDelegate()

    init(config: PerfBenchConfig) {
        world = PerfBenchWorld(config: config, media: GalleryMedia.render())
        let names = UserNamesStore()
        names.debugSeed(PerfBenchWorld.senderNames)
        let chatType = ChatType.chatTypeBasicGroup(ChatTypeBasicGroup(basicGroupId: 1))
        store = ChatHistoryStore(
            chatId: world.chatId,
            chatType: chatType,
            lastReadInboxMessageId: world.tailId,
            lastReadOutboxMessageId: world.tailId,
            unreadCount: 0,
            lastMessageId: world.tailId,
            loader: PerfBenchLoader(world: world),
            selfUserId: PerfBenchWorld.selfUserId,
            userNames: names,
            coalesceUpdates: true
        )
        world.store = store
        row = ChatRow(
            id: world.chatId,
            title: "Perf \(config.scenario)",
            preview: "",
            unreadCount: 0,
            isMuted: false,
            order: 1,
            chatType: chatType,
            canSend: true,
            draftText: "",
            lastReadInboxMessageId: world.tailId,
            lastReadOutboxMessageId: world.tailId,
            lastMessageId: world.tailId,
            lastMessageDate: Int(Date().timeIntervalSince1970),
            avatar: AvatarVisual(kind: .normal, initials: "PB", colorIndex: 2, photoFileId: nil, photoLocalPath: nil, mini: nil)
        )
        // Never started: MessageListView only needs it for the active-history hook.
        client = TDClient(
            account: Account(id: UUID(), useTestDc: false, createdAt: .now, lastActiveAt: .now),
            manager: TgwatchApp.tdlibManager,
            delegate: delegate
        )
        Task { await store.warm() }
    }

    private final class NoDelegate: TDClientLifecycleDelegate {
        func tdClient(_ client: TDClient, didFetchMe me: User) {}
        func tdClient(_ client: TDClient, didDestroyItselfWithReason reason: TDClientDestroyReason) {}
    }
}

/// The made-up chat and its simulated TDLib: history pages with database / server
/// latency and cold-cache partial pages, and file downloads with limited slots.
final class PerfBenchWorld: @unchecked Sendable {
    static let selfUserId: Int64 = 1
    static let senderNames: [Int64: String] = [10: "Anna", 11: "Boris", 12: "Clara", 13: "Dmitri", 14: "Eve"]

    let config: PerfBenchConfig
    let chatId: Int64 = 777_000
    let idStep: Int64 = 1 << 20
    var tailId: Int64 { Int64(config.messageCount) * idStep }
    private let templates: [GalleryMedia.Picture]
    private let stickerPath: String?
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    @MainActor weak var store: ChatHistoryStore?

    private let lock = NSLock()
    /// Message indices TDLib has in its database (index 0 = oldest).
    private var localIndices: IndexSet
    private var completedFiles: [Int: String] = [:]
    /// Waiting downloads and their priorities.
    private var queued: [Int: Int] = [:]
    private var queueOrder = 0
    private var queuedAt: [Int: Int] = [:]
    private var running: [Int: Task<Void, Never>] = [:]
    private var requestedAt: [Int: Double] = [:]
    private var everRequested: Set<Int> = []

    init(config: PerfBenchConfig, media: GalleryMedia) {
        self.config = config
        templates = [media.landscape, media.portrait, media.square, media.tall]
        stickerPath = Bundle.main.path(forResource: "sticker_raster", ofType: "webp", inDirectory: "SampleStickers")
            ?? Bundle.main.path(forResource: "sticker_raster", ofType: "webp")
        let local = min(config.localTailCount, config.messageCount)
        localIndices = IndexSet(integersIn: (config.messageCount - local)..<config.messageCount)
        let files = PerfBench.directory.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.removeItem(at: files)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }

    // MARK: History

    func index(of id: Int64) -> Int { Int(id / idStep) - 1 }

    /// `getChatHistory` with TDLib's paging rules (as in the harness's SimTDLib): from 0 =
    /// from the newest; offset 0 = strictly older than `from`; offset -N = additionally N
    /// newer, `from` included. Returns the response JSON and how long TDLib would take.
    func history(from: Int64, offset: Int, limit: Int, onlyLocal: Bool) -> (Data, Int) {
        lock.lock()
        // Newest first, as TDLib returns.
        var start: Int   // in descending order: 0 = newest
        let count = config.messageCount
        if from == 0 {
            start = 0
        } else {
            let idx = index(of: from)                     // ascending index of `from`
            let descIdx = count - 1 - idx
            start = offset == 0 ? descIdx + 1 : descIdx + offset
        }
        start = max(0, min(start, count))
        let end = min(count, start + limit)
        var indices = (start..<end).map { count - 1 - $0 }   // ascending index, newest first
        var latency = config.localLatencyMs
        if onlyLocal {
            indices = Array(indices.prefix { localIndices.contains($0) })
        } else if !indices.allSatisfy({ localIndices.contains($0) }) {
            // TDLib goes to the server: one round trip, and on a cold cache only the
            // first few come back now; the server batch lands in the database for the next call.
            latency = config.historyLatencyMs + Int.random(in: 0...max(0, config.historyJitterMs))
            let fetched = indices.min().map { max(0, $0 - 100)...(indices.max() ?? $0) }
            if let fetched { localIndices.insert(integersIn: fetched) }
            if config.coldPageSize > 0 { indices = Array(indices.prefix(config.coldPageSize)) }
        }
        lock.unlock()
        let messages = indices.map { message(index: $0) }
        let encoded = messages.compactMap { try? encoder.encode($0) }
        var data = Data(#"{"@type":"messages","total_count":\#(count),"messages":["#.utf8)
        for (i, m) in encoded.enumerated() {
            if i > 0 { data.append(UInt8(ascii: ",")) }
            data.append(m)
        }
        data.append(contentsOf: Array("]}".utf8))
        return (data, latency)
    }

    /// Deterministic message `index` (0 = oldest).
    func message(index i: Int) -> Message {
        var rng = SplitMix(seed: UInt64(i) &* 0x9E37_79B9_7F4A_7C15)
        let id = Int64(i + 1) * idStep
        let isOutgoing = rng.unit() < 0.35
        let date = Int(Date().timeIntervalSince1970) - (config.messageCount - i) * 1500
        let sender: MessageSender = isOutgoing
            ? .messageSenderUser(MessageSenderUser(userId: Self.selfUserId))
            : .messageSenderUser(MessageSenderUser(userId: 10 + Int64(rng.next() % 5)))
        let kind = rng.unit()
        let media = config.mediaShare
        let content: MessageContent
        var replyTo: MessageReplyTo?
        if kind < media * 0.5 {
            content = .messagePhoto(photo(index: i, rng: &rng))
        } else if kind < media * 0.75 {
            content = .messageVoiceNote(MessageVoiceNote(
                caption: FormattedText(entities: [], text: ""),
                isListened: true,   // keeps automatic transcription out of the bench
                voiceNote: VoiceNote(
                    duration: 3 + Int(rng.next() % 50),
                    mimeType: "audio/ogg",
                    speechRecognitionResult: nil,
                    voice: Self.remoteFile(id: 4_000_000 + i * 8 + 3),
                    waveform: Data((0..<63).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
                )
            ))
        } else if kind < media {
            content = .messageSticker(MessageSticker(isPremium: false, sticker: Sticker(
                emoji: "🙂",
                format: .stickerFormatWebp,
                fullType: .stickerFullTypeRegular(StickerFullTypeRegular(premiumAnimation: nil)),
                height: 512,
                id: TdInt64(Int64(i)),
                setId: 1,
                sticker: Self.remoteFile(id: 4_000_000 + i * 8 + 2),
                thumbnail: nil,
                width: 512
            )))
        } else {
            let long = rng.unit() < 0.25
            content = .messageText(MessageText(
                linkPreview: nil,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: Self.text(long: long, rng: &rng))
            ))
            if i > 5, rng.unit() < 0.15 {
                replyTo = .messageReplyToMessage(MessageReplyToMessage(
                    chatId: chatId, checklistTaskId: 0, content: nil,
                    messageId: Int64(i - 1 - Int(rng.next() % 5) + 1) * idStep,
                    origin: nil, originSendDate: 0, pollOptionId: "", quote: nil
                ))
            }
        }
        var interaction: MessageInteractionInfo?
        if rng.unit() < 0.12 {
            let emojis = ["👍", "❤️", "🔥", "😁"]
            let n = 1 + Int(rng.next() % 3)
            interaction = MessageInteractionInfo(
                forwardCount: 0,
                reactions: MessageReactions(
                    areTags: false, canGetAddedReactions: true, paidReactors: [],
                    reactions: (0..<n).map { k in
                        MessageReaction(
                            isChosen: k == 0 && rng.unit() < 0.3,
                            recentSenderIds: [],
                            totalCount: 1 + Int(rng.next() % 9),
                            type: .reactionTypeEmoji(ReactionTypeEmoji(emoji: emojis[k])),
                            usedSenderId: nil
                        )
                    }
                ),
                replyInfo: nil,
                viewCount: 0
            )
        }
        return Message(
            authorSignature: "", autoDeleteIn: 0, canBeSaved: true, chatId: chatId,
            containsUnreadMention: false, containsUnreadPollVotes: false,
            content: content,
            date: date, editDate: 0, effectId: 0, factCheck: nil, forwardInfo: nil,
            guestBotCallerId: nil, hasTimestampedMedia: false, id: id, importInfo: nil,
            interactionInfo: interaction, isChannelPost: false, isFromOffline: false, isOutgoing: isOutgoing,
            isPaidStarSuggestedPost: false, isPaidTonSuggestedPost: false, isPinned: false,
            mediaAlbumId: 0, paidMessageStarCount: 0, replyMarkup: nil, replyTo: replyTo,
            restrictionInfo: nil, schedulingState: nil, selfDestructIn: 0, selfDestructType: nil,
            senderBoostCount: 0, senderBusinessBotUserId: 0,
            senderId: sender, senderTag: "",
            sendingState: nil, suggestedPostInfo: nil, summaryLanguageCode: "", topicId: nil,
            unreadReactions: [], viaBotUserId: 0
        )
    }

    private func photo(index i: Int, rng: inout SplitMix) -> MessagePhoto {
        let template = templates[i % templates.count]
        let medium = 320.0 / Double(max(template.width, template.height))
        let large = 1280.0 / Double(max(template.width, template.height))
        let caption = rng.unit() < 0.3 ? Self.text(long: false, rng: &rng) : ""
        return MessagePhoto(
            caption: FormattedText(entities: [], text: caption),
            hasSpoiler: false,
            isSecret: false,
            photo: Photo(
                hasStickers: false,
                minithumbnail: template.mini.map { Minithumbnail(data: $0, height: 40, width: 40) },
                sizes: [
                    PhotoSize(height: Int(Double(template.height) * medium), photo: Self.remoteFile(id: 4_000_000 + i * 8),
                              progressiveSizes: [], type: "m", width: Int(Double(template.width) * medium)),
                    PhotoSize(height: Int(Double(template.height) * large), photo: Self.remoteFile(id: 4_000_000 + i * 8 + 1),
                              progressiveSizes: [], type: "y", width: Int(Double(template.width) * large)),
                ]
            ),
            showCaptionAboveMedia: false,
            video: nil
        )
    }

    private static let words = ("lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor "
        + "incididunt ut labore et dolore magna aliqua привет как дела сегодня завтра встреча watch "
        + "telegram scroll page message").split(separator: " ").map(String.init)

    private static func text(long: Bool, rng: inout SplitMix) -> String {
        let count = long ? 25 + Int(rng.next() % 40) : 1 + Int(rng.next() % 10)
        return (0..<count).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ")
    }

    static func remoteFile(id: Int, localPath: String? = nil, progress: Int64 = 0) -> File {
        File(
            expectedSize: 40_000,
            id: id,
            local: LocalFile(
                canBeDeleted: true,
                canBeDownloaded: true,
                downloadOffset: 0,
                downloadedPrefixSize: localPath != nil ? 40_000 : progress,
                downloadedSize: localPath != nil ? 40_000 : progress,
                isDownloadingActive: localPath == nil && progress > 0,
                isDownloadingCompleted: localPath != nil,
                path: localPath ?? ""
            ),
            remote: RemoteFile(id: "remote-\(id)", isUploadingActive: false, isUploadingCompleted: true,
                               uniqueId: "unique-\(id)", uploadedSize: 40_000),
            size: 40_000
        )
    }

    // MARK: Downloads

    func download(fileId: Int, priority: Int) -> File {
        lock.lock()
        if let path = completedFiles[fileId] {
            lock.unlock()
            return Self.remoteFile(id: fileId, localPath: path)
        }
        if running[fileId] == nil {
            if let current = queued[fileId] {
                // A new request raises the priority, as in TDLib.
                queued[fileId] = max(current, priority)
            } else {
                let restart = everRequested.contains(fileId)
                everRequested.insert(fileId)
                queued[fileId] = priority
                queueOrder += 1
                queuedAt[fileId] = queueOrder
                requestedAt[fileId] = PerfBench.shared?.now() ?? 0
                PerfBench.shared?.download(requested: fileId, restart: restart)
            }
        }
        lock.unlock()
        pump()
        return Self.remoteFile(id: fileId)
    }

    func cancel(fileId: Int) {
        lock.lock()
        var cancelled = false
        if queued.removeValue(forKey: fileId) != nil { cancelled = true }
        if let task = running.removeValue(forKey: fileId) { task.cancel(); cancelled = true }
        lock.unlock()
        if cancelled { PerfBench.shared?.downloadCancelled() }
        pump()
    }

    /// Starts queued downloads while slots are free: highest priority first, newest
    /// first among equals.
    private func pump() {
        lock.lock()
        var starts: [Int] = []
        while running.count + starts.count < config.downloadSlots,
              let fileId = queued.max(by: { ($0.value, queuedAt[$0.key] ?? 0) < ($1.value, queuedAt[$1.key] ?? 0) })?.key {
            queued[fileId] = nil
            starts.append(fileId)
        }
        for fileId in starts {
            running[fileId] = Task.detached { [weak self] in await self?.runDownload(fileId: fileId) }
        }
        lock.unlock()
    }

    private func runDownload(fileId: Int) async {
        let total = config.downloadMs > 0 ? Double(config.downloadMs) * Double.random(in: 0.7...1.3) : 0
        if total > 0 {
            try? await Task.sleep(for: .milliseconds(Int(total / 2)))
            guard !Task.isCancelled else { return }
            // TDLib reports progress while downloading.
            await post(Self.remoteFile(id: fileId, progress: 20_000))
            try? await Task.sleep(for: .milliseconds(Int(total / 2)))
            guard !Task.isCancelled else { return }
        }
        let path = materialize(fileId: fileId)
        lock.lock()
        running[fileId] = nil
        completedFiles[fileId] = path
        let started = requestedAt[fileId] ?? 0
        lock.unlock()
        PerfBench.shared.map { $0.downloadFinished(ms: $0.now() - started) }
        await post(Self.remoteFile(id: fileId, localPath: path))
        pump()
    }

    /// Puts the "downloaded" file on disk under its own path, so each one decodes anew
    /// the way distinct real photos do.
    private func materialize(fileId: Int) -> String {
        let isSticker = fileId % 8 == 2
        let source = isSticker ? stickerPath : templates[(fileId - 4_000_000) / 8 % templates.count].path
        let url = PerfBench.directory.appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent("\(fileId).\(isSticker ? "webp" : "jpg")")
        if let source, !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.copyItem(atPath: source, toPath: url.path)
        }
        return url.path
    }

    @MainActor
    private func post(_ file: File) {
        store?.handle(.updateFile(UpdateFile(file: file)))
    }
}

/// `ChatHistoryLoader` over `PerfBenchWorld`. Pages go through `decodeHistoryPage`, the
/// production decode.
struct PerfBenchLoader: ChatHistoryLoader {
    let world: PerfBenchWorld

    func openChat(chatId: Int64) async throws {}
    func closeChat(chatId: Int64) async throws {}

    func loadHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message] {
        try await page(fromMessageId, offset, limit, onlyLocal: false)
    }

    func loadLocalHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message] {
        try await page(fromMessageId, offset, limit, onlyLocal: true)
    }

    private func page(_ from: Int64, _ offset: Int, _ limit: Int, onlyLocal: Bool) async throws -> [Message] {
        let (data, latencyMs) = world.history(from: from, offset: offset, limit: limit, onlyLocal: onlyLocal)
        if latencyMs > 0 { try await Task.sleep(for: .milliseconds(latencyMs)) }
        return try decodeHistoryPage(data, decoder: world.decoder, chatId: world.chatId)
    }

    func downloadFile(fileId: Int, priority: Int) async throws -> File { world.download(fileId: fileId, priority: priority) }
    func cancelDownloadFile(fileId: Int) async throws { world.cancel(fileId: fileId) }
    func sendText(chatId: Int64, text: String) async throws -> Message { throw LoaderUnsupported() }
    func sendVoiceNote(chatId: Int64, fileURL: URL, duration: Int, waveform: Data) async throws -> Message { throw LoaderUnsupported() }
    func setChatDraftMessage(chatId: Int64, draftText: String) async throws {}
    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool) async throws {}
    func setPollAnswer(chatId: Int64, messageId: Int64, optionIds: [Int]) async throws {}
    func sendSticker(chatId: Int64, remoteFileId: String, emoji: String, width: Int, height: Int) async throws -> Message { throw LoaderUnsupported() }
    func sendLocation(chatId: Int64, latitude: Double, longitude: Double) async throws -> Message { throw LoaderUnsupported() }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
#endif
