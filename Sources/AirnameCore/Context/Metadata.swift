import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What ImageIO (and the file's xattrs) say about a photo. Never touches pixels.
public struct PhotoMetadata: Codable, Sendable, Equatable {
    public var pixelWidth = 0
    public var pixelHeight = 0
    public var uti: String?
    /// Capture date as shot, in the camera's local time: `YYYY-MM-DD`.
    public var date: String?
    /// `HHMM`, local to the capture.
    public var time: String?
    /// `+01:00` from OffsetTimeOriginal, if present.
    public var offset: String?
    /// `exif` or `file` (creation date of the file, in this Mac's time zone).
    public var dateSource: String?
    public var latitude: Double?
    public var longitude: Double?
    public var make: String?
    public var model: String?
    public var orientation: Int?
    public var userComment: String?
    /// `com.apple.assetsd.creatorBundleID` carried over from the iPhone (e.g. com.apple.springboard for screenshots).
    public var creatorBundleID: String?

    public var hasGPS: Bool { latitude != nil && longitude != nil }
    public var isScreenshotByMetadata: Bool {
        userComment?.trimmingCharacters(in: .whitespaces) == "Screenshot" || creatorBundleID == "com.apple.springboard"
    }

    public init() {}

    public enum Error: Swift.Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String { switch self { case .unreadable(let p): "not a readable image: \(p)" } }
    }

    public static func read(_ url: URL) throws -> PhotoMetadata {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { throw Error.unreadable(url.path) }

        var m = PhotoMetadata()
        m.uti = CGImageSourceGetType(src) as String?
        m.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        m.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        m.orientation = props[kCGImagePropertyOrientation] as? Int

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        m.make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        m.model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        m.userComment = exif[kCGImagePropertyExifUserComment] as? String
        m.offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String

        let exifDate = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        if let (d, t) = exifDate.flatMap(parseExifDate) {
            m.date = d; m.time = t; m.dateSource = "exif"
        } else if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HHmm"
            let parts = f.string(from: created).split(separator: " ")
            m.date = String(parts[0]); m.time = String(parts[1]); m.dateSource = "file"
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           !(lat == 0 && lon == 0) {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            m.latitude = latRef.uppercased() == "S" ? -abs(lat) : abs(lat)
            m.longitude = lonRef.uppercased() == "W" ? -abs(lon) : abs(lon)
        }
        m.creatorBundleID = Xattr.getString(url, "com.apple.assetsd.creatorBundleID")
        return m
    }

    /// `2026:09:21 14:03:10` → (`2026-09-21`, `1403`). Rejects the all-zero placeholder.
    static func parseExifDate(_ s: String) -> (String, String)? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard let d = parts.first else { return nil }
        let ymd = d.split(separator: ":")
        guard ymd.count == 3, let y = Int(ymd[0]), let mo = Int(ymd[1]), let da = Int(ymd[2]),
              y > 1900, (1...12).contains(mo), (1...31).contains(da) else { return nil }
        let date = String(format: "%04d-%02d-%02d", y, mo, da)
        var time = ""
        if parts.count > 1 {
            let hms = parts[1].split(separator: ":")
            if hms.count >= 2, let h = Int(hms[0]), let mi = Int(hms[1]) { time = String(format: "%02d%02d", h, mi) }
        }
        return (date, time)
    }

    /// `iPhone 15 Pro` → `iphone-15-pro`.
    public var deviceSlug: String? {
        guard let model, !model.isEmpty else { return nil }
        return Slug.make(model, trimStopWords: false)
    }
}
