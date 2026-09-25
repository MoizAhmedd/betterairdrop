import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Synthetic test images with fabricated EXIF/GPS. No real photos are ever used in tests.
enum TestImages {
    struct Meta {
        var dateTimeOriginal: String? = "2026:09:21 14:03:10"
        var offset: String? = "-04:00"
        var gps: (lat: Double, lon: Double)? = (43.6532, -79.3832)   // Toronto City Hall
        var make: String? = "Apple"
        var model: String? = "iPhone 15 Pro"
        var orientation: Int = 1
        var userComment: String?
    }

    /// A temp directory that's removed when the returned object is released.
    final class TempDir {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("betterairdrop-tests-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func path(_ name: String) -> URL { url.appendingPathComponent(name) }
    }

    /// Draws a small gradient with a few shapes so encoders have something real to compress.
    static func cgImage(width: Int = 96, height: Int = 64, seed: Int = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<width {
            ctx.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat((x + seed * 37) % width) / CGFloat(width), blue: 0.4, alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 10 + seed % 20, y: 10, width: 30, height: 30))
        return ctx.makeImage()!
    }

    static func properties(_ m: Meta) -> [CFString: Any] {
        var props: [CFString: Any] = [kCGImagePropertyOrientation: m.orientation]
        var exif: [CFString: Any] = [:]
        if let d = m.dateTimeOriginal { exif[kCGImagePropertyExifDateTimeOriginal] = d; exif[kCGImagePropertyExifDateTimeDigitized] = d }
        if let o = m.offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = o }
        if let c = m.userComment { exif[kCGImagePropertyExifUserComment] = c }
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
        var tiff: [CFString: Any] = [:]
        if let make = m.make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model = m.model { tiff[kCGImagePropertyTIFFModel] = model }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary] = tiff }
        if let g = m.gps {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(g.lat), kCGImagePropertyGPSLatitudeRef: g.lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(g.lon), kCGImagePropertyGPSLongitudeRef: g.lon >= 0 ? "E" : "W",
            ] as [CFString: Any]
        }
        return props
    }

    @discardableResult
    static func write(_ url: URL, type: UTType, meta: Meta = Meta(), seed: Int = 0, width: Int = 96, height: Int = 64) -> URL {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage(width: width, height: height, seed: seed), properties(meta) as CFDictionary)
        precondition(CGImageDestinationFinalize(dest), "couldn't write \(url.path)")
        return url
    }

    @discardableResult static func heic(_ url: URL, _ meta: Meta = Meta(), seed: Int = 0) -> URL { write(url, type: .heic, meta: meta, seed: seed) }
    @discardableResult static func jpeg(_ url: URL, _ meta: Meta = Meta(), seed: Int = 0) -> URL { write(url, type: .jpeg, meta: meta, seed: seed) }
    @discardableResult static func png(_ url: URL, _ meta: Meta = Meta(), seed: Int = 0) -> URL { write(url, type: .png, meta: meta, seed: seed) }

    /// A small hand-made GeoNames-format table (real coordinates, CC BY 4.0 GeoNames) for Places tests.
    static let geonamesSample = """
    6167865\tToronto\tToronto\t\t43.70011\t-79.4163\tP\tPPLA\tCA\t\t08\t\t\t\t2600000\t\t175\tAmerica/Toronto\t2024-01-01
    6077243\tMontréal\tMontreal\t\t45.50884\t-73.58781\tP\tPPLA2\tCA\t\t10\t\t\t\t1600000\t\t216\tAmerica/Toronto\t2024-01-01
    6075357\tMississauga\tMississauga\t\t43.5789\t-79.6583\tP\tPPLA3\tCA\t\t08\t\t\t\t668549\t\t161\tAmerica/Toronto\t2024-01-01
    2267057\tLisboa\tLisbon\t\t38.71667\t-9.13333\tP\tPPLC\tPT\t\t14\t\t\t\t517802\t\t45\tEurope/Lisbon\t2024-01-01
    2618425\tKøbenhavn\tCopenhagen\t\t55.67594\t12.56553\tP\tPPLC\tDK\t\t17\t\t\t\t1153615\t\t14\tEurope/Copenhagen\t2024-01-01
    6949461\tIndre By\tIndre By\t\t55.68113\t12.57893\tP\tPPLX\tDK\t\t17\t\t\t\t30000\t\t14\tEurope/Copenhagen\t2024-01-01
    """
}
