import CoreServices
import Foundation

/// Tells its owner when something changes in a folder. The menu-bar app uses FSEvents, so it costs
/// nothing while idle; tests use `ManualFolderMonitor`.
public protocol FolderMonitor: AnyObject {
    /// Starts delivering change callbacks on `queue`. Calling it twice restarts the stream.
    func start(queue: DispatchQueue, onChange: @escaping () -> Void)
    func stop()
}

/// `FSEventStream` on one folder with file-level events and 0.5 s latency (coalesced by the kernel,
/// no polling). Only the top level matters to the Watcher, so subfolder events just trigger a
/// cheap rescan.
public final class FSEventsFolderMonitor: FolderMonitor {
    public let folder: URL
    public let latency: TimeInterval
    private var stream: FSEventStreamRef?
    private var handler: (() -> Void)?

    public init(folder: URL, latency: TimeInterval = 0.5) {
        self.folder = folder
        self.latency = latency
    }

    deinit { stop() }

    public func start(queue: DispatchQueue, onChange: @escaping () -> Void) {
        stop()
        handler = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSEventsFolderMonitor>.fromOpaque(info).takeUnretainedValue().handler?()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}

/// A monitor that fires only when told to (tests).
public final class ManualFolderMonitor: FolderMonitor {
    private var queue: DispatchQueue?
    private var handler: (() -> Void)?
    public private(set) var isRunning = false
    public init() {}
    public func start(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue; handler = onChange; isRunning = true
    }
    public func stop() { isRunning = false }
    public func fire() {
        guard isRunning, let queue, let handler else { return }
        queue.async(execute: handler)
    }
}
