import BetterAirdropCore
import ArgumentParser
import Foundation

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the extracted context and why a name was picked. Changes nothing.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "An image file (or a PDF, with Pro and name_pdfs on).", completion: .file())
    var file: String

    @Option(help: "Naming backend: auto, claude (your API key), hosted (Pro naming), apple (Apple Intelligence, macOS 26+) or vision (basic, on this Mac).")
    var backend: String?

    @Option(help: "Filename template to explain against.")
    var template: String?

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let config = try global.loadConfig()
        var planner = try makePlanner(config: config, backend: backend)
        planner.templateOverride = template
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath).standardizedFileURL
        let p = planner.plan([url])[0]
        if json { try printJSON(p); return }

        print(tilde(p.source))
        if p.action == .skip, p.context == nil { print("  skipped: \(p.reason ?? "")"); return }
        guard let ctx = p.context else { return }
        let m = ctx.metadata
        func row(_ k: String, _ v: String) { print("  " + k.padding(toLength: 10, withPad: " ", startingAt: 0) + v) }

        row("date", [m.date, m.time.map { "\($0.prefix(2)):\($0.suffix(2))" }, m.offset].compactMap { $0 }.joined(separator: " ")
            + (m.dateSource == "file" ? (ctx.document != nil ? "  (file creation date)" : "  (no EXIF date: file creation date)")
               : m.dateSource == "document" ? "  (the document's own date)" : m.dateSource == "pdf" ? "  (the PDF's creation date)" : ""))
        row("place", ctx.place.map { "\($0.city), \($0.countryCode)  (\($0.distanceKm) km from the city point)" }
            ?? (m.hasGPS ? "GPS present, no city with 15k+ people within 25 km" : "no GPS"))
        row("device", m.model ?? "unknown")
        row("airdrop", ctx.airdrop ? "yes (quarantine agent sharingd)" : "no")
        row("kind", "\(ctx.kind.rawValue)  (\(ctx.kindReason))")
        if let d = ctx.document {
            row("pdf", "\(d.pages) page\(d.pages == 1 ? "" : "s"), \(d.text.count) characters \(d.source == .ocr ? "OCR'd from page 1 (no text layer)" : "from the text layer")"
                + (d.title.map { ", title \"\($0)\"" } ?? ""))
            row("text", "\"\(d.text.prefix(120).replacingOccurrences(of: "\n", with: " / "))\(d.text.count > 120 ? "…" : "")\"")
        }
        if let v = ctx.vision {
            row("labels", v.labels.prefix(8).map { "\($0.id) \(String(format: "%.2f", $0.confidence))" }.joined(separator: ", ").ifEmpty("none"))
            let lines = v.lines.filter { $0.confidence >= 0.3 }
            row("text", lines.isEmpty ? "none" : "\(lines.count) lines, e.g. \"\(lines.prefix(3).map(\.text).joined(separator: " / "))\"")
            if let c = v.documentConfidence, c > 0 { row("document", String(format: "outline %.2f, %.0f%% of the image", c, (v.documentArea ?? 0) * 100)) }
            row("vision", "\(v.milliseconds) ms")
        }
        if let s = p.suggestion {
            row("backend", "\(s.backend)  (confidence \(String(format: "%.2f", s.confidence)))")
            for w in s.why { row("", "· " + w) }
            if let u = s.usage {
                row("tokens", "\(u.inputTokens) in, \(u.outputTokens) out (about $\(String(format: "%.4f", u.cost())) on \(u.model))")
            }
        } else {
            row("backend", "none produced a subject")
        }
        if let t = p.timings, !t.isEmpty { row("timing", t.summary) }
        if let n = planner.namer, Backends.isCloud(n), let ms = ClaudeAuth.shared.lastLookupMilliseconds {
            row("", "· credential lookup at start-up: \(ms) ms (cached until shortly before it expires)")
        }
        row("template", p.template ?? "-")
        switch p.action {
        case .skip: row("result", "skip: \(p.reason ?? "")")
        case .convert, .rename:
            row("result", "\((p.target! as NSString).lastPathComponent)\(p.action == .convert ? "  (HEIC converted to JPEG)" : "")")
        }
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
