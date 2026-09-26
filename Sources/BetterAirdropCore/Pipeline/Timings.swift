import Foundation
import os

/// Wall-clock time one photo spent in each pipeline stage, in milliseconds. Shown by `explain`,
/// printed by `watch`, and logged (subsystem `dev.betterairdrop`, category `perf`).
///
/// Stages can overlap: naming runs while the watcher waits for a burst to go quiet, so the stages
/// don't have to add up to `total` (first seen → renamed).
public struct StageTimings: Codable, Sendable, Equatable {
    public enum Stage: String, CaseIterable, Codable, Sendable {
        /// First seen → size, mtime and container stable.
        case settle
        /// Named and ready → the burst was committed (waiting for the quiet window or other photos).
        case quiet
        /// Resolving the Claude credential (spawning `ant` when the cached token is missing or stale).
        case credential
        /// Apple Vision labels, OCR and document detection.
        case vision
        /// Downscaling and re-encoding the copy sent to Claude.
        case encode
        /// The Messages API request, retries included.
        case claude
        /// HEIC → JPEG.
        case convert
        /// Journal, move into place, marker, original to the Trash.
        case commit
        /// First seen by the watcher → renamed.
        case total
    }

    public var ms: [String: Int] = [:]

    public init() {}

    public subscript(_ stage: Stage) -> Int? {
        get { ms[stage.rawValue] }
        set { ms[stage.rawValue] = newValue }
    }

    public var isEmpty: Bool { ms.isEmpty }

    public mutating func add(_ stage: Stage, seconds: TimeInterval) {
        ms[stage.rawValue, default: 0] += max(0, Int((seconds * 1000).rounded()))
    }

    public mutating func merge(_ other: StageTimings?) {
        for (k, v) in other?.ms ?? [:] { ms[k, default: 0] += v }
    }

    /// Runs `body` and adds its duration to `stage`.
    public mutating func time<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { add(stage, seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9) }
        return try body()
    }

    /// "settle 520 ms · vision 840 ms · claude 1630 ms · convert 310 ms · commit 45 ms · total 3.4 s"
    public var summary: String {
        Stage.allCases.compactMap { s -> String? in
            guard let v = self[s] else { return nil }
            return s == .total ? String(format: "total %.1f s", Double(v) / 1000) : "\(s.rawValue) \(v) ms"
        }.joined(separator: " · ")
    }
}

/// The `perf` log. `log stream --predicate 'subsystem == "dev.betterairdrop"' --info` shows it.
public enum PerfLog {
    public static let logger = Logger(subsystem: "dev.betterairdrop", category: "perf")

    public static func record(_ file: String, _ t: StageTimings) {
        let name = (file as NSString).lastPathComponent
        logger.info("\(name, privacy: .private) \(t.summary, privacy: .public)")
    }
}
