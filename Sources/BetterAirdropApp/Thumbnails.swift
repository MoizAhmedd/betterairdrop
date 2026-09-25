import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Small thumbnails via ImageIO (fast for HEIC/JPEG/PNG), cached by path and modification date.
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func key(_ path: String, _ px: Int) -> NSString {
        let m = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(m)|\(px)" as NSString
    }

    static func cgImage(_ path: String, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func image(_ path: String, maxPixels: Int = 96) -> NSImage? {
        let k = key(path, maxPixels)
        if let c = cache.object(forKey: k) { return c }
        guard let cg = cgImage(path, maxPixels: maxPixels) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: k)
        return img
    }

    /// A 256 px JPEG copy for a notification attachment (the system moves the file it's given).
    static func notificationCopy(of path: String) -> URL? {
        guard let cg = cgImage(path, maxPixels: 256) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("betterairdrop-thumb-\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}

/// A rounded thumbnail that loads off the main thread.
struct ThumbnailView: View {
    let path: String
    var size: CGFloat = 36
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary).font(.system(size: size * 0.4))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
        .task(id: path) {
            let p = path, px = Int(size * 3)
            let box = await withCheckedContinuation { (c: CheckedContinuation<ImageBox, Never>) in
                DispatchQueue.global(qos: .utility).async { c.resume(returning: ImageBox(Thumbnails.image(p, maxPixels: px))) }
            }
            image = box.image
        }
    }
}

final class ImageBox: @unchecked Sendable {
    let image: NSImage?
    init(_ i: NSImage?) { image = i }
}
