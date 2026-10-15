import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Reads what a PDF says, on this Mac (Pro, "Name PDFs too"). The text layer of the first
/// `maxPages` pages, cut to `maxChars`; a scan with no text layer has page 1 rendered and read with
/// Vision OCR instead. Only this text ever reaches a namer: never the file or a page image.
public enum PDFText {
    public static let maxPages = 2
    /// UTF-16 units (what the hosted Worker's 6,000-character cap counts), so the cap holds for any script.
    public static let maxChars = 4000
    /// Fewer letters than this in the text layer means a scan (or a stray "Scanned with…" footer).
    static let minLetters = 30
    /// Long edge of page 1 rendered for OCR (the same as `VisionAnalyzer` uses for photos).
    static let ocrPixels: CGFloat = 2048

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case unreadable, encrypted, noText
        public var description: String {
            switch self {
            case .unreadable: "not a readable PDF"
            case .encrypted: "encrypted PDF"
            case .noText: "no text in the PDF, and OCR found none on page 1"
            }
        }
    }

    /// - Parameter ocr: reads a rendered page (injectable for tests); Vision by default.
    public static func extract(_ url: URL, ocr: (CGImage) -> String? = PDFText.recognize) throws -> DocumentText {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw Error.unreadable }
        if doc.isEncrypted || doc.isLocked { throw Error.encrypted }
        let attrs = doc.documentAttributes ?? [:]
        let title = cleanTitle(attrs[PDFDocumentAttribute.titleAttribute] as? String)
        let created = (attrs[PDFDocumentAttribute.creationDateAttribute] as? Date).map(isoDay)

        let layer = (0..<min(maxPages, doc.pageCount)).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        var text = normalize(layer)
        var source = DocumentText.Source.text
        if text.filter(\.isLetter).count < minLetters {
            guard let page = doc.page(at: 0), let image = render(page), let read = ocr(image).map(normalize),
                  read.filter(\.isLetter).count >= 4 else {
                if text.filter(\.isLetter).count >= 4 { return DocumentText(text: cut(text), source: .text, pages: doc.pageCount, title: title, created: created) }
                throw Error.noText
            }
            text = read
            source = .ocr
        }
        return DocumentText(text: cut(text), source: source, pages: doc.pageCount, title: title, created: created)
    }

    /// Trims each line, collapses runs of spaces and drops empty lines.
    static func normalize(_ s: String) -> String {
        s.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// At most `maxChars` UTF-16 units, cut at a character boundary.
    static func cut(_ s: String, max: Int = maxChars) -> String {
        guard s.utf16.count > max else { return s }
        var out = ""
        var n = 0
        for c in s {
            let w = c.utf16.count
            if n + w > max { break }
            out.append(c); n += w
        }
        return out
    }

    /// Metadata titles are often junk from the app that made the PDF ("Microsoft Word - Document1",
    /// "untitled", a file name). Those are dropped.
    static func cleanTitle(_ t: String?) -> String? {
        guard let t = t?.trimmingCharacters(in: .whitespacesAndNewlines), t.filter(\.isLetter).count >= 3 else { return nil }
        let l = t.lowercased()
        if l.hasPrefix("microsoft word") || l.hasPrefix("untitled") || l == "document" || l.hasSuffix(".pdf")
            || l.hasSuffix(".doc") || l.hasSuffix(".docx") || l.hasPrefix("print") { return nil }
        return String(t.prefix(120))
    }

    static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Page 1 on white at `ocrPixels` on the long edge, with the page's rotation applied.
    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = ocrPixels / max(size.width, size.height)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Vision OCR, lines top to bottom.
    public static func recognize(_ image: CGImage) -> String? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])) != nil else { return nil }
        let lines = (req.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first.flatMap { $0.confidence >= 0.3 ? $0.string : nil } }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// The checks that keep PDF naming from touching a file it shouldn't. Cheap: no text is read.
public enum PDFIntake {
    public static let extensions: Set<String> = ["pdf"]

    public static func isPDF(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Browsers write next to the final name while downloading: Safari `x.pdf.download`, Chrome
    /// `x.pdf.crdownload`, Firefox `x.pdf.part` (with an empty `x.pdf` placeholder).
    static let partialSiblings = Planner.partialSuffixes + [".part"]

    /// True while a browser is still writing this PDF.
    public static func isDownloading(_ url: URL) -> Bool {
        partialSiblings.contains { FileManager.default.fileExists(atPath: url.path + $0) }
    }

    /// A complete PDF starts with `%PDF-` and has `%%EOF` in its last 1 KB. A file cut off mid-download
    /// (or Firefox's empty placeholder) fails this.
    public static func isComplete(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size >= 16,
              (try? h.seek(toOffset: 0)) != nil, let head = try? h.read(upToCount: 5), head == Data("%PDF-".utf8) else { return false }
        let n = min(size, 1024)
        guard (try? h.seek(toOffset: size - n)) != nil, let tail = try? h.read(upToCount: Int(n)) else { return false }
        return tail.range(of: Data("%%EOF".utf8)) != nil
    }

    /// Encrypted PDFs are left alone, including ones that open without a password (an owner password
    /// restricting copying or printing): whoever made them asked for their contents to be protected.
    public static func isEncrypted(_ url: URL) -> Bool {
        guard let doc = CGPDFDocument(url as CFURL) else { return false }
        return doc.isEncrypted
    }

    /// Inside an app bundle, a Photos library or any other package (a folder Finder shows as one file).
    public static func isInsidePackage(_ url: URL) -> Bool {
        var dir = url.deletingLastPathComponent().standardizedFileURL
        while dir.path != "/" && !dir.path.isEmpty {
            if (try? dir.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return true }
            let ext = dir.pathExtension.lowercased()
            if ["app", "bundle", "framework", "photoslibrary", "pkg", "xcarchive"].contains(ext) { return true }
            dir = dir.deletingLastPathComponent()
        }
        return false
    }
}
