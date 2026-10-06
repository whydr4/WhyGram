import Foundation

/// The top-level `@type`, `@extra` and `@client_id` of a TDLib JSON object, read
/// without parsing the rest of it.
///
/// Every response and update used to go through `JSONSerialization` just to route it,
/// which built the whole object tree (for a history page, every message in it), and
/// the receiver then parsed the same bytes again. This walks the bytes once, tracking
/// only string boundaries and nesting depth.
public struct TDJSONEnvelope: Equatable {
    public var type: String?
    public var extra: String?
    public var clientId: Int32?

    public init(type: String? = nil, extra: String? = nil, clientId: Int32? = nil) {
        self.type = type
        self.extra = extra
        self.clientId = clientId
    }

    public static func scan(_ data: Data) -> TDJSONEnvelope {
        data.withUnsafeBytes { raw -> TDJSONEnvelope in
            scan(raw.bindMemory(to: UInt8.self), typeOnly: false)
        }
    }

    /// Just the top-level `@type` (TDLib writes it first, so this reads a few bytes).
    public static func type(of data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            scan(raw.bindMemory(to: UInt8.self), typeOnly: true).type
        }
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")

    private static func scan(_ b: UnsafeBufferPointer<UInt8>, typeOnly: Bool) -> TDJSONEnvelope {
        var result = TDJSONEnvelope()
        let n = b.count
        var i = 0
        var depth = 0
        var expectKey = false
        var found = 0
        while i < n {
            let c = b[i]
            switch c {
            case quote:
                let start = i + 1
                let end = stringEnd(b, from: start)
                if depth == 1 && expectKey {
                    expectKey = false
                    var j = skipSpace(b, from: end + 1)
                    guard j < n, b[j] == UInt8(ascii: ":") else { i = end + 1; continue }
                    j = skipSpace(b, from: j + 1)
                    switch key(b, start, end) {
                    case .type:
                        if j < n, b[j] == quote {
                            result.type = string(b, j + 1, stringEnd(b, from: j + 1))
                            found += 1
                        }
                    case .extra:
                        if j < n, b[j] == quote {
                            result.extra = string(b, j + 1, stringEnd(b, from: j + 1))
                        } else {
                            // TDLib echoes `@extra` as sent; a number stays a number.
                            result.extra = string(b, j, numberEnd(b, from: j))
                        }
                        found += 1
                    case .clientId:
                        result.clientId = Int32(string(b, j, numberEnd(b, from: j)))
                        found += 1
                    case .other:
                        break
                    }
                    if found == 3 || (typeOnly && result.type != nil) { return result }
                    i = j
                    continue
                }
                i = end + 1
            case UInt8(ascii: "{"):
                depth += 1
                if depth == 1 { expectKey = true }
                i += 1
            case UInt8(ascii: "["):
                depth += 1
                i += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                i += 1
            case UInt8(ascii: ","):
                if depth == 1 { expectKey = true }
                i += 1
            default:
                i += 1
            }
        }
        return result
    }

    private enum Key { case type, extra, clientId, other }

    private static func key(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Key {
        let length = end - start
        guard length >= 5, b[start] == UInt8(ascii: "@") else { return .other }
        func equals(_ literal: StaticString) -> Bool {
            guard literal.utf8CodeUnitCount == length else { return false }
            let p = literal.utf8Start
            for k in 0..<length where b[start + k] != p[k] { return false }
            return true
        }
        if equals("@type") { return .type }
        if equals("@extra") { return .extra }
        if equals("@client_id") { return .clientId }
        return .other
    }

    /// Index of the closing quote of the string whose first character is at `from`.
    private static func stringEnd(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> Int {
        var j = from
        while j < b.count {
            if b[j] == backslash { j += 2; continue }
            if b[j] == quote { return j }
            j += 1
        }
        return b.count
    }

    private static func numberEnd(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> Int {
        var j = from
        while j < b.count {
            let c = b[j]
            if (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "-") { j += 1 } else { break }
        }
        return j
    }

    private static func skipSpace(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> Int {
        var j = from
        while j < b.count, b[j] == 0x20 || b[j] == 0x0A || b[j] == 0x0D || b[j] == 0x09 { j += 1 }
        return j
    }

    private static func string(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> String {
        guard start < end, end <= b.count else { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: b[start..<end]), as: UTF8.self)
    }
}
