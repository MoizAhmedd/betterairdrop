import CoreGraphics
import CoreText
import Foundation

/// PDFs made on the fly with CoreGraphics: one with a real text layer, a "scan" (the same kind of
/// page drawn as a picture, so there's no text to extract) and encrypted ones. No binary fixtures.
enum TestPDFs {
    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter, in points

    static func draw(_ lines: [String], in ctx: CGContext, height: CGFloat, size: CGFloat) {
        var y = height - size * 4
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        for l in lines {
            let attr = NSAttributedString(string: l, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            ctx.textPosition = CGPoint(x: size * 4, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            y -= size * 1.6
        }
    }

    /// A PDF whose pages carry these lines as real text.
    @discardableResult
    static func text(_ url: URL, pages: [[String]], title: String? = nil, info: [CFString: Any] = [:]) -> URL {
        var box = page
        var meta = info
        if let title { meta[kCGPDFContextTitle] = title }
        let ctx = CGContext(url as CFURL, mediaBox: &box, meta as CFDictionary)!
        for lines in pages {
            ctx.beginPDFPage(nil)
            draw(lines, in: ctx, height: page.height, size: 16)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    @discardableResult
    static func text(_ url: URL, _ lines: [String], title: String? = nil) -> URL { text(url, pages: [lines], title: title) }

    /// A one-page "scan": the lines rendered into a bitmap, and only the bitmap placed on the page.
    @discardableResult
    static func scanned(_ url: URL, _ lines: [String]) -> URL {
        let w = 1224, h = 1584
        let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bmp.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bmp.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        draw(lines, in: bmp, height: CGFloat(h), size: 44)
        var box = page
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(bmp.makeImage()!, in: page)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// Encrypted with an owner password only (it opens without a password), or with a user password too.
    @discardableResult
    static func encrypted(_ url: URL, userPassword: String = "") -> URL {
        text(url, pages: [invoiceLines], info: [kCGPDFContextOwnerPassword: "owner", kCGPDFContextUserPassword: userPassword])
    }

    static let invoiceLines = ["INVOICE", "Bell Canada", "Invoice date: October 12, 2026", "Account 1234 5678",
                               "Internet and TV, monthly service", "Total due: $84.12"]
    static let leaseLines = ["RESIDENTIAL LEASE AGREEMENT", "45 Carlton Street, Toronto", "Signed September 30, 2026"]
}
