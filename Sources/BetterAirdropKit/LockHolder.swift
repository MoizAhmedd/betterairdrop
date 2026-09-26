import BetterAirdropCore
import Darwin
import Foundation

/// Who holds the watch lock when the app has to stand by: another copy of the app, or
/// `betterairdrop watch` in a Terminal. Read from the lock's owner record plus the process table.
public struct LockHolder: Equatable, Sendable {
    public var pid: Int32
    /// The executable's name, e.g. "betterairdrop" or "BetterAirdrop"; nil if it can't be read.
    public var processName: String?
    public var kind: ProcessLock.Owner.Kind

    public init(pid: Int32, processName: String?, kind: ProcessLock.Owner.Kind) {
        self.pid = pid; self.processName = processName; self.kind = kind
    }

    /// The current holder, or nil if the lock is free.
    public static func current(_ lockURL: URL = ProcessLock.defaultURL) -> LockHolder? {
        guard let o = ProcessLock.holder(lockURL) else { return nil }
        return LockHolder(pid: o.pid, processName: o.pid > 0 ? processName(o.pid) : nil, kind: o.kind)
    }

    /// "betterairdrop, PID 4242"; just the PID if the name is unknown; nil if neither is known.
    public var label: String? {
        guard pid > 0 else { return nil }
        return processName.map { "\($0), PID \(pid)" } ?? "PID \(pid)"
    }

    /// Only a BetterAirdrop process (the app or the CLI) that isn't this one is offered "Stop It".
    public var canStop: Bool { pid > 0 && pid != getpid() && Self.isBetterAirdrop(processName) }

    static func isBetterAirdrop(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        return n == "betterairdrop"
    }

    /// The panel's banner, e.g. "Another copy of BetterAirdrop is watching Downloads (betterairdrop, PID 4242)."
    public func banner(folderName: String) -> String {
        "Another copy of BetterAirdrop is watching \(folderName)" + (label.map { " (\($0))." } ?? ".")
    }

    public static func processName(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let name = String(cString: buf)
        return name.isEmpty ? nil : name
    }

    /// Sends SIGTERM to the holder if it's still `pid` and still a BetterAirdrop process, then
    /// waits up to `timeout` for the lock to be released. True if the lock is free afterwards.
    public static func stop(pid: Int32, lockURL: URL = ProcessLock.defaultURL, timeout: TimeInterval = 3) -> Bool {
        guard let h = current(lockURL), h.pid == pid, h.canStop else { return current(lockURL) == nil }
        guard kill(pid, SIGTERM) == 0 else { return false }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ProcessLock.holder(lockURL) == nil { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return ProcessLock.holder(lockURL) == nil
    }
}
