@testable import AirnameCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Simulates what AirDrop does to a folder: files appear with `com.apple.quarantine` set to
/// `0081;<hex time>;sharingd;<UUID>` (the exact format seen on real AirDropped files).
enum AirDropSim {
    static func quarantine(agent: String = "sharingd", at date: Date = Date(), flags: String = "0081") -> String {
        String(format: "%@;%08x;%@;%@", flags, Int(date.timeIntervalSince1970), agent, UUID().uuidString)
    }

    static func tag(_ url: URL, agent: String = "sharingd", at date: Date = Date()) {
        try! Xattr.set(url, "com.apple.quarantine", Data(quarantine(agent: agent, at: date).utf8))
    }

    /// Writes `data` in chunks with a pause between them, tagged from the first byte (worst case).
    static func slowWrite(_ data: Data, to url: URL, chunk: Int = 32 * 1024, pause: TimeInterval = 0.04, agent: String = "sharingd") -> Thread {
        FileManager.default.createFile(atPath: url.path, contents: data.prefix(chunk))
        tag(url, agent: agent)
        let t = Thread {
            let h = try! FileHandle(forWritingTo: url)
            h.seekToEndOfFile()
            var off = chunk
            while off < data.count {
                Thread.sleep(forTimeInterval: pause)
                h.write(data.subdata(in: off..<min(off + chunk, data.count)))
                off += chunk
            }
            try? h.close()
        }
        t.start()
        return t
    }

