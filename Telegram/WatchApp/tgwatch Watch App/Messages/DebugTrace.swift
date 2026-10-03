import Foundation

/// Fork-only on-device trace for UI behaviour that can't be reproduced off the watch
/// (no watchOS simulator here). Appends timestamped lines to
/// `Library/Caches/whygram-trace.log` in the app container, which a development
/// install can pull with
/// `devicectl device copy from --domain-type appDataContainer
///  --domain-identifier <bundle id> --source Library/Caches/whygram-trace.log`.
/// The file is truncated when it passes `maxBytes`.
@MainActor
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

    static func log(_ message: @autoclosure () -> String) {
        guard let url else { return }
        let line = String(format: "%8.3f ", Date().timeIntervalSince(start)) + message() + "\n"
        guard let data = line.data(using: .utf8) else { return }
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
