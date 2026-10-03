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
    private static let maxBytes = 256 * 1024
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
