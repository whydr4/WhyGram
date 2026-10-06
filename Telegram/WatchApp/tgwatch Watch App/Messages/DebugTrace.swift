import Foundation

/// Fork-only on-device trace for UI behaviour that can't be reproduced off the watch
/// (no watchOS simulator here). Appends timestamped lines to
/// `Library/Caches/whygram-trace.log` in the app container, which a development
/// install can pull with
/// `devicectl device copy from --domain-type appDataContainer
///  --domain-identifier <bundle id> --source Library/Caches/whygram-trace.log`.
/// The file is truncated when it passes `maxBytes`.
///
/// Callable from any thread. Lines are buffered and written on a background queue a
/// few times a second: the simulator's jump probe logs every scroll frame, and opening
/// and writing the file for each line on the main thread cost frames.
enum DebugTrace {
    #if DEBUG
    private static let maxBytes = 4 * 1024 * 1024   // the simulator's jump probe logs every frame
    #else
    private static let maxBytes = 256 * 1024
    #endif
    private static let url: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("whygram-trace.log")
    private static let start = Date()
    private static let queue = DispatchQueue(label: "whygram.debug-trace", qos: .utility)
    /// Touched only on `queue`.
    nonisolated(unsafe) private static var pending = Data()
    nonisolated(unsafe) private static var flushScheduled = false

    static func log(_ message: @autoclosure () -> String) {
        guard url != nil else { return }
        let line = String(format: "%8.3f ", Date().timeIntervalSince(start)) + message() + "\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            pending.append(data)
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + 0.25) { flush() }
        }
    }

    /// Writes what's buffered now (e.g. before the app is suspended).
    static func flushNow() {
        queue.sync { flush() }
    }

    private static func flush() {
        flushScheduled = false
        guard let url, !pending.isEmpty else { return }
        let data = pending
        pending = Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size > maxBytes {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

#if DEBUG
/// Simulator-only render counters: how often the list and its rows re-evaluate their
/// bodies. Logged once a second while anything is counted.
@MainActor
enum RenderCounter {
    private static var counts: [String: Int] = [:]
    private static var flushScheduled = false

    /// Adds `by` to the counter, or keeps the largest value seen with `max`.
    static func bump(_ name: String, by: Int = 1, max: Bool = false) {
        if max {
            counts[name] = Swift.max(counts[name] ?? 0, by)
        } else {
            counts[name, default: 0] += by
            PerfBench.shared?.render(name, by: by)
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let line = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            DebugTrace.log("renders/s " + line)
            counts = [:]
            flushScheduled = false
        }
    }
}
#endif
