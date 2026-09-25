import Darwin
import Foundation

/// Thin wrappers over getxattr/setxattr/removexattr. Never follows symlinks.
public enum Xattr {
    public static func get(_ url: URL, _ name: String) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard n >= 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: n)
            let r = getxattr(path, name, &buf, n, 0, XATTR_NOFOLLOW)
            return r >= 0 ? Data(buf.prefix(r)) : nil
        }
    }

    public static func getString(_ url: URL, _ name: String) -> String? {
        guard let d = get(url, name) else { return nil }
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        return s.isEmpty ? nil : s
    }

    public static func set(_ url: URL, _ name: String, _ data: Data) throws {
        let r = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        }
        if r != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public static func remove(_ url: URL, _ name: String) {
        _ = url.withUnsafeFileSystemRepresentation { path in
            path.map { removexattr($0, name, XATTR_NOFOLLOW) }
        }
    }

    public static func names(_ url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let n = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard n > 0 else { return [] }
            var buf = [CChar](repeating: 0, count: n)
            _ = listxattr(path, &buf, n, XATTR_NOFOLLOW)
            return buf.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
    }
}

/// `com.apple.quarantine` = `flags;hex-time;agent;uuid`. AirDrop's agent is `sharingd`.
public struct Quarantine: Sendable, Equatable {
    public var flags: String
    public var timestamp: Date?
    public var agent: String
    public var uuid: String?

    public var isAirDrop: Bool { agent == "sharingd" }

    public init?(_ raw: String) {
        let f = raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3, !f[0].isEmpty else { return nil }
        flags = f[0]
        timestamp = UInt64(f[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        agent = f[2]
        uuid = f.count > 3 && !f[3].isEmpty ? f[3] : nil
    }

    public static func of(_ url: URL) -> Quarantine? {
        Xattr.getString(url, "com.apple.quarantine").flatMap(Quarantine.init)
    }
}
