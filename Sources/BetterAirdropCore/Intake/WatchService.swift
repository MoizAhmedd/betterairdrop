import Foundation

/// Runs a `Watcher` in the background of a long-lived process (the menu-bar app): folder events
/// from a `FolderMonitor` → a serial queue → `Watcher.runOnce()` until there's nothing left. With
/// no events nothing runs at all, so the app sits at 0% CPU while idle.
///
/// It also owns the `ProcessLock` (so `betterairdrop watch --foreground` steps aside while the app
/// watches, and gets the lock back while the app is paused), and re-checks folder access on every
/// event so a revoked Downloads permission is noticed at the next AirDrop.
public final class WatchService: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case watching
        case paused
        /// The folder can't be listed (the Downloads permission is missing or was revoked).
        case noAccess
        /// Another watcher (the CLI in a Terminal window) holds the lock.
        case lockedByOther
    }

    public let watcher: Watcher
    public let queue = DispatchQueue(label: "dev.betterairdrop.watch", qos: .utility)
    let monitor: any FolderMonitor
    let lockURL: URL?
    /// True if the folder can be listed. The default lists it (the check that trips over TCC).
    public var accessCheck: @Sendable (URL) -> Bool = { FolderAccess.canList($0) }
    /// Called on the service's queue.
    public var onStateChange: (State) -> Void = { _ in }
    /// Called on the service's queue before a batch is processed, e.g. to show a spinner.
    public var onBusy: (Bool) -> Void = { _ in }

    private let stateLock = NSLock()
    private var _state = State.stopped
    public var state: State { stateLock.lock(); defer { stateLock.unlock() }; return _state }
    private var lock: ProcessLock?
    private var userPaused = false
    private var running = false

    /// `lockURL` nil = don't take the shared lock (tests that run several services).
    public init(watcher: Watcher, monitor: any FolderMonitor, lockURL: URL? = ProcessLock.defaultURL) {
        self.watcher = watcher
        self.monitor = monitor
        self.lockURL = lockURL
    }

    public var folder: URL { watcher.options.folder }

    public func start() {
        queue.async { [self] in
            running = true
            monitor.start(queue: queue) { [weak self] in self?.drain() }
            if userPaused { set(.paused) } else { activate() }
        }
    }

    public func stop() {
        watcher.pause()
        queue.async { [self] in
            running = false
            monitor.stop()
            lock = nil
            set(.stopped)
        }
    }

    /// Stops renaming immediately (a batch in progress finishes its current step) and frees the lock.
    public func pause() {
        watcher.pause()
        queue.async { [self] in
            userPaused = true
            lock = nil
            set(.paused)
        }
    }

    /// Resumes. Files that arrived while paused are left alone.
    public func resume() {
        queue.async { [self] in
            userPaused = false
            watcher.resume()
            activate()
        }
    }

    /// Re-checks access and the lock, e.g. when the menu opens or after the user granted access.
    public func recheck() {
        queue.async { [self] in
            guard running, !userPaused else { return }
            activate()
        }
    }

    /// Runs one pass now (used at start-up and by tests).
    public func poke() { queue.async { [self] in drain() } }

    private func activate() {
        if lock == nil, let lockURL {
            lock = ProcessLock(lockURL, owner: .init(kind: .app, folder: folder.path))
            if lock == nil { set(.lockedByOther); return }
        }
        drain()
    }

    private func drain() {
        guard running, !userPaused else { return }
        if lock == nil && lockURL != nil { activate(); if lock == nil { return } }
        guard accessCheck(folder) else { set(.noAccess); return }
        set(.watching)
        while !watcher.isPaused {
            onBusy(true)
            let batch = watcher.runOnce()
            onBusy(false)
            if batch == nil { break }
        }
    }

    private func set(_ s: State) {
        stateLock.lock()
        let changed = _state != s
        _state = s
        stateLock.unlock()
        if changed { onStateChange(s) }
    }
}

/// Folder permission checks. Listing a TCC-protected folder the first time shows the system prompt;
/// afterwards it simply fails with EPERM until the user grants access.
public enum FolderAccess {
    public static func canList(_ folder: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    /// True for `~/Downloads` itself (the one folder whose access the onboarding asks for).
    public static func isDownloads(_ folder: URL) -> Bool {
        folder.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").standardizedFileURL.path
    }
}
