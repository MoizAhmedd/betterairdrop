@testable import BetterAirdropCore
@testable import BetterAirdropKit
import Foundation
import Testing

@Suite struct ShellKeyTests {
    @Test func picksTheLoginShell() {
        #expect(ShellKey.shell(environment: ["SHELL": "/bin/bash"]) == "/bin/bash")
        #expect(ShellKey.shell(environment: [:]) == "/bin/zsh")
        #expect(ShellKey.shell(environment: ["SHELL": "bash"]) == "/bin/zsh")   // not absolute
        #expect(ShellKey.shell(environment: ["SHELL": "/nope/zsh"]) == "/bin/zsh")
    }

    @Test func runsAnInteractiveLoginShell() {
        let args = ShellKey.arguments
        #expect(args.first == "-ilc")
        #expect(args.last!.contains("\"$ANTHROPIC_API_KEY\""))
    }

    @Test func parsesBetweenTheMarkers() {
        let b = ShellKey.begin, e = ShellKey.end
        #expect(ShellKey.parse("\(b)sk-ant-abc123\(e)") == "sk-ant-abc123")
        // rc files that print a banner, before and after
        #expect(ShellKey.parse("Welcome to fish\nLast login: …\n\(b)sk-ant-xyz\(e)\nbye") == "sk-ant-xyz")
        #expect(ShellKey.parse("\(b)\(e)") == nil)                  // unset
        #expect(ShellKey.parse("\(b)  \(e)") == nil)                // blank
        #expect(ShellKey.parse("\(b)sk-ant a b\(e)") == nil)        // not a key
        #expect(ShellKey.parse("sk-ant-no-markers") == nil)         // the command didn't run
        #expect(ShellKey.parse("\(b)sk-ant-cut-off") == nil)
    }

    @Test func readUsesTheRunnerWithATimeout() {
        var seen: (String, [String], TimeInterval)?
        let key = ShellKey.read(environment: ["SHELL": "/bin/zsh"]) { path, args, timeout in
            seen = (path, args, timeout)
            return "\(ShellKey.begin)sk-ant-from-zshrc\(ShellKey.end)"
        }
        #expect(key == "sk-ant-from-zshrc")
        #expect(seen?.0 == "/bin/zsh")
        #expect(seen?.2 == 3)
        #expect(ShellKey.read(environment: [:]) { _, _, _ in nil } == nil)   // timed out or failed
    }

    @Test func realShellTimesOut() {
        // A shell that never finishes is killed, not waited on.
        let start = Date()
        #expect(ShellKey.run("/bin/sh", ["-c", "sleep 30"], timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(ShellKey.run("/bin/sh", ["-c", "printf hi"], timeout: 5) == "hi")
    }
}

@Suite struct KeyOfferTests {
    @Test func onlyLooksWhenNothingResolves() {
        #expect(KeyOffer.shouldLookInShell(hasCredential: false, backend: "auto", declined: false))
        #expect(KeyOffer.shouldLookInShell(hasCredential: false, backend: "claude", declined: false))
        #expect(!KeyOffer.shouldLookInShell(hasCredential: true, backend: "auto", declined: false))
        #expect(!KeyOffer.shouldLookInShell(hasCredential: false, backend: "vision", declined: false))
        #expect(!KeyOffer.shouldLookInShell(hasCredential: false, backend: "auto", declined: true))
    }

    @Test func nudgeWhenVisionIsTheFallback() {
        #expect(KeyOffer.showNudge(hasCredential: false, backend: "auto", offering: false))
        #expect(!KeyOffer.showNudge(hasCredential: false, backend: "auto", offering: true))   // the offer replaces it
        #expect(!KeyOffer.showNudge(hasCredential: true, backend: "auto", offering: false))
        #expect(!KeyOffer.showNudge(hasCredential: false, backend: "vision", offering: false)) // chose Vision on purpose
    }
}

@Suite struct CameraFilesTests {
    @Test(arguments: ["IMG_4821.HEIC", "IMG_E4821.jpg", "img_0001.png", "IMG_4821 2.HEIC", "IMG_4821(1).JPG",
                      "PXL_20260921_184512345.jpg", "DSC_0042.JPG", "DSC01234.jpg", "_DSC1234.jpg", "DSCF0001.JPG",
                      "DJI_0001.JPG", "GOPR1234.JPG", "20260921_184512.jpg", "MVIMG_20260921_184512.jpg",
                      "IMG_20260921_184512.jpg", "IMG_4821-edited.jpg"])
    func cameraNames(_ name: String) { #expect(CameraFiles.isCameraName(name), "\(name)") }

    @Test(arguments: ["2026-09-21_toronto_walnut-lamp.jpg", "invoice.png", "IMG_4821.mov", "IMG_.jpg", "Screenshot 2026-09-21 at 10.00.00.png",
                      "photo.HEIC", "IMG_4821.pdf", "MYIMG_1234.jpg", "IMG_4821_toronto_lamp.jpg"])
    func notCameraNames(_ name: String) { #expect(!CameraFiles.isCameraName(name), "\(name)") }

    @Test func findsTopLevelNewestFirstWithALimit() throws {
        let t = Temp()
        let fm = FileManager.default
        func touch(_ name: String, _ age: TimeInterval) throws {
            let u = t.url.appendingPathComponent(name)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path)
        }
        try touch("IMG_0001.HEIC", 300)
        try touch("IMG_0002.HEIC", 100)
        try touch("PXL_20260921_184512345.jpg", 200)
        try touch("notes.txt", 50)
        try touch("already_named.jpg", 10)
        try touch("sub/IMG_0003.HEIC", 5)          // not top level
        try touch(".IMG_0004.HEIC", 5)             // hidden
        let all = CameraFiles.find(in: t.url).map(\.lastPathComponent)
        #expect(all == ["IMG_0002.HEIC", "PXL_20260921_184512345.jpg", "IMG_0001.HEIC"])
        #expect(CameraFiles.find(in: t.url, limit: 2).count == 2)
        #expect(CameraFiles.find(in: t.url.appendingPathComponent("missing")).isEmpty)
    }
}

@Suite struct PreviewCostTests {
    @Test func claudeCost() {
        #expect(PreviewCost.text(count: 12, claude: true) == "~$0.02")
        #expect(PreviewCost.text(count: 1, claude: true) == "under $0.01")
        #expect(PreviewCost.text(count: 20, claude: true) == "~$0.04")
        #expect(PreviewCost.text(count: 12, claude: false) == "free, on this Mac")
    }

    @Test func batches() {
        #expect(PreviewCost.batchSize == 20)
    }
}
