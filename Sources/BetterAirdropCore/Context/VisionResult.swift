import Foundation

/// Output of the on-device Vision pass (filled by `VisionAnalyzer`).
public struct VisionResult: Codable, Sendable, Equatable {
    public struct Label: Codable, Sendable, Equatable {
        public var id: String
        public var confidence: Double
        public init(_ id: String, _ confidence: Double) { self.id = id; self.confidence = confidence }
    }
    public struct TextLine: Codable, Sendable, Equatable {
        public var text: String
        public var confidence: Double
        /// Height of the line's box as a fraction of the image height (a proxy for font size).
        public var height: Double
        /// Vertical position of the box's top edge, 0 = top of the image.
        public var top: Double
        public init(_ text: String, confidence: Double = 1, height: Double = 0.02, top: Double = 0.5) {
            self.text = text; self.confidence = confidence; self.height = height; self.top = top
        }
    }
    public var labels: [Label] = []
    public var lines: [TextLine] = []
    /// Confidence and area (fraction of the image) of the detected document rectangle, if any.
    public var documentConfidence: Double?
    public var documentArea: Double?
    public var milliseconds: Int = 0

    public init(labels: [Label] = [], lines: [TextLine] = [], documentConfidence: Double? = nil, documentArea: Double? = nil) {
        self.labels = labels; self.lines = lines
        self.documentConfidence = documentConfidence; self.documentArea = documentArea
    }
}
