import AppKit

/// Icons drawn in code (from the UX mockups' SVG), so there are no binary assets to keep in sync.
enum Art {
    /// The menu-bar tag glyph, 18×18 pt, as a template image. `paused` adds a slash.
    static func menuBarGlyph(paused: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let tag = NSBezierPath()
            tag.move(to: NSPoint(x: 2.5, y: 4.5))
            tag.curve(to: NSPoint(x: 4.5, y: 2.5), controlPoint1: NSPoint(x: 2.5, y: 3.4), controlPoint2: NSPoint(x: 3.4, y: 2.5))
            tag.line(to: NSPoint(x: 10.5, y: 2.5))
            tag.line(to: NSPoint(x: 15.5, y: 9))
            tag.line(to: NSPoint(x: 10.5, y: 15.5))
            tag.line(to: NSPoint(x: 4.5, y: 15.5))
            tag.curve(to: NSPoint(x: 2.5, y: 13.5), controlPoint1: NSPoint(x: 3.4, y: 15.5), controlPoint2: NSPoint(x: 2.5, y: 14.6))
            tag.close()
            tag.lineWidth = 1.5
            tag.lineJoinStyle = .round
            tag.stroke()
            NSBezierPath(ovalIn: NSRect(x: 11.2 - 1.3, y: 9 - 1.3, width: 2.6, height: 2.6)).fill()
            for (a, b) in [(NSPoint(x: 5, y: 7), NSPoint(x: 8.5, y: 7)), (NSPoint(x: 5, y: 10.5), NSPoint(x: 7.2, y: 10.5))] {
                let l = NSBezierPath(); l.move(to: a); l.line(to: b); l.lineWidth = 1.4; l.lineCapStyle = .round; l.stroke()
            }
            if paused {
                let slash = NSBezierPath(); slash.move(to: NSPoint(x: 2, y: 16.5)); slash.line(to: NSPoint(x: 16.5, y: 1.5))
                slash.lineCapStyle = .round
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                slash.lineWidth = 3.4; slash.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                slash.lineWidth = 1.4; slash.stroke()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "BetterAirdrop"
        return img
    }

    /// The app icon: a photo card with a name tag on a blue squircle.
    static func appIcon(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = size / 100
            ctx.scaleBy(x: s, y: s)
            // Leave the standard macOS icon margin (the squircle is ~80% of the canvas).
            ctx.translateBy(x: 10, y: 10); ctx.scaleBy(x: 0.8, y: 0.8)
            let body = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 92, height: 92), xRadius: 22, yRadius: 22)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowBlurRadius = 2.5; shadow.shadowOffset = NSSize(width: 0, height: -1.2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.set()
            NSColor(hex: 0x3b7fd9).setFill(); body.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: NSColor(hex: 0x9dd0ff), ending: NSColor(hex: 0x3b7fd9))!.draw(in: body, angle: 90)
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 92, height: 46), xRadius: 22, yRadius: 22).fill()

            // Photo card, rotated -8° about (50, 52).
            ctx.saveGState()
            ctx.translateBy(x: 50, y: 52); ctx.rotate(by: -8 * .pi / 180); ctx.translateBy(x: -50, y: -52)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 24, y: 26, width: 44, height: 40), xRadius: 6, yRadius: 6).fill()
            NSColor(hex: 0xbfe0ff).setFill()
            NSBezierPath(roundedRect: NSRect(x: 28, y: 30, width: 36, height: 24), xRadius: 3, yRadius: 3).fill()
            NSColor(hex: 0xffd166).setFill()
            NSBezierPath(ovalIn: NSRect(x: 51, y: 33, width: 8, height: 8)).fill()
            let hill = NSBezierPath()
            hill.move(to: NSPoint(x: 28, y: 54)); hill.line(to: NSPoint(x: 39, y: 42)); hill.line(to: NSPoint(x: 48, y: 51))
            hill.line(to: NSPoint(x: 54, y: 46)); hill.line(to: NSPoint(x: 64, y: 54)); hill.close()
            NSColor(hex: 0x5fa36b).setFill(); hill.fill()
            NSColor(hex: 0x9aa9bb).setFill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: 58, width: 22, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            ctx.restoreGState()

            // Name tag, translate(52 52) rotate(12°).
            ctx.saveGState()
            ctx.translateBy(x: 52, y: 52); ctx.rotate(by: 12 * .pi / 180)
            let tag = NSBezierPath()
            tag.move(to: NSPoint(x: 0, y: 6))
            tag.curve(to: NSPoint(x: 6, y: 0), controlPoint1: NSPoint(x: 0, y: 2.7), controlPoint2: NSPoint(x: 2.7, y: 0))
            tag.line(to: NSPoint(x: 26, y: 0)); tag.line(to: NSPoint(x: 38, y: 13)); tag.line(to: NSPoint(x: 26, y: 26))
            tag.line(to: NSPoint(x: 6, y: 26))
            tag.curve(to: NSPoint(x: 0, y: 20), controlPoint1: NSPoint(x: 2.7, y: 26), controlPoint2: NSPoint(x: 0, y: 23.3))
            tag.close()
            NSColor(hex: 0x1d1d1f).setFill(); tag.fill()
            NSColor(hex: 0x9dd0ff).setFill()
            NSBezierPath(ovalIn: NSRect(x: 26.4, y: 10.4, width: 5.2, height: 5.2)).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 8.5, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.white.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 14.5, width: 9, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            ctx.restoreGState()
            return true
        }
    }

    /// Writes an .iconset folder (for `iconutil -c icns`). Used by scripts/make-app.sh.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = pt * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = NSSize(width: px, height: px)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                appIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
                try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}
