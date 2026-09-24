import Foundation

/// `~/.config/airname/config.toml`. Every key is optional.
public struct Config: Sendable, Equatable {
    public enum Originals: String, Sendable, CaseIterable { case trash, keep, delete }
    public enum PlaceProvider: String, Sendable, CaseIterable { case offline, apple, none }

    public var backend = "auto"
    public var template = "{date}_{place}_{subject}"
    public var originals = Originals.trash
    public var convertHEIC = true
    public var jpegQuality = 0.88
    public var maxSubjectWords = 6
    public var language = "en"

    public var watchEnabled = true
    public var watchFolder = "~/Downloads"
    public var watchAirdropOnly = true
    public var watchNotify = true

    public var placeProvider = PlaceProvider.offline
    public var stripGPSFromOutput = false

    public var kindTemplates: [String: String] = [
        "screenshot": "{date}_screenshot_{subject}",
        "receipt": "{date}_receipt_{merchant}_{total}",
        "document": "{date}_doc_{subject}",
        "whiteboard": "{date}_whiteboard_{subject}",
    ]

    public var ollamaURL = "http://127.0.0.1:11434"
    public var ollamaModel = "qwen3.5:4b"
    public var claudeModel = ClaudeNamer.defaultModel
    /// Whether `backend = "auto"` may use Claude when a credential is found. Off = auto stays on-device.
    public var claudeInAuto = true

    /// Keys the parser didn't recognise (reported by `doctor`, never fatal).
    public var unknownKeys: [String] = []

    public init() {}

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public var line: Int
        public var message: String
        public var description: String { "config line \(line): \(message)" }
    }

    public static var defaultPath: URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["AIRNAME_CONFIG"] { return URL(fileURLWithPath: p) }
        let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("airname/config.toml")
    }

    /// Loads the config, or the defaults if the file doesn't exist.
    public static func load(from url: URL = defaultPath) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// Parses the TOML subset airname uses: `key = value` pairs and one level of `[tables]`.
    /// Values are "strings", numbers and true/false. `#` starts a comment outside strings.
    public static func parse(_ text: String) throws -> Config {
        var c = Config()
        var table = ""
        for (i, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let n = i + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else { throw ParseError(line: n, message: "bad table header") }
                table = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { throw ParseError(line: n, message: "expected key = value") }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = try parseValue(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces), line: n)
            try c.apply(table.isEmpty ? key : "\(table).\(key)", value, line: n)
        }
        return c
    }

    enum Value: Equatable { case string(String), number(Double), bool(Bool) }

    static func stripComment(_ s: String) -> String {
        var inString = false, escaped = false
        for (i, ch) in s.enumerated() {
            if escaped { escaped = false; continue }
            if ch == "\\" && inString { escaped = true; continue }
            if ch == "\"" { inString.toggle() }
            if ch == "#" && !inString { return String(s.prefix(i)) }
        }
        return s
    }

    static func parseValue(_ s: String, line: Int) throws -> Value {
        if s.hasPrefix("\"") {
            guard s.count >= 2, s.hasSuffix("\"") else { throw ParseError(line: line, message: "unterminated string") }
            var out = "", escaped = false
            for ch in s.dropFirst().dropLast() {
                if escaped {
                    switch ch { case "n": out.append("\n"); case "t": out.append("\t"); default: out.append(ch) }
                    escaped = false
                } else if ch == "\\" { escaped = true } else { out.append(ch) }
            }
            return .string(out)
        }
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if let d = Double(s.replacingOccurrences(of: "_", with: "")) { return .number(d) }
        throw ParseError(line: line, message: "can't read value \(s) (strings need quotes)")
    }

    /// Sets a dotted key (`watch.enabled`). Used by the parser and by `airname config set`.
    public mutating func set(_ key: String, _ raw: String) throws {
        let value: Value = (try? Self.parseValue(raw, line: 0)) ?? .string(raw)
        try apply(key, value, line: 0)
    }

    mutating func apply(_ key: String, _ v: Value, line: Int) throws {
        func str() throws -> String {
            guard case .string(let s) = v else { throw ParseError(line: line, message: "\(key) must be a string") }
            return s
        }
        func bool() throws -> Bool {
            guard case .bool(let b) = v else { throw ParseError(line: line, message: "\(key) must be true or false") }
            return b
        }
        func num() throws -> Double {
            guard case .number(let d) = v else { throw ParseError(line: line, message: "\(key) must be a number") }
            return d
        }
        func oneOf<E: RawRepresentable & CaseIterable>(_: E.Type) throws -> E where E.RawValue == String {
            let s = try str()
            guard let e = E(rawValue: s) else {
                throw ParseError(line: line, message: "\(key) must be one of \(E.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return e
        }
        switch key {
        case "backend":
            let s = try str()
            guard ["auto", "apple", "vision", "ollama", "claude"].contains(s) else {
                throw ParseError(line: line, message: "backend must be auto, apple, vision, ollama or claude")
            }
            backend = s
        case "template":
            let s = try str()
            do { _ = try Template(s) } catch { throw ParseError(line: line, message: "\(error)") }
            template = s
        case "originals": originals = try oneOf(Originals.self)
        case "convert_heic": convertHEIC = try bool()
        case "jpeg_quality":
            let q = try num()
            guard (0.1...1).contains(q) else { throw ParseError(line: line, message: "jpeg_quality must be between 0.1 and 1") }
            jpegQuality = q
        case "max_subject_words":
            let w = Int(try num())
            guard (1...12).contains(w) else { throw ParseError(line: line, message: "max_subject_words must be 1–12") }
            maxSubjectWords = w
        case "language": language = try str()
        case "watch.enabled": watchEnabled = try bool()
        case "watch.folder": watchFolder = try str()
        case "watch.airdrop_only": watchAirdropOnly = try bool()
        case "watch.notify": watchNotify = try bool()
        case "place.provider": placeProvider = try oneOf(PlaceProvider.self)
        case "place.strip_gps_from_output": stripGPSFromOutput = try bool()
        case "ollama.url": ollamaURL = try str()
        case "ollama.model": ollamaModel = try str()
        case "claude.model": claudeModel = try str()
        case "claude.auto": claudeInAuto = try bool()
        default:
            if key.hasPrefix("templates.") {
                let kind = String(key.dropFirst("templates.".count))
                let s = try str()
                do { _ = try Template(s) } catch { throw ParseError(line: line, message: "\(error)") }
                kindTemplates[kind] = s
            } else {
                unknownKeys.append(key)
            }
        }
    }
}
