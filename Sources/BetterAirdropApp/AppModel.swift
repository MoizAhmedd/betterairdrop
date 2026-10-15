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
    /// Who holds the watch lock while the app stands by (`.lockedByOther`).
    @Published private(set) var lockHolder: LockHolder?
    @Published private(set) var credential = CredentialInfo()
    @Published var historyVersion = 0
    /// First run: a key was found in the login shell and is waiting for "Use It".
    @Published private(set) var shellKeyOffer = false
    @Published private(set) var shellKeyError: String?
    @Published private(set) var shellKeyChecking = false
    /// Unnamed camera files already in the folder (IMG_4821.HEIC…), for the first-run preview.
    @Published private(set) var backlog: [URL] = []
    /// What the app last saw of the folder permission (nil until macOS has answered).
    @Published var folderAccess: Bool?
    /// The notification permission as macOS last reported it (nil until checked).
    @Published var notificationStatus: AppState.Notifications?
    /// A `reportState(probe:)` folder probe is in flight.
    var probingAccess = false
    private var shellKey: String?

    // MARK: Pro
    @Published private(set) var license: License?
    @Published private(set) var proStatus: ProStatus = .free
    /// What hosted naming last heard from the server: names left this month, the last error.
    @Published private(set) var hostedUsage: HostedUsage?
    /// The Pro watchers (screenshots, other folders) by folder path, and what each is doing.
    @Published private(set) var proWatchStates: [String: WatchService.State] = [:]
    /// The folder screenshots are saved to (re-read whenever the watchers are rebuilt).
    @Published private(set) var screenshotFolder = ScreenshotFolder.current()
    /// The one-time "Pro also names screenshots…" row (after the 20th rename).
    @Published private(set) var showProMention = false
    /// A one-line note in the menu after a free user drops a folder.
    @Published var proHint: String?
    private var lifetimeRenames = 0
    private var extraServices: [WatchService] = []
    private var buildGeneration = 0

    struct CredentialInfo: Equatable {
        var storedKey = false
        var environmentKey = false
        var antPath: String?
        var antLoggedIn = false
        var any: Bool { storedKey || environmentKey || antLoggedIn }
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
        license = LicenseStore().read()
        proStatus = ProGate.status(license)
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
    var engine: EngineStatus {
        EngineStatus.current(config: config, hasCredential: credential.any, appleReady: AppleIntelligenceStatus.current.isAvailable,
                             hasLicense: isPro, hostedProblem: isPro ? HostedNamer.currentProblem(key: license?.key) : nil,
                             hostedRemaining: isPro ? hostedUsage?.remaining : nil)
    }
    var needsAttention: Bool { state == .noAccess }

    /// Pro is unlocked (active, or in the grace period after Polar said the key is invalid).
    var isPro: Bool { proStatus.isUnlocked }

    /// Pro with "Name PDFs too" on: watchers, Rename Files…, drops and Services take PDFs too.
    var namesPDFs: Bool { isPro && config.namePDFs }

    /// Settings' paths: `~/…` under the home folder.
    nonisolated static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    nonisolated static func tilde(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// "● Ready: watching Downloads"
    var statusLine: String {
        switch state {
        case .watching: "Ready: watching \(folderName)"
        case .stopped: "Starting…"
        case .paused: "Paused"
        case .noAccess: "Can't read \(folderName)"
        case .lockedByOther: "Standing by: another copy is watching"
        }
    }

    /// "Naming with Claude Haiku 4.5 · your key"
    var engineLine: String {
        var s = "Naming with \(engine.name)"
        if engine.name.hasPrefix("Claude") {
            if credential.storedKey || credential.environmentKey { s += " · your key" } else if credential.antLoggedIn { s += " · ant login" }
        }
        return s
    }

    var showKeyNudge: Bool { KeyOffer.showNudge(hasCredential: credential.any, backend: config.backend, offering: shellKeyOffer) }

    // MARK: - Lifecycle

    func start() {
        // The names-left count from the last run, until this run's first hosted request.
        if let last = AppState.load()?.hosted { HostedNamer.seedUsage(last) }
        hostedUsage = HostedNamer.lastUsage()
        refreshCredential()
        rebuildService()
        refreshRecent()
        scheduleResumeTimer()
        refreshLicense()
    }

    /// Builds the planner (which may run `ant` or read the key file, so off the main thread) and
    /// restarts the watchers with the current config: the AirDrop folder always, plus (Pro) the
    /// screenshot folder and the user's other folders. Only the AirDrop watcher takes the shared
    /// lock that `betterairdrop watch` also uses.
    func rebuildService() {
        service?.stop()
        service = nil
        for s in extraServices { s.stop() }
        extraServices = []
        buildGeneration += 1
        let generation = buildGeneration
        let config = self.config, folder = self.folder, journal = self.journal
        let paused = isPaused, pro = isPro, pdfs = namesPDFs
        DispatchQueue.global(qos: .userInitiated).async {
            var planner = Self.makePlanner(config: config, pdfs: pdfs)
            // Pro: arrivals are filed by kind. Renames started by hand (preview, drops, Services) stay in place.
            if pro { planner.filing = Filing(config: config) }
            let shots = ScreenshotFolder.current()
            let plan = WatchPlan.make(main: folder, mainAirdropOnly: config.watchAirdropOnly,
                                      screenshots: pro && config.watchScreenshots ? shots : nil,
                                      extras: pro ? config.watchExtraFolders.map(Self.expand) : [], pdfs: pdfs)
            let built = plan.entries.enumerated().map { i, e -> (WatchPlan.Entry, Watcher, WatchService) in
                let committer = Committer(config: config, journal: journal)
                committer.backend = planner.namer?.id ?? "none"
                committer.tagging = pro && config.finderTags
                var options = Watcher.Options(folder: e.folder)
                options.intake = e.intake
                options.movies = e.movies
                options.pdfs = e.pdfs
                let watcher = Watcher(options: options, planner: planner, committer: committer)
                let monitor = FSEventsFolderMonitor(folder: e.folder.resolvingSymlinksInPath())
                let svc = i == 0 ? WatchService(watcher: watcher, monitor: monitor) : WatchService(watcher: watcher, monitor: monitor, lockURL: nil)
                return (e, watcher, svc)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.buildGeneration else { return }   // a newer rebuild won
                self.screenshotFolder = shots
                var states: [String: WatchService.State] = [:]
                for (i, (entry, watcher, svc)) in built.enumerated() {
                    watcher.onBatch = { [weak self] b in DispatchQueue.main.async { self?.handle(b) } }
                    svc.onBusy = { [weak self] b in DispatchQueue.main.async { self?.busy = b } }
                    if i == 0 {
                        svc.onStateChange = { [weak self] s in DispatchQueue.main.async { self?.stateChanged(s) } }
                        self.service = svc
                    } else {
                        let path = entry.folder.path
                        states[path] = .stopped
                        svc.onStateChange = { [weak self] s in DispatchQueue.main.async { self?.proWatchStates[path] = s } }
                        self.extraServices.append(svc)
                    }
                    if paused { svc.pause() }
                    svc.start()
                }
                self.proWatchStates = states
            }
        }
    }

    // MARK: - Pro license

    /// Reads the license (the CLI may have changed it) and, at most once a week, re-checks it with
    /// Polar in the background. Turning Pro on or off restarts the watchers.
    func refreshLicense() {
        DispatchQueue.global(qos: .utility).async {
            let client = LicenseClient()
            let stored = client.store.read()
            DispatchQueue.main.async { [weak self] in self?.setLicense(stored) }
            guard let l = stored, ProGate.needsRevalidation(l) else { return }
            client.revalidateIfDue()
            let after = client.store.read()
            DispatchQueue.main.async { [weak self] in self?.setLicense(after) }
        }
    }

    private func setLicense(_ l: License?) {
        let wasPro = isPro
        license = l
        proStatus = ProGate.status(l)
        if isPro != wasPro { rebuildService() }
    }

    /// Settings → Pro → Activate. Completion gets an error message, or nil on success.
    func activateLicense(_ key: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let client = LicenseClient()
            var failure: String?
            do { try client.activate(key: key) } catch { failure = "\(error)" }
            let stored = client.store.read()
            DispatchQueue.main.async { [weak self] in
                self?.setLicense(stored)
                completion(failure)
            }
        }
    }

    func deactivateLicense(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let client = LicenseClient()
            var failure: String?
            do { try client.deactivate() } catch { failure = "\(error)" }
            let stored = client.store.read()
            DispatchQueue.main.async { [weak self] in
                self?.setLicense(stored)
                completion(failure)
            }
        }
    }

    /// The menu opened: the one-time Pro row shows on the first opening after the 20th rename and
    /// is gone from the next one on.
    func panelOpened() {
        refreshLicense()
        proHint = nil
        let key = "proMentionShown"
        if showProMention { showProMention = false; return }
        guard ProMention.shouldShow(renames: lifetimeRenames, isPro: isPro, alreadyShown: defaults.bool(forKey: key)) else { return }
        showProMention = true
        defaults.set(true, forKey: key)
    }

    func dismissProMention() { showProMention = false }

    /// `pdfs`: Pro with "Name PDFs too" on (`namesPDFs`). PDFs then get their own engine
    /// (`Backends.resolveDocuments`): text only, falling back to Apple Intelligence, never Vision.
    nonisolated static func makePlanner(config: Config, backend: String? = nil, pdfs: Bool = false) -> Planner {
        var planner = Planner(config: config)
        planner.namer = (try? Backends.resolve(backend ?? config.backend, config: config, license: LicenseStore())) ?? VisionNamer()
        planner.analyzer = { VisionAnalyzer.analyze($0) }
        if pdfs {
            planner.pdfs = true
            planner.documentNamer = Backends.resolveDocuments(backend ?? config.backend, config: config, license: LicenseStore())
        }
        return planner
    }

    private func stateChanged(_ s: WatchService.State) {
        let was = state
        state = s
        if s == .watching { folderAccess = true } else if s == .noAccess { folderAccess = false }
        if s == .noAccess && was != .noAccess { onLostAccess?() }
        if s == .lockedByOther { refreshLockHolder() } else { lockHolder = nil }
        writeAppState()
    }

    /// True only while the app is actually watching: the switch in the panel shows this.
    var isWatching: Bool { state == .watching && !isPaused }

    func refreshLockHolder() {
        DispatchQueue.global(qos: .userInitiated).async {
            let h = LockHolder.current()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state == .lockedByOther else { return }
                self.lockHolder = h
            }
        }
    }

    /// "Stop It": SIGTERM to the other watcher (only if it's still the holder and a BetterAirdrop
    /// process), then take over. Completion gets false if it's still holding the lock.
    func stopLockHolder(_ holder: LockHolder, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let freed = LockHolder.stop(pid: holder.pid)
            DispatchQueue.main.async { [weak self] in
                self?.recheck()
                if !freed { self?.refreshLockHolder() }
                completion(freed)
            }
        }
    }

    private func handle(_ batch: Watcher.Batch) {
        refreshRecent()
        refreshHostedUsage()
        onBatch?(batch)
    }

    /// Picks up what hosted naming last heard (after a batch or a manual rename) for Settings and
    /// `status --json` (via app-state.json).
    func refreshHostedUsage() {
        let u = HostedNamer.lastUsage()
        guard u != hostedUsage else { return }
        hostedUsage = u
        writeAppState()
    }

    /// Re-checks folder access and the lock now (menu opened, onboarding saw a grant, Retry).
    func recheck() {
        service?.recheck()
        for s in extraServices { s.recheck() }
        if state == .lockedByOther { refreshLockHolder() }
    }

    // MARK: - Pause

    func pause(_ d: PauseDuration) {
        pausedUntil = d.resumeDate()
        defaults.set(pausedUntil, forKey: "pausedUntil")
        defaults.set(d == .indefinitely, forKey: "pausedIndefinitely")
        service?.pause()
        for s in extraServices { s.pause() }
        scheduleResumeTimer()
        objectWillChange.send()
    }

    func resume() {
        pausedUntil = nil
        defaults.removeObject(forKey: "pausedUntil")
        defaults.set(false, forKey: "pausedIndefinitely")
        resumeTimer?.invalidate()
        service?.resume()
        for s in extraServices { s.resume() }
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
        // Only counted while the one-time Pro row could still be shown.
        let countAll = !isPro && !defaults.bool(forKey: "proMentionShown")
        DispatchQueue.global(qos: .userInitiated).async {
            let batches = journal.recentBatches(limit: 30)
            let items = Recent.items(batches, limit: 5)
            let last = Recent.lastUndoable(batches)
            let stats = journal.stats(since: monthStart)
            let lifetime = countAll ? journal.stats(since: .distantPast).photos : 0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lifetimeRenames = lifetime
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
            c.storedKey = CredentialStore().readAPIKey() != nil   // also moves a pre-0.3 Keychain key over, once
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

    /// "Use It": check the key with Anthropic, then keep it (CredentialStore, readable only by this user).
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
                        try CredentialStore().storeAPIKey(key)
                        self.defaults.set(String(key.suffix(4)), forKey: "apiKeySuffix")
                        self.defaults.set(Date(), forKey: "apiKeyVerified")
                        self.shellKey = nil
                        self.shellKeyOffer = false
                        self.credentialsChanged()
                    } catch {
                        self.shellKeyError = "Couldn't save the key."
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
        let config = self.config, journal = self.journal, tagging = isPro && config.finderTags
        DispatchQueue.global(qos: .userInitiated).async {
            let committer = Committer(config: config, journal: journal)
            committer.tagging = tagging
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
        let config = self.config, pdfs = namesPDFs
        DispatchQueue.global(qos: .userInitiated).async {
            let proposals = Self.makePlanner(config: config, backend: backend, pdfs: pdfs).plan(urls)
            DispatchQueue.main.async { [weak self] in self?.refreshHostedUsage(); completion(proposals) }
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
        if old.finderTags != c.finderTags { rebuildService(); return }   // the watchers' committers tag (or not)
        if old.watchFolder != c.watchFolder || old.backend != c.backend || old.claudeModel != c.claudeModel
            || old.claudeInAuto != c.claudeInAuto || old.watchAirdropOnly != c.watchAirdropOnly
            || old.template != c.template || old.kindTemplates != c.kindTemplates || old.convertHEIC != c.convertHEIC
            || old.originals != c.originals || old.placeProvider != c.placeProvider || old.stripGPSFromOutput != c.stripGPSFromOutput
            || old.watchScreenshots != c.watchScreenshots || old.watchExtraFolders != c.watchExtraFolders || old.dateFormat != c.dateFormat
            || old.fileFolders != c.fileFolders || old.fileMonthly != c.fileMonthly || old.namePDFs != c.namePDFs {
            rebuildService()
        }
    }

    /// `betterairdrop setup` changed the config file or the key: pick both up without a restart.
    /// One rebuild, after the key is re-read (a new key can change what `auto` picks): two rebuilds
    /// in a row can leave the first watcher running unreferenced.
    func reloadFromDisk() {
        do {
            config = try Config.load(from: configURL)
            configError = nil
        } catch {
            configError = "\(error)"
        }
        ClaudeAuth.shared.invalidate()
        refreshCredential { [weak self] in self?.rebuildService() }
        refreshLicense()   // `betterairdrop license activate|deactivate` posts the same signal
    }

    /// After a key was stored or removed.
    func credentialsChanged() {
        ClaudeAuth.shared.invalidate()
        refreshCredential()
        rebuildService()
    }
}
