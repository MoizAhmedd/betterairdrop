import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The copy of a photo that a cloud backend is allowed to see: a downscaled JPEG re-encoded from
/// pixels only. No EXIF, GPS, TIFF (make/model), maker notes or xattrs are carried over; the
/// useful context is sent as text instead (see `ClaudePrompt`).
public enum UploadImage {
    public enum Error: Swift.Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String { switch self { case .unreadable(let p): "can't decode \(p) for upload" } }
    }

    public static func jpeg(from url: URL, maxPixelSize: Int = 768, quality: Double = 0.8) throws -> Data {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Error.unreadable(url.lastPathComponent)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake the EXIF orientation into the pixels
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let pixels = redraw(thumb) else { throw Error.unreadable(url.lastPathComponent) }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Error.unreadable(url.lastPathComponent)
        }
        // Only the compression setting: no metadata dictionaries at all.
        CGImageDestinationAddImage(dest, pixels, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Error.unreadable(url.lastPathComponent) }
        return out as Data
    }

    /// Draws into a fresh 8-bit sRGB context, which drops HDR/wide-gamut quirks and anything
    /// attached to the decoded image, and flattens alpha onto white (screenshots, PNGs).
    static func redraw(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