    /// A photo-sized HEIC with noise so it doesn't compress to nothing (a few hundred KB).
    static func bigHEIC(seed: Int, width: Int = 1600, height: Int = 1200) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = UInt64(seed + 1) &* 6364136223846793005
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                ctx.setFillColor(red: CGFloat(rng >> 56) / 255, green: CGFloat((rng >> 48) & 0xff) / 255, blue: CGFloat((rng >> 40) & 0xff) / 255, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, TestImages.properties(.init()) as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

/// Names each photo after its file ("subject for img 0001"), so every target is predictable.
let stemNamer = FakeNamer { ctx in
    let stem = URL(fileURLWithPath: ctx.file).deletingPathExtension().lastPathComponent
    return NameSuggestion(kind: ctx.kind, subject: "subject for \(stem)", confidence: 0.9, backend: "fake")
}

@Suite struct WatcherTests {
    func watcher(_ s: Sandbox, backlog: Bool = false, startedAt: Date = Date()) -> Watcher {
        var planner = s.planner()
        planner.namer = stemNamer
        var o = Watcher.Options(folder: s.downloads)
        o.settleInterval = 0.3
        o.quietWindow = 0.8
        o.pollInterval = 0.05
        o.maxWait = 20
        o.backlog = backlog
        return Watcher(options: o, planner: planner, committer: s.committer(), startedAt: startedAt)
    }

    @Test func chunkedSlowWriteIsOnlyProcessedOnceComplete() throws {
        let s = Sandbox()
        let data = AirDropSim.bigHEIC(seed: 1)
        #expect(data.count > 200_000)
        let w = watcher(s)
        let writer = AirDropSim.slowWrite(data, to: s.file("IMG_7001.HEIC"))
        let batch = try #require(w.runOnce())
        #expect(writer.isFinished)
        #expect(batch.photos == 1 && batch.failed == 0)
        let out = try #require(batch.outcomes.first?.target)
        #expect((out as NSString).lastPathComponent == "2026-09-21_toronto_subject-img-7001.jpg")
        // The journal hashed the complete file, and the JPEG decodes at full size.
        let rec = try #require(s.journal.records().last)
        #expect(rec.sourceSHA1 == Insecure_sha1(data))
        #expect(try PhotoMetadata.read(URL(fileURLWithPath: out)).pixelWidth == 1600)
    }

    @Test func burstOfEightWithLivePhotoIsOneBatch() throws {
        let s = Sandbox()
        // Things that must be ignored: another browser's download, no quarantine at all, an AirDrop
        // from before the watcher started, an orphan video, a partial transfer.
        TestImages.heic(s.file("safari.HEIC"), seed: 50); AirDropSim.tag(s.file("safari.HEIC"), agent: "Safari")
        TestImages.png(s.file("plain.png"), seed: 51)
        TestImages.heic(s.file("IMG_0100.HEIC"), seed: 52); AirDropSim.tag(s.file("IMG_0100.HEIC"), at: Date().addingTimeInterval(-3600))
        try Data("not really a movie".utf8).write(to: s.file("IMG_9999.MOV")); AirDropSim.tag(s.file("IMG_9999.MOV"))
        TestImages.heic(s.file("IMG_0200.HEIC.download"), seed: 53); AirDropSim.tag(s.file("IMG_0200.HEIC.download"))
        let bystanders = s.snapshot()

        let w = watcher(s)
        var batches: [Watcher.Batch] = []
        w.onBatch = { batches.append($0) }
        // Eight photos arriving 60 ms apart; IMG_0003 is a Live Photo (HEIC + MOV).
        TestImages.heic(s.file("IMG_0001.HEIC"), seed: 1); AirDropSim.tag(s.file("IMG_0001.HEIC"))
        let writer = Thread {
            for i in 2...8 {
                Thread.sleep(forTimeInterval: 0.06)
                let u = TestImages.heic(s.file(String(format: "IMG_%04d.HEIC", i)), seed: i)
                AirDropSim.tag(u)
                if i == 3 { try! Data(repeating: 7, count: 4096).write(to: s.file("IMG_0003.MOV")); AirDropSim.tag(s.file("IMG_0003.MOV")) }
            }
        }
        writer.start()
        let batch = try #require(w.runOnce())
        #expect(batches.count == 1, "one notification per batch")
        #expect(batch.photos == 8 && batch.videos == 1 && batch.failed == 0)
        #expect(Watcher.summary(batch) == "Renamed 8 photos (+1 Live Photo video)")

        let listing = s.listing()
        #expect(listing.contains("2026-09-21_toronto_subject-img-0003.jpg"))
        #expect(listing.contains("2026-09-21_toronto_subject-img-0003.mov"), "the MOV follows its still")
        // Bystanders are untouched, byte for byte.
        let after = s.snapshot()
        for (name, data) in bystanders { #expect(after[name] == data, "\(name) must be ignored") }

        // Idempotent: nothing left to do.
        #expect(w.runOnce() == nil)
        #expect(watcher(s).runOnce() == nil, "a fresh watcher doesn't pick up outputs either")

        // Undo restores the originals byte-identically, video included.
        let before = s.snapshot().filter { !$0.key.hasPrefix("2026-") }
        let undone = try s.undoer().undo(.batch(batch.id))
        #expect(undone.allSatisfy { $0.status == .restored })
        #expect(Set(s.listing()) == Set(bystanders.keys).union((1...8).map { String(format: "IMG_%04d.HEIC", $0) }).union(["IMG_0003.MOV"]))
        #expect(s.snapshot().filter { before[$0.key] != nil } == before)
    }

    @Test func backlogPicksUpEarlierAirDrops() throws {
        let s = Sandbox()
        TestImages.heic(s.file("IMG_0100.HEIC"), seed: 1); AirDropSim.tag(s.file("IMG_0100.HEIC"), at: Date().addingTimeInterval(-86400))
        #expect(watcher(s).runOnce() == nil)
        let b = try #require(watcher(s, backlog: true).runOnce())
        #expect(b.photos == 1)
    }

    @Test func quarantineFormatMatchesRealAirDrops() {
        let q = AirDropSim.quarantine()
        #expect(q.range(of: #"^0081;[0-9a-f]{8};sharingd;[0-9A-F-]{36}$"#, options: .regularExpression) != nil)
        #expect(Quarantine(q)?.isAirDrop == true)
    }
}

func Insecure_sha1(_ d: Data) -> String {
    let dir = TestImages.TempDir()
    let u = dir.path("x")
    try! d.write(to: u)
    return try! FileOps.sha1(u)
}
