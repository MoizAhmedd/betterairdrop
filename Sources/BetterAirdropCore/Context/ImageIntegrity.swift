import Foundation

/// Structural "is this file complete?" checks. ImageIO happily decodes a truncated HEIC
/// (it reports statusComplete and fills the missing pixels), so we check the container instead.
public enum ImageIntegrity {
    public static func isComplete(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size >= 12 else { return false }
        func read(_ offset: UInt64, _ n: Int) -> [UInt8]? {
            guard (try? h.seek(toOffset: offset)) != nil, let d = try? h.read(upToCount: n), d.count == n else { return nil }
            return [UInt8](d)
        }
        guard let head = read(0, 12) else { return false }
        if head[4...7] == [0x66, 0x74, 0x79, 0x70] {         // "ftyp": ISO-BMFF (HEIC/HEIF/AVIF)
            return bmffBoxesReachEOF(size: size, read: read)
        }
        if head[0] == 0xFF && head[1] == 0xD8 {               // JPEG: must end with EOI (ignoring zero padding)
            let n = Int(min(size, 64))
            guard let tail = read(size - UInt64(n), n) else { return false }
            let trimmed = Array(tail.reversed().drop { $0 == 0 }.reversed())
            return trimmed.count >= 2 && trimmed.suffix(2) == [0xFF, 0xD9]
        }
        if head[0...3] == [0x89, 0x50, 0x4E, 0x47] {          // PNG: must end with the IEND chunk
            guard let tail = read(size - 8, 4) else { return false }
            return tail == Array("IEND".utf8)
        }
        return true   // other formats (DNG/TIFF): no cheap check; ImageIO decides
    }

    static func bmffBoxesReachEOF(size: UInt64, read: (UInt64, Int) -> [UInt8]?) -> Bool {
        var offset: UInt64 = 0
        var boxes = 0
        while offset < size {
            guard let hdr = read(offset, 8) else { return false }
            var boxSize = UInt64(hdr[0]) << 24 | UInt64(hdr[1]) << 16 | UInt64(hdr[2]) << 8 | UInt64(hdr[3])
            if boxSize == 1 {
                guard let large = read(offset + 8, 8) else { return false }
                boxSize = large.reduce(0) { $0 << 8 | UInt64($1) }
            } else if boxSize == 0 {
                return boxes > 0   // "extends to end of file"
            }
            guard boxSize >= 8, offset + boxSize <= size else { return false }
            offset += boxSize
            boxes += 1
        }
        return offset == size && boxes >= 2
    }
}
