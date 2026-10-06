import SwiftUI
import TDShim

@main
struct TgwatchApp: App {
    @State private var manager: AccountManager
    /// True when running inside an XCTest process. Computed once and stored so
    /// both `init()` and `body` can reference the same value without repeating
    /// the `NSClassFromString` lookup.
    private let isUnderXCTest: Bool = NSClassFromString("XCTestCase") != nil

    @MainActor
    init() {
        TgwatchApp.wipeMessageDatabaseIfRequested()
        // Under XCTest the app's `@main` `init()` still runs inside the test
        // process. Instantiating a `TDLibClientManager` here would conflict
        // with the one tests create via `SharedTestTDLibManager` (TDLib's
        // `td_receive` is single-thread-global — see CLAUDE.md gotcha). Hand
        // the test process a no-bootstrap manager; tests never drive the
        // SwiftUI scene, so its `factory` is never invoked.
        let factory: any TDClientFactory
        if isUnderXCTest {
            factory = NoopTDClientFactory()
        } else {
            factory = LiveTDClientFactory(manager: TgwatchApp.tdlibManager)
        }
        let mgr = AccountManager(
            registry: .defaultProduction(),
            factory: factory
        )
        #if DEBUG
        // The synthetic perf bench runs without an account (no TDLib traffic).
        let runsAccount = !isUnderXCTest && (PerfBench.shared?.config.isReal ?? true)
        #else
        let runsAccount = !isUnderXCTest
        #endif
        if runsAccount {
            mgr.bootstrap()
        }
        _manager = State(initialValue: mgr)
    }

    /// The process's only TDLib client manager: it runs `td_receive` in a loop, which
    /// TDLib allows on one thread only (a second manager aborts the app).
    static let tdlibManager = TDLibClientManager()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let bench = PerfBench.shared, !bench.config.isReal {
                // Perf bench on a made-up chat (perf-sim.sh); `real` runs in the app.
                PerfBenchRootView()
                    .environment(manager)   // LoadingView's account switcher reads it
            } else if let section = ProcessInfo.processInfo.environment["TGWATCH_UI_GALLERY"] {
                // Opens straight into Settings ▸ UI Gallery, at the section named by
                // the variable (`1` = from the top), for screenshot passes.
                NavigationStack { UIGalleryView(startSection: section) }
            } else {
                mainScene
            }
            #else
            mainScene
            #endif
        }
    }

    @ViewBuilder
    private var mainScene: some View {
        if let client = manager.activeClient {
            ContentView()
                .environment(client)
                .environment(manager)
                .id(manager.activeAccountId)
        } else if !isUnderXCTest {
            // Under XCTest the scene is not test-driven; suppress
            // AccountBootstrapView so its .task doesn't call
            // ensureAccountExists() → factory.make() via NoopTDClientFactory.
            AccountBootstrapView()
                .environment(manager)
        }
    }

    /// DEBUG-only: deletes TDLib's sqlite message-database files (keeping
    /// `td.binlog`, which holds auth keys) for every existing account dir
    /// when `TGWATCH_WIPE_MESSAGE_DB=1`. Each launch then re-fetches chat
    /// history from the server cold.
    private static func wipeMessageDatabaseIfRequested() {
#if DEBUG
        guard ProcessInfo.processInfo.environment["TGWATCH_WIPE_MESSAGE_DB"] == "1" else { return }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("tdlib", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            for name in ["db.sqlite", "db.sqlite-shm", "db.sqlite-wal"] {
                try? fm.removeItem(at: entry.appendingPathComponent(name))
            }
        }
#endif
    }
}
