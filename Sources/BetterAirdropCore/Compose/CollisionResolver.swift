import Foundation

/// Picks `stem.ext`, then `stem-2.ext`, `stem-3.ext`… until the name is free on disk and not
/// reserved by an earlier file in the same batch. Comparison is case-insensitive (APFS default).
public enum CollisionResolver {
    public static func resolve(directory: URL, stem: String, ext: String, reserved: Set<String> = [], ignoring: URL? = nil) -> URL {
        var n = 1
        while true {
            let name = n == 1 ? "\(stem).\(ext)" : "\(stem)-\(n).\(ext)"
            let url = directory.appendingPathComponent(name)
            if let ignoring, url.path.lowercased() == ignoring.path.lowercased() { return ignoring }
            if !reserved.contains(url.path.lowercased()) && !exists(url) { return url }
            n += 1
        }
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }
}
