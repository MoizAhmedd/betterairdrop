import BetterAirdropCore
import Foundation

/// The live preview under Settings → Naming → Name format.
public enum TemplatePreview {
    public static let sample: [String: String] = [
        "date": "2026-09-24", "time": "14-03", "place": "toronto", "country": "ca",
        "subject": "walnut-lamp-on-oak-sideboard", "kind": "photo", "device": "iphone-15-pro",
        "merchant": "loblaws", "total": "84-12", "orig": "img-4821",
    ]
    /// Token chips, in the order they're offered.
    public static let tokens = ["date", "time", "place", "country", "subject", "kind", "device", "orig"]

    /// The name a sample photo would get, or the template's error.
    public static func render(_ source: String, ext: String = "jpg") -> Result<String, Error> {
        do {
            let t = try Template(source)
            guard let stem = t.render(sample) else { return .failure(CocoaError(.formatting)) }
            return .success("\(stem).\(ext)")
        } catch { return .failure(error) }
    }
}
