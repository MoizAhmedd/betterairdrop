@testable import BetterAirdropCore
import Foundation
import Testing

/// Waits up to `timeout` for `cond`, polling.
func eventually(_ timeout: TimeInterval = 10, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.05) }
    return cond()
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: T
    init(_ v: T) { _v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return _v } set { lock.lock(); _v = newValue; lock.unlock() } }
}

@Suite(.serialized) struct WatchServiceTests {
    func service(_ s: Sandbox, monitor: any FolderMonitor = ManualFolderMonitor(), lock: URL? = nil) -> WatchService {
        var planner = s.planner()
        planner.namer = stemNamer
        var o = Watcher.Options(folder: s.downloads)
        o.settleInterval = 0.2; o.quietWindow = 0.4; o.pollInterval = 0.05
        return WatchService(watcher: Watcher(options: o, planner: planner, committer: s.committer()), monitor: monitor, lockURL: lock)
    }

    @Test func eventRenamesAndPauseIgnoresArrivals() throws {
        let s = Sandbox()
        let m = ManualFolderMonitor()
        let svc = service(s, monitor: m)
        let batches = Box<[Watcher.Batch]>([])
        svc.watcher.onBatch = { b in batches.value.append(b) }
        svc.start()
        #expect(eventually { svc.state == .watching || m.isRunning })
        TestImages.heic(s.file("IMG_0001.HEIC"), seed: 1); AirDropSim.tag(s.file("IMG_0001.HEIC"))
        m.fire()
        #expect(eventually { batches.value.count == 1 })
        #expect(svc.state == .watching)

        // Paused: an arrival is ignored, and still ignored after resuming.
        svc.pause()
        #expect(eventually { svc.state == .paused })
        TestImages.heic(s.file("IMG_0002.HEIC"), seed: 2); AirDropSim.tag(s.file("IMG_0002.HEIC"), at: Date().addingTimeInterval(-5))
        m.fire()
        svc.resume()
        m.fire()
        #expect(eventually { svc.state == .watching })
        Thread.sleep(forTimeInterval: 1)
        #expect(batches.value.count == 1)
        #expect(s.listing().contains("IMG_0002.HEIC"))

        // A new arrival after resuming is renamed.
        TestImages.heic(s.file("IMG_0003.HEIC"), seed: 3); AirDropSim.tag(s.file("IMG_0003.HEIC"))
        m.fire()
        #expect(eventually { batches.value.count == 2 })
        svc.stop()
    }

    @Test func lostAccessIsReportedAndRecovers() throws {
        let s = Sandbox()
        let m = ManualFolderMonitor()
        let svc = service(s, monitor: m)
        let allowed = Box(false)
        svc.accessCheck = { _ in allowed.value }
        let states = Box<[WatchService.State]>([])
        svc.onStateChange = { states.value.append($0) }
        svc.start()
        #expect(eventually { svc.state == .noAccess })
        allowed.value = true
        svc.recheck()
        #expect(eventually { svc.state == .watching })
        #expect(states.value == [.noAccess, .watching])
        svc.stop()
    }

    @Test func appHoldsTheLockAndTheCLICanTellWhoItIs() throws {
        let s = Sandbox()
        let lockURL = s.root.path("state/lock")
        let svc = service(s, lock: lockURL)
        svc.start()
        #expect(eventually { svc.state == .watching })
        #expect(ProcessLock(lockURL, owner: .init(kind: .cli, folder: "/x")) == nil)
        let holder = try #require(ProcessLock.holder(lockURL))
        #expect(holder.kind == .app && holder.pid == getpid() && holder.folder == s.downloads.path)
        // Pausing frees the lock for the CLI; resuming while the CLI holds it reports that.
        svc.pause()
        #expect(eventually { svc.state == .paused })
        var cli = ProcessLock(lockURL, owner: .init(kind: .cli, folder: "/x"))
        #expect(cli != nil)
        svc.resume()
        #expect(eventually { svc.state == .lockedByOther })
        cli = nil
        svc.recheck()
        #expect(eventually { svc.state == .watching })
        svc.stop()
        #expect(eventually { ProcessLock.holder(lockURL) == nil })
    }

    @Test func fsEventsMonitorFiresForANewFile() throws {
        let dir = TestImages.TempDir()
        let m = FSEventsFolderMonitor(folder: dir.url.resolvingSymlinksInPath(), latency: 0.1)
        let fired = Box(0)
        m.start(queue: DispatchQueue(label: "t")) { fired.value += 1 }
        Thread.sleep(forTimeInterval: 0.3)
        try Data("x".utf8).write(to: dir.path("a.txt"))
        #expect(eventually(5) { fired.value > 0 })
        m.stop()
    }
}

@Suite struct JournalSummaryTests {
    @Test func recentBatchesAndMonthlyStats() throws {
        let s = Sandbox()
        func rec(_ batch: String, _ src: String, cost: Double?) -> JournalRecord {
            JournalRecord(op: .begin, batch: batch, action: .rename, source: "/d/\(src)", target: "/d/n-\(src)",
                          sourceSHA1: "a", outputSHA1: "a", backend: cost == nil ? "vision" : "claude", costUSD: cost)
        }
        for (b, f, c) in [("b1", "1.heic", 0.002), ("b1", "1.mov", nil), ("b2", "2.heic", 0.001), ("b2", "3.heic", nil)] as [(String, String, Double?)] {
            let r = rec(b, f, cost: c)
            try s.journal.append(r)
            try s.journal.append(r.with(.done))
        }
        try s.journal.append(rec("b2", "3.heic", cost: nil).with(.undo))
        let batches = s.journal.recentBatches(limit: 5)
        #expect(batches.map(\.id) == ["b2", "b1"])
        #expect(batches[0].undoable.count == 1)
        #expect(batches[1].backend == "claude")
        #expect(abs(batches[1].costUSD - 0.002) < 1e-9)
        let st = s.journal.stats(since: Date().addingTimeInterval(-60))
        #expect(st.photos == 2)       // 1.heic and 2.heic; the MOV and the undone 3.heic don't count
        #expect(abs(st.costUSD - 0.003) < 1e-9)
        #expect(s.journal.stats(since: Date().addingTimeInterval(60)) == Journal.Stats())
    }

    @Test func committerRecordsCost() throws {
        let s = Sandbox()
        TestImages.png(s.file("IMG_1.png"))
        var planner = s.planner()
        planner.namer = FakeNamer { ctx in
            var n = NameSuggestion(kind: .photo, subject: "a lamp", confidence: 0.9, backend: "claude")
            n.usage = TokenUsage(model: "m", inputTokens: 1_000_000, outputTokens: 0)
            return n
        }
        _ = try s.committer().commit(planner.plan([s.file("IMG_1.png")]))
        #expect(s.journal.entries().first?.begin.costUSD == 1.0)
    }
}
