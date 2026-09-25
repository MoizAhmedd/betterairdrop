import Foundation

/// Writes `config.toml` back without losing the user's comments or layout: keys that exist are
/// edited in place (keeping any trailing comment), missing keys that differ from the default are
/// added under the right table, and everything else (comments, unknown keys) is left alone.
extension Config {
    /// Every key the app can change, with its TOML value.
    public var tomlValues: [(key: String, value: String)] {
        var out: [(String, String)] = [
            ("backend", Self.quote(backend)),
            ("template", Self.quote(template)),
            ("originals", Self.quote(originals.rawValue)),
            ("convert_heic", "\(convertHEIC)"),
            ("jpeg_quality", Self.number(jpegQuality)),
            ("max_subject_words", "\(maxSubjectWords)"),
            ("language", Self.quote(language)),
            ("watch.enabled", "\(watchEnabled)"),
            ("watch.folder", Self.quote(watchFolder)),
            ("watch.airdrop_only", "\(watchAirdropOnly)"),
            ("watch.notify", "\(watchNotify)"),
            ("place.provider", Self.quote(placeProvider.rawValue)),
            ("place.strip_gps_from_output", "\(stripGPSFromOutput)"),
            ("ollama.url", Self.quote(ollamaURL)),
            ("ollama.model", Self.quote(ollamaModel)),
            ("claude.model", Self.quote(claudeModel)),
            ("claude.auto", "\(claudeInAuto)"),
        ]
        for (kind, t) in kindTemplates.sorted(by: { $0.key < $1.key }) { out.append(("templates.\(kind)", Self.quote(t))) }
        return out
    }

    static func quote(_ s: String) -> String {
        var o = "\""
        for ch in s {
            switch ch {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\t": o += "\\t"
            default: o.append(ch)
            }
        }
        return o + "\""
    }

    static func number(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.1f", d) : "\(d)"
    }

    /// The updated file text for `existing` (nil = no file yet).
    public func rendered(updating existing: String?) -> String {
        let defaults = Dictionary(Config().tomlValues, uniquingKeysWith: { a, _ in a })
        var wanted = tomlValues
        var lines = (existing ?? "").components(separatedBy: "\n")
        if existing == nil || existing == "" { lines = [] }
        var seen = Set<String>()
        var table = ""
        var lastLineOfTable: [String: Int] = [:]
        var firstTableHeader: Int?
        let values = Dictionary(wanted, uniquingKeysWith: { a, _ in a })

        for i in lines.indices {
            let stripped = Self.stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
                table = stripped.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if firstTableHeader == nil { firstTableHeader = i }
                lastLineOfTable[table] = i
                continue
            }
            guard let eq = stripped.firstIndex(of: "=") else { continue }
            let key = stripped[..<eq].trimmingCharacters(in: .whitespaces)
            let full = table.isEmpty ? key : "\(table).\(key)"
            lastLineOfTable[table] = i
            guard let v = values[full], !seen.contains(full) else { continue }
            seen.insert(full)
            // Keep indentation and any trailing comment (with its original spacing).
            let raw = lines[i]
            let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
            let code = Self.stripComment(raw)
            let comment = String(raw.dropFirst(code.count))
            let spacing = String(code.reversed().prefix { $0 == " " || $0 == "\t" })
            let body = "\(indent)\(key) = \(v)"
            lines[i] = comment.isEmpty ? body : body + (spacing.isEmpty ? " " : spacing) + comment
        }

        // Keys not in the file: add them only if they differ from the default.
        wanted.removeAll { seen.contains($0.key) || defaults[$0.key] == $0.value }
        var topLevel: [String] = []
        var byTable: [String: [String]] = [:]
        var tableOrder: [String] = []
        for (key, v) in wanted {
            if let dot = key.firstIndex(of: ".") {
                let t = String(key[..<dot]), k = String(key[key.index(after: dot)...])
                if byTable[t] == nil { tableOrder.append(t) }
                byTable[t, default: []].append("\(k) = \(v)")
            } else {
                topLevel.append("\(key) = \(v)")
            }
        }
        // Insert into existing tables from the bottom up so indices stay valid.
        var inserts: [(Int, [String])] = []
        for t in tableOrder where lastLineOfTable[t] != nil && !t.isEmpty {
            inserts.append((lastLineOfTable[t]! + 1, byTable.removeValue(forKey: t)!))
        }
        if !topLevel.isEmpty {
            if let h = firstTableHeader {
                // After the last top-level key, or before the first table.
                let at = lastLineOfTable[""].map { $0 + 1 } ?? h
                inserts.append((at, topLevel + (lastLineOfTable[""] == nil ? [""] : [])))
            } else {
                inserts.append((lastLineOfTable[""].map { $0 + 1 } ?? lines.count, topLevel))
            }
        }
        for (at, new) in inserts.sorted(by: { $0.0 > $1.0 }) { lines.insert(contentsOf: new, at: at) }
        for t in tableOrder where byTable[t] != nil {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(t)]")
            lines.append(contentsOf: byTable[t]!)
        }
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    /// Saves to `url`, creating the folder if needed. Comments and unknown keys survive.
    public func save(to url: URL = Config.defaultPath) throws {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(rendered(updating: existing).utf8).write(to: url, options: .atomic)
    }
}

