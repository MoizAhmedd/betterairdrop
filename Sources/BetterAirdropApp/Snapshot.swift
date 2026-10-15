import AppKit

/// Development aid: with BETTERAIRDROP_SNAPSHOT_DIR set, the app opens each of its surfaces in turn
/// and saves a PNG of its own windows (an app may always capture its own windows, so this needs no
/// Screen Recording permission). Used to compare the UI against the mockups.
@MainActor
enum Snapshot {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["BETTERAIRDROP_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func capture(_ window: NSWindow?, _ name: String) {
        guard let window, let dir = directory else { return }
        window.displayIfNeeded()
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.boundsIgnoreFraming, .bestResolution]) else {
            NSLog("snapshot \(name): capture failed"); return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// The menu-bar glyph in its states, on light and dark strips (the status item's own window
    /// can't be captured).
    static func saveGlyphs() {
        guard let dir = directory else { return }
        let img = NSImage(size: NSSize(width: 150, height: 48), flipped: false) { _ in
            for (row, bg, fg) in [(0, NSColor(white: 0.93, alpha: 1), NSColor.black), (1, NSColor(white: 0.16, alpha: 1), NSColor.white)] {
                bg.setFill(); NSRect(x: 0, y: CGFloat(row) * 24, width: 150, height: 24).fill()
                for (i, paused) in [false, true].enumerated() {
                    let g = Art.menuBarGlyph(paused: paused)
                    let tinted = NSImage(size: g.size, flipped: false) { r in
                        g.draw(in: r); fg.withAlphaComponent(paused ? 0.5 : 1).set(); r.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: NSRect(x: 12 + CGFloat(i) * 40, y: CGFloat(row) * 24 + 3, width: 18, height: 18))
                }
                NSColor.systemOrange.setFill()
                let g = Art.menuBarGlyph()
                let tinted = NSImage(size: g.size, flipped: false) { r in g.draw(in: r); fg.set(); r.fill(using: .sourceAtop); return true }
                tinted.draw(in: NSRect(x: 92, y: CGFloat(row) * 24 + 3, width: 18, height: 18))
                NSBezierPath(ovalIn: NSRect(x: 107, y: CGFloat(row) * 24 + 15, width: 6, height: 6)).fill()
            }
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("menubar-glyphs.png"))
    }

    /// Up to four images already in the folder (for the preview sheet snapshot).
    static func sampleFiles(_ folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().filter { !$0.hasPrefix(".") }.prefix(4).map { folder.appendingPathComponent($0) }
    }

    /// Runs `steps` one after another, `delay` seconds apart, then quits if asked to.
    static func run(_ steps: [(String, () -> Void)], delay: TimeInterval = 1.2) {
        var remaining = steps
        func next() {
            guard !remaining.isEmpty else {
                if ProcessInfo.processInfo.environment["BETTERAIRDROP_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
                return
            }
            let (_, step) = remaining.removeFirst()
            step()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { next() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { next() }
    }
}
