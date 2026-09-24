// M0(a) throwaway spike: Vision labels + OCR + document detection over a folder of images.
// Usage: swift scripts/spike-vision-eval.swift fixtures-local > spike-out/vision.json
// Reads only. Prints one JSON object per image. Not part of the package.
import Foundation
import ImageIO
import Vision

struct Row: Codable {
    var file: String
    var width = 0, height = 0
    var exifDate: String?
    var gps = false
    var userComment: String?
    var creator: String?
    var labels: [String] = []
    var ocrLines: [String] = []
    var docConfidence: Float?
    var docArea: Double?
    var kind = "photo"
    var candidate = ""
    var candidateV2 = ""
    var salientText: String?
    var ms = 0
}

let generic: Set<String> = [
    "structure", "outdoor", "indoor", "sky", "people", "adult", "material", "wood_processed",
    "document", "text", "screenshot", "machine", "conveyance", "land", "plant", "interior_room",
    "room", "consumer_electronics", "container", "clothing", "footwear", "art", "liquid",
    "water_body", "water", "vegetation", "grass", "tree", "cloudy", "blue_sky", "daytime", "night_sky",
    "wood_natural", "textile", "furniture", "tool", "equipment", "decoration", "games",
]
// v2: Vision's taxonomy returns parents with the same score as the leaf, so drop known parents.
let parents: Set<String> = generic.union([
    "portal", "conveyance", "tableware", "utensil", "raw_glass", "optical_equipment", "frozen",
    "domicile", "food", "frame", "people", "adult", "child", "illustrations", "chart", "diagram",
    "printed_page", "book", "sign", "vehicle", "animal", "mammal", "housewares", "cord", "light",
    "seat", "jewelry", "baked_goods", "interior_room", "land", "cloudy", "drink", "sport",
])

func xattrString(_ path: String, _ name: String) -> String? {
    let n = getxattr(path, name, nil, 0, 0, 0)
    guard n > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: n)
    getxattr(path, name, &buf, n, 0, 0)
    return String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
}

func slug(_ s: String) -> String {
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
    let parts = folded.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    let stop: Set<String> = ["the", "a", "an", "of", "and", "to", "in", "on", "for", "is", "at"]
    return parts.filter { !stop.contains($0) && $0.allSatisfy(\.isASCII) }.prefix(6).joined(separator: "-")
}

func analyze(_ url: URL) -> Row {
    let t0 = Date()
    var row = Row(file: url.lastPathComponent)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return row }
    row.width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    row.height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
    row.exifDate = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
    row.userComment = exif?[kCGImagePropertyExifUserComment] as? String
    row.gps = props[kCGImagePropertyGPSDictionary] != nil
    row.creator = xattrString(url.path, "com.apple.assetsd.creatorBundleID")

    // Downscale for Vision, as the real pipeline will.
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceThumbnailMaxPixelSize: 2048,
                                 kCGImageSourceCreateThumbnailWithTransform: true]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return row }

    let classify = VNClassifyImageRequest()
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.usesLanguageCorrection = true
    let doc = VNDetectDocumentSegmentationRequest()
    try? VNImageRequestHandler(cgImage: cg).perform([classify, text, doc])

    let obs = (classify.results ?? []).filter { $0.confidence > 0.1 }.sorted { $0.confidence > $1.confidence }
    row.labels = obs.prefix(10).map { String(format: "%@:%.2f", $0.identifier, $0.confidence) }
    row.ocrLines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    // v2 salience: tallest line with >= 4 letters that isn't status-bar noise.
    let status = try! NSRegularExpression(pattern: #"^[\d:.\s%()+•?|/-]*$|^\d{1,2}:\d{2}"#)
    let salient = (text.results ?? []).compactMap { o -> (String, Double)? in
        guard let c = o.topCandidates(1).first, c.confidence >= 0.5 else { return nil }
        let s = c.string
        let letters = s.filter(\.isLetter).count
        guard letters >= 4, status.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil else { return nil }
        return (s, Double(o.boundingBox.height) * Double(min(letters, 20)).squareRoot())
    }.max { $0.1 < $1.1 }
    row.salientText = salient?.0
    if let d = doc.results?.first {
        row.docConfidence = d.confidence
        row.docArea = Double(d.boundingBox.width * d.boundingBox.height)
    }

    // Kind heuristics.
    let joined = row.ocrLines.joined(separator: " ").lowercased()
    let labelIds = Set(obs.filter { $0.confidence > 0.3 }.map(\.identifier))
    let money = joined.range(of: #"\$?\d+\.\d{2}\b"#, options: .regularExpression) != nil
    if row.userComment == "Screenshot" || row.creator == "com.apple.springboard" {
        row.kind = "screenshot"
    } else if money && ["total", "subtotal", "tax", "hst", "visa", "debit", "change"].contains(where: joined.contains) {
        row.kind = "receipt"
    } else if labelIds.contains("whiteboard") || labelIds.contains("blackboard") {
        row.kind = "whiteboard"
    } else if (row.docArea ?? 0) > 0.25 && (row.docConfidence ?? 0) > 0.8 && row.ocrLines.count >= 8 {
        row.kind = "document"
    }

    // Candidate name.
    var subject = ""
    if row.kind != "photo", let first = row.ocrLines.first(where: { slug($0).count >= 6 }) {
        subject = slug(first)
    }
    if subject.isEmpty {
        let specific = obs.filter { $0.confidence >= 0.3 && !generic.contains($0.identifier) }.prefix(3)
        subject = specific.map { slug($0.identifier.replacingOccurrences(of: "_", with: " ")) }.joined(separator: "-")
    }
    let date = row.exifDate.map { String($0.prefix(10)).replacingOccurrences(of: ":", with: "-") } ?? "nodate"
    let stem = url.deletingPathExtension().lastPathComponent.lowercased()
    var parts = [date]
    if row.kind != "photo" { parts.append(row.kind) }
    parts.append(subject.isEmpty ? "photo-\(slug(stem))" : subject)
    row.candidate = parts.joined(separator: "_")

    // v2 composer.
    let leaves = obs.filter { $0.confidence >= 0.3 && !parents.contains($0.identifier) }.prefix(2)
    let strongLabel = leaves.contains { $0.confidence >= 0.5 }
    var subj2 = ""
    if (row.kind != "photo" || (!strongLabel && row.ocrLines.count >= 3)), let t = row.salientText {
        subj2 = slug(t)
    }
    if subj2.isEmpty {
        subj2 = leaves.map { slug($0.identifier.replacingOccurrences(of: "_", with: " ")) }.joined(separator: "-")
    }
    var p2 = [date]
    if row.kind != "photo" { p2.append(row.kind) }
    p2.append(subj2.isEmpty ? "photo-\(slug(stem))" : subj2)
    row.candidateV2 = p2.joined(separator: "_")
    row.ms = Int(Date().timeIntervalSince(t0) * 1000)
    return row
}

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "fixtures-local")
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { ["heic", "heif", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try enc.encode(files.map(analyze)), as: UTF8.self))
