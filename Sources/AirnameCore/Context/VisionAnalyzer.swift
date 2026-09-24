import Foundation
import ImageIO
import Vision

/// Runs Apple Vision on a downscaled copy of the image: scene labels, OCR and document detection.
/// Everything stays on the Mac.
public enum VisionAnalyzer {
    public static let maxPixelSize = 2048

    public static func analyze(_ url: URL) -> VisionResult? {
        let t0 = Date()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,   // apply EXIF orientation so OCR reads upright text
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        let document = VNDetectDocumentSegmentationRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([classify, text, document])
        } catch {
            return nil
        }

        var r = VisionResult()
        r.labels = (classify.results ?? [])
            .filter { $0.confidence >= 0.1 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(15)
            .map { .init($0.identifier, Double($0.confidence)) }
        r.lines = (text.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first else { return nil }
            let box = obs.boundingBox   // normalized, origin bottom-left
            return .init(c.string, confidence: Double(c.confidence), height: Double(box.height), top: Double(1 - box.maxY))
        }
        if let d = document.results?.first {
            r.documentConfidence = Double(d.confidence)
            r.documentArea = Double(d.boundingBox.width * d.boundingBox.height)
        }
        r.milliseconds = Int(Date().timeIntervalSince(t0) * 1000)
        return r
    }
}
