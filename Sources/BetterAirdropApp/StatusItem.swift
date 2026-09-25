import AppKit
import Combine
import SwiftUI

/// The menu-bar icon and its panel. This is an AppKit `NSStatusItem` rather than SwiftUI's
/// `MenuBarExtra` because the icon has to accept dropped files, show an attention dot and open its
/// panel programmatically, none of which `MenuBarExtra` supports. The panel itself is SwiftUI.
@MainActor
final class StatusItemController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model: AppModel
    let actions: PanelActions
    private var panel: MenuPanel?
    private var dot: NSView?
    private var subscriptions: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?

    init(model: AppModel, actions: PanelActions) {
        self.model = model
        self.actions = actions
        super.init()
        guard let button = item.button else { return }
        button.image = Art.menuBarGlyph()
        button.imagePosition = .imageOnly
        button.toolTip = "BetterAirdrop"
        let drop = DropTarget(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onClick = { [weak self] in self?.toggle() }
        drop.onDrop = { [weak self] urls in self?.actions.renameFiles(urls) }
        button.addSubview(drop)

        let d = NSView(frame: NSRect(x: button.bounds.width - 9, y: button.bounds.height - 8, width: 6, height: 6))
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor.systemOrange.cgColor
        d.layer?.cornerRadius = 3
        d.autoresizingMask = [.minXMargin, .minYMargin]
        d.isHidden = true
        button.addSubview(d)
        dot = d

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &subscriptions)
        updateIcon()
    }

    /// Solid while watching, dimmed and slashed while paused, an orange dot when something needs attention.
    func updateIcon() {
        guard let button = item.button else { return }
        let paused = model.isPaused || model.state == .paused
        button.image = Art.menuBarGlyph(paused: paused)
        button.appearsDisabled = paused
        dot?.isHidden = !model.needsAttention
        if isOpen { panel?.sizeToContent() }
        item.isVisible = UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true
    }

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        model.refreshRecent()
        model.recheck()
        let p = panel ?? MenuPanel(root: PanelView(model: model, actions: actions))
        panel = p
        p.onClose = { [weak self] in self?.didClose() }
        p.sizeToContent()
        let b = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = b.midX - p.frame.width / 2
        if let vf = screen?.visibleFrame { x = min(max(x, vf.minX + 8), vf.maxX - p.frame.width - 8) }
        p.setFrameTopLeftPoint(NSPoint(x: x, y: b.minY - 5))
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        button.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        panel?.orderOut(nil)
        didClose()
    }

    private func didClose() {
        item.button?.highlight(false)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    /// The status item's own window (for snapshots).
    var buttonWindow: NSWindow? { item.button?.window }
    var panelWindow: NSWindow? { panel }
}

/// Covers the status button: forwards clicks, accepts dropped files.
final class DropTarget: NSView {
    var onClick: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onClick() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        (superview as? NSButton)?.highlight(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { (superview as? NSButton)?.highlight(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (superview as? NSButton)?.highlight(false)
        let u = urls(sender)
        guard !u.isEmpty else { return false }
        onDrop(u)
        return true
    }
}

/// A borderless, translucent panel under the menu-bar icon, like a `MenuBarExtra(.window)`.
final class MenuPanel: NSPanel {
    var onClose: () -> Void = {}
    private let hosting: NSHostingView<AnyView>

    init<V: View>(root: V) {
        hosting = NSHostingView(rootView: AnyView(root))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    /// Fits the height to the SwiftUI content, keeping the top edge where it is.
    func sizeToContent() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let top = frame.maxY
        setContentSize(NSSize(width: 340, height: size.height))
        if isVisible { setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top)) }
    }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
        onClose()
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        onClose()
    }
}
