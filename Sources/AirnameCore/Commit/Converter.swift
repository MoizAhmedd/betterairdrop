import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// HEIC → JPEG through ImageIO. `CGImageDestinationAddImageFromSource` carries EXIF, TIFF, GPS,
/// IPTC, orientation and the ICC profile across in one call. HDR gain maps and depth data are not
/// carried (documented limitation).
public enum Converter {
    public enum Error: Swift.Error, CustomStringConvertible {
        case unreadable(String), encodeFailed(String)
        public var description: String {
            switch self {
            case .unreadable(let p): "can't read image \(p)"
            case .encodeFailed(let p): "JPEG encoding failed for \(p)"
            }
        }
    }

    public static func toJPEG(source: URL, destination: URL, quality: Double, stripGPS: Bool = false) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(src) == .statusComplete, CGImageSourceGetCount(src) > 0
        else { throw Error.unreadable(source.path) }
        // ImageIO reports statusComplete even for a truncated HEIC, so check the container too.
        guard ImageIntegrity.isComplete(source), CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
        else { throw Error.unreadable(source.path) }
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Error.encodeFailed(destination.path) }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if stripGPS { props[kCGImagePropertyGPSDictionary] = kCFNull }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: destination)
            throw Error.encodeFailed(source.path)
        }
    }
}

enum FileOps {
    /// SHA-1 of a file's contents, streamed.
    static func sha1(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fsync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        // F_FULLFSYNC asks the drive to flush too; fall back to fsync where unsupported.
        if fcntl(fd, F_FULLFSYNC) != 0 && Darwin.fsync(fd) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Renames without ever replacing an existing file (`RENAME_EXCL`), so a race can't overwrite.
    static func renameExclusive(_ from: URL, _ to: URL) throws {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func copyDates(from src: URL, to dst: URL) {
        guard let v = try? src.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) else { return }
        var attrs: [FileAttributeKey: Any] = [:]
        if let c = v.creationDate { attrs[.creationDate] = c }
        if let m = v.contentModificationDate { attrs[.modificationDate] = m }
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: dst.path)
    }
}
