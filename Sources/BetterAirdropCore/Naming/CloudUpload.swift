import Foundation

/// What the two backends that send a photo off the Mac share: Claude with the user's own key
/// (`ClaudeNamer`) and hosted naming (`HostedNamer`). Both send the same metadata-free 768 px JPEG
/// and the same text context, get back the same answer (`ClaudePrompt.parse`), and turn it into a
/// suggestion the same way.
struct CloudUpload {
    let image: Data
    let context: String

    init(_ url: URL, context ctx: PhotoContext, maxPixelSize: Int, timings: inout StageTimings) throws {
        image = try timings.time(.encode) { try UploadImage.jpeg(from: url, maxPixelSize: maxPixelSize) }
        context = ClaudePrompt.context(ctx)
    }

    /// For the `explain` trail: "a 92 KB metadata-free JPEG and the text context".
    var summary: String { "a \(image.count / 1024) KB metadata-free JPEG and the text context" }

    /// The answer merged with the local context, with `why` in front of the answer's own trail.
    func suggestion(_ answer: ClaudePrompt.Answer, context ctx: PhotoContext, backend: String, why: [String],
                    timings: StageTimings, usage: TokenUsage?) -> NameSuggestion {
        var s = answer.suggestion(context: ctx, backend: backend, maxWords: 6)
        s.usage = usage
        s.timings = timings
        s.why = why + s.why
        return s
    }

    /// `retry-after` (seconds) if the server sent one, else 1 s, 2 s, 4 s… with a little jitter. Capped at 20 s.
    static func backoff(_ attempt: Int, retryAfter: String?) -> TimeInterval {
        if let r = retryAfter.flatMap(Double.init), r >= 0 { return min(r, 20) }
        return min(pow(2, Double(attempt - 1)) + Double.random(in: 0...0.25), 20)
    }
}
