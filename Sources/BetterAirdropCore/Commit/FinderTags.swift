import Foundation

/// Finder tags (Pro): the kind ("Receipt", "Screenshot"…) and, for photos, the city, so Spotlight
/// and Finder's sidebar find a photo by what it is even when its name is short. Written with the
/// documented `URLResourceKey.tagNamesKey` (an xattr; the file's bytes don't change, so undo's
/// checksum still matches). The journal records which tags were added, and undo removes only
/// those, keeping any the user added.
///
/// There's no Spotlight description here on purpose: the Finder comment (`kMDItemFinderComment`)
/// can only be set through Finder's AppleScript dictionary (an Automation permission prompt), and
/// `kMDItemDescription` only comes from the image's own metadata, which would rewrite the file.
public enum FinderTags {
    public static func read(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// Adds the tags the file doesn't already have. Returns the ones it added.
    @discardableResult
    public static func add(_ tags: [String], to url: URL) throws -> [String] {
        let existing = read(url)
        let new = tags.filter { t in !existing.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        guard !new.isEmpty else { return [] }
        try (url as NSURL).setResourceValue(existing + new, forKey: .tagNamesKey)
        return new
    }

    /// Removes exactly these tags (and nothing the user added).
    public static func remove(_ tags: [String], from url: URL) {
        let existing = read(url)
        let kept = existing.filter { !tags.contains($0) }
        guard kept.count != existing.count else { return }
        try? (url as NSURL).setResourceValue(kept, forKey: .tagNamesKey)
    }

    /// The tags for a renamed file: its kind, plus the city for a photo.
    public static func tags(for p: Proposal) -> [String] {
        guard let kind = p.suggestion?.kind ?? p.context?.kind else { return [] }
        var out = [kind == .other ? "Document" : kind.rawValue.capitalized]
        if kind == .photo, let city = p.context?.place?.city, !city.isEmpty { out.append(city) }
        return out
    }
}
