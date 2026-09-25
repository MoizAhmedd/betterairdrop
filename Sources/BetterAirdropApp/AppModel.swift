import AppKit
import BetterAirdropCore
import BetterAirdropKit
import Combine

/// The app's state. Everything the menu, windows and notifications show comes from here; the
/// actual work happens in `WatchService` (off the main thread) and the core's Undoer / Planner.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: Config
    @Published private(set) var configError: String?
    @Published private(set) var state: WatchService.State = .stopped
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var recent: [RecentItem] = []
    @Published private(set) var lastUndoableID: String?
    @Published private(set) var lastUndoableCount = 0
    @Published private(set) var stats = Journal.Stats()
    @Published private(set) var busy = false
    @Published private(set) var credential = CredentialInfo()
    @Published var historyVersion = 0
    /// First run: a key was found in the login shell and is waiting for "Use It".
    @Published private(set) var shellKeyOffer = false
    @Published private(set) var shellKeyError: String?
    @Published private(set) var shellKeyChecking = false
    /// Unnamed camera files already in the folder (IMG_4821.HEIC…), for the first-run preview.
    @Published private(set) var backlog: [URL] = []
    private var shellKey: String?

    struct CredentialInfo: Equatable {
        var keychainKey = false
        var environmentKey = false
        var antPath: String?
        var antLoggedIn = false
        var any: Bool { keychainKey || environmentKey || antLoggedIn }
    }

    let journal = Journal()
    let configURL = Config.defaultPath
    private var service: WatchService?
    private var resumeTimer: Timer?
    private let defaults = UserDefaults.standard

    /// Hooks for the notification layer.
    var onBatch: ((Watcher.Batch) -> Void)?
    var onLostAccess: (() -> Void)?

    init() {
        do { config = try Config.load(from: configURL) } catch {
            config = Config()
            configError = "\(error)"
        }
        if let d = defaults.object(forKey: "pausedUntil") as? Date {
            pausedUntil = d > Date() ? d : nil
            if d <= Date() { defaults.removeObject(forKey: "pausedUntil") }
        }
    }

    // MARK: - Derived

    var folder: URL { URL(fileURLWithPath: (config.watchFolder as NSString).expandingTildeInPath).standardizedFileURL }
    var folderIsDownloads: Bool { FolderAccess.isDownloads(folder) }
    var folderName: String { folderIsDownloads ? "Downloads" : folder.lastPathComponent }
    var folderDisplayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.path.hasPrefix(home) ? "~" + folder.path.dropFirst(home.count) : folder.path
    }
    var isPaused: Bool { defaults.bool(forKey: "pausedIndefinitely") || pausedUntil != nil }
    var engine: EngineStatus { EngineStatus.current(config: config, hasCredential: credential.any) }
    var needsAttention: Bool { state == .noAccess }

    /// "● Ready: watching Downloads"
    var statusLine: String {
        switch state {
        case .watching, .stopped: "Ready: watching \(folderName)"
        case .paused: "Paused"
        case .noAccess: "Can't read \(folderName)"
        case .lockedByOther: "Running in Terminal instead"
        }
    }

    /// "Naming with Claude Haiku 4.5 · your key"
    var engineLine: String {
        var s = "Naming with \(engine.name)"
        if engine.name.hasPrefix("Claude") {
            if credential.keychainKey || credential.environmentKey { s += " · your key" } else if credential.antLoggedIn { s += " · ant login" }
        }
        return s
    }

    var showKeyNudge: Bool { KeyOffer.showNudge(hasCredential: credential.any, backend: config.backend, offering: shellKeyOffer) }

    // MARK: - Lifecycle

    func start() {
        refreshCredential()
        rebuildService()
        refreshRecent()
        scheduleResumeTimer()
    }

    /// Builds the planner (which may run `ant` or read the Keychain, so off the main thread) and
    /// restarts the watcher with the current config.
    func rebuildService() {
        service?.stop()
        service = nil
        let config = self.config, folder = self.folder, journal = self.journal
        let paused = isPaused
        DispatchQueue.global(qos: .userInitiated).async {
            let planner = Self.makePlanner(config: config)
            let committer = Committer(config: config, journal: journal)
            committer.backend = planner.namer?.id ?? "none"
            var options = Watcher.Options(folder: folder)
            options.airdropOnly = config.watchAirdropOnly
            let watcher = Watcher(options: options, planner: planner, committer: committer)
            let svc = WatchService(watcher: watcher, monitor: FSEventsFolderMonitor(folder: folder.resolvingSymlinksInPath()))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                watcher.onBatch = { [weak self] b in DispatchQueue.main.async { self?.handle(b) } }
                svc.onStateChange = { [weak self] s in DispatchQueue.main.async { self?.stateChanged(s) } }
                svc.onBusy = { [weak self] b in DispatchQueue.main.async { self?.busy = b } }
                if paused { svc.pause() }
                svc.start()
                self.service = svc
            }
        }
    }

    nonisolated static func makePlanner(config: Config, backend: String? = nil) -> Planner {
        var planner = Planner(config: config)
        planner.namer = (try? Backends.resolve(backend ?? config.backend, config: config)) ?? VisionNamer()
        planner.analyzer = { VisionAnalyzer.analyze($0) }
        return planner
    }

    private func stateChanged(_ s: WatchService.State) {
        let was = state
        state = s
        if s == .noAccess && was != .noAccess { onLostAccess?() }
    }

    private func handle(_ batch: Watcher.Batch) {
        refreshRecent()
        onBatch?(batch)
    }

    /// Re-checks folder access now (menu opened, onboarding saw a grant).
    func recheck() { service?.recheck() }

    // MARK: - Pause

    func pause(_ d: PauseDuration) {
        pausedUntil = d.resumeDate()
        defaults.set(pausedUntil, forKey: "pausedUntil")
        defaults.set(d == .indefinitely, forKey: "pausedIndefinitely")
        service?.pause()
        scheduleResumeTimer()
        objectWillChange.send()
    }

    func resume() {
        pausedUntil = nil
        defaults.removeObject(forKey: "pausedUntil")
        defaults.set(false, forKey: "pausedIndefinitely")
        resumeTimer?.invalidate()
        service?.resume()
        objectWillChange.send()
    }

    /// One timer while paused for a while; nothing at all otherwise.
    private func scheduleResumeTimer() {
        resumeTimer?.invalidate()
        guard let until = pausedUntil else { return }
        let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in Task { @MainActor in self?.resume() } }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        resumeTimer = t
    }

    // MARK: - Recent, stats

    func refreshRecent() {
        let journal = self.journal
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let batches = journal.recentBatches(limit: 30)
            let items = Recent.items(batches, limit: 5)
            let last = Recent.lastUndoable(batches)
            let stats = journal.stats(since: monthStart)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recent = items
                self.lastUndoableID = last?.id
                self.lastUndoableCount = last?.count ?? 0
                self.stats = stats
                self.historyVersion += 1
            }
        }
    }

    func refreshCredential(then: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            var c = CredentialInfo()
            c.keychainKey = Keychain.hasAPIKey()
            c.environmentKey = !(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").isEmpty
            let auth = ClaudeAuth()
            c.antPath = auth.antExecutable
            if c.antPath != nil { c.antLoggedIn = auth.antToken() != nil }
            DispatchQueue.main.async { [weak self] in self?.credential = c; then?() }
        }
    }

    // MARK: - First run: a key from the shell, photos already there

    private static let declinedShellKey = "declinedShellKey"

    /// Homebrew and Finder don't pass `~/.zshrc`'s exports to the app, so ask the login shell
    /// (up to 3 s, off the main thread). The key stays in memory until the user accepts it.
    func lookForShellKey() {
        guard KeyOffer.shouldLookInShell(hasCredential: credential.any, backend: config.backend,
                                         declined: defaults.bool(forKey: Self.declinedShellKey)) else { return }
        DispatchQueue.global(qos: .utility).async {
            let key = ShellKey.read()
            DispatchQueue.main.async { [weak self] in
                guard let self, let key, !self.credential.any else { return }
                self.shellKey = key
                self.shellKeyOffer = true
            }
        }
    }

    /// "Use It": check the key with Anthropic, then keep it in the Keychain.
    func acceptShellKey() {
        guard let key = shellKey, !shellKeyChecking else { return }
        shellKeyChecking = true
        shellKeyError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ClaudeAuth.validate(key: key)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.shellKeyChecking = false
                switch result {
                case .valid:
                    do {
                        try Keychain.storeAPIKey(key)
                        self.defaults.set(String(key.suffix(4)), forKey: "apiKeySuffix")
                        self.defaults.set(Date(), forKey: "apiKeyVerified")
                        self.shellKey = nil
                        self.shellKeyOffer = false
                        self.credentialsChanged()
                    } catch {
                        self.shellKeyError = "Couldn't save it in your Keychain."
                    }
                case .rejected(let why), .unreachable(let why):
                    self.shellKeyError = why
                }
            }
        }
    }

    func declineShellKey() {
        shellKey = nil
        shellKeyOffer = false
        shellKeyError = nil
        defaults.set(true, forKey: Self.declinedShellKey)
    }

    /// Counts unnamed camera files at the top of the folder (no AirDrop tag needed: the preview
    /// renames nothing until the user clicks Rename).
    func scanBacklog(then: ((Int) -> Void)? = nil) {
        let folder = self.folder
        DispatchQueue.global(qos: .utility).async {
            let files = CameraFiles.find(in: folder)
            DispatchQueue.main.async { [weak self] in
                self?.backlog = files
                then?(files.count)
            }
        }
    }

    // MARK: - Undo / redo

    /// Undoes on a background queue. Completion gets the outcomes (refused ones included).
    func undo(_ selection: Undoer.Selection, force: Bool = false, completion: @escaping ([Undoer.Outcome], String?) -> Void) {
        let journal = self.journal
        DispatchQueue.global(qos: .userInitiated).async {
            var u = Undoer(journal: journal)
            u.force = force
            let result: ([Undoer.Outcome], String?)
            do { result = (try u.undo(selection), nil) } catch { result = ([], "\(error)") }
            DispatchQueue.main.async { [weak self] in
                self?.refreshRecent()
                completion(result.0, result.1)
            }
        }
    }

    /// Plans and commits specific files (Redo, Rename Again, the preview sheet's result).
    func commit(_ proposals: [Proposal], completion: @escaping (Watcher.Batch) -> Void) {
        let config = self.config, journal = self.journal
        DispatchQueue.global(qos: .userInitiated).async {
            let committer = Committer(config: config, journal: journal)
            let id = Journal.newBatchID()
            let outcomes = (try? committer.commit(proposals, batch: id)) ?? []
            let batch = Watcher.Batch(id: id, proposals: proposals, outcomes: outcomes)
            DispatchQueue.main.async { [weak self] in
                self?.refreshRecent()
                completion(batch)
            }
        }
    }

    /// Plans files off the main thread (no changes on disk).
    func plan(_ urls: [URL], backend: String? = nil, completion: @escaping ([Proposal]) -> Void) {
        let config = self.config
        DispatchQueue.global(qos: .userInitiated).async {
            let proposals = Self.makePlanner(config: config, backend: backend).plan(urls)
            DispatchQueue.main.async { completion(proposals) }
        }
    }

    /// Redo: name the restored original again.
    func redo(_ item: RecentItem) {
        plan([URL(fileURLWithPath: item.source)]) { [weak self] p in
            self?.commit(p) { self?.onBatch?($0) }
        }
    }

    // MARK: - Config

    func updateConfig(_ change: (inout Config) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        let old = config
        config = c
        do { try c.save(to: configURL); configError = nil } catch { configError = "\(error)" }
        if old.watchFolder != c.watchFolder || old.backend != c.backend || old.claudeModel != c.claudeModel
            || old.claudeInAuto != c.claudeInAuto || old.watchAirdropOnly != c.watchAirdropOnly
            || old.template != c.template || old.kindTemplates != c.kindTemplates || old.convertHEIC != c.convertHEIC
            || old.originals != c.originals || old.placeProvider != c.placeProvider || old.stripGPSFromOutput != c.stripGPSFromOutput {
            rebuildService()
        }
    }

    /// After a key was stored or removed.
    func credentialsChanged() {
        ClaudeAuth.shared.invalidate()
        refreshCredential()
        rebuildService()
    }
}
