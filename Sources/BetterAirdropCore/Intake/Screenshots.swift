import Foundation

/// Screenshots this Mac took (⇧⌘3/4/5). macOS marks each one with the
/// `com.apple.metadata:kMDItemIsScreenCapture` xattr (a binary plist `true`), which is where
/// Spotlight's `kMDItemIsScreenCapture = 1` comes from. Reading the xattr is one syscall and works
/// even with Spotlight indexing off.
public enum ScreenCapture {
    public static let xattrName = "com.apple.metadata:kMDItemIsScreenCapture"

    public static func isScreenCapture(_ url: URL) -> Bool {
        Xattr.get(url, xattrName).map(decode) ?? false
    }

    static func decode(_ data: Data) -> Bool {
        guard let v = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        if let b = v as? Bool { return b }
        return (v as? NSNumber)?.boolValue ?? false
    }
}

/// Where screenshots are saved: `defaults read com.apple.screencapture location`, else ~/Desktop.
public enum ScreenshotFolder {
    /// - Parameters:
    ///   - location: the `location` preference as stored (may start with `~`, may be missing).
    ///   - isDirectory: whether a folder exists there (a stale setting falls back to the Desktop,
    ///     which is what macOS itself does).
    public static func resolve(location: String?, home: URL, isDirectory: (URL) -> Bool) -> URL {
        let desktop = home.appendingPathComponent("Desktop").standardizedFileURL
        guard var path = location?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return desktop }
        if path == "~" { path = home.path } else if path.hasPrefix("~/") { path = home.path + path.dropFirst(1) }
        guard path.hasPrefix("/") else { return desktop }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return isDirectory(url) ? url : desktop
    }

    /// `BETTERAIRDROP_SCREENSHOT_DIR` stands in for the preference (snapshots and tests, so they
    /// never watch the real screenshot folder).
    public static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let location = environment["BETTERAIRDROP_SCREENSHOT_DIR"]
            ?? UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return resolve(location: location, home: home) { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
