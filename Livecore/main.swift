import AppKit
import AVFoundation
import IOKit.pwr_mgt
import ServiceManagement

enum VideoScaleType: String, CaseIterable {
    case fill
    case fit
    case stretch
    case center

    var title: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        case .center: return "Center"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        case .fit, .center: return .resizeAspect
        }
    }
}

final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let videoBookmark = "videoBookmark"
        static let scaleType = "scaleType"
        static let desktopEnabled = "desktopEnabled"
        static let keepScreenAwakeOnLock = "keepScreenAwakeOnLock"
        static let installationIdentity = "installationIdentity"
        static let installationCleanupPending = "installationCleanupPending"
    }

    private let defaults = UserDefaults.standard

    var scaleType: VideoScaleType {
        get { VideoScaleType(rawValue: defaults.string(forKey: Key.scaleType) ?? "") ?? .fill }
        set { defaults.set(newValue.rawValue, forKey: Key.scaleType) }
    }

    var desktopEnabled: Bool {
        get { defaults.bool(forKey: Key.desktopEnabled) }
        set { defaults.set(newValue, forKey: Key.desktopEnabled) }
    }

    var keepScreenAwakeOnLock: Bool {
        get { defaults.bool(forKey: Key.keepScreenAwakeOnLock) }
        set { defaults.set(newValue, forKey: Key.keepScreenAwakeOnLock) }
    }

    func saveVideoURL(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Key.videoBookmark)
    }

    func resolveVideoURL() throws -> URL? {
        guard let bookmark = defaults.data(forKey: Key.videoBookmark) else {
            return nil
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            try saveVideoURL(url)
        }
        return url
    }

    /// App deletion does not remove UserDefaults. Tie wallpaper ownership to
    /// the concrete executable instance so replacing/reinstalling the bundle
    /// cannot silently restart a video selected by an earlier installation.
    func prepareForCurrentInstallation() -> Bool {
        let identity = currentInstallationIdentity()
        if defaults.string(forKey: Key.installationIdentity) != identity {
            defaults.set(identity, forKey: Key.installationIdentity)
            defaults.set(false, forKey: Key.desktopEnabled)
            defaults.set(false, forKey: Key.keepScreenAwakeOnLock)
            defaults.removeObject(forKey: Key.videoBookmark)
            defaults.set(true, forKey: Key.installationCleanupPending)
        }
        return defaults.bool(forKey: Key.installationCleanupPending)
    }

    func completeInstallationCleanup() {
        defaults.set(false, forKey: Key.installationCleanupPending)
    }

    private func currentInstallationIdentity() -> String {
        guard let executable = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path)
        else {
            return Bundle.main.bundleURL.standardizedFileURL.path
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(device):\(inode):\(created):\(modified):\(size)"
    }
}

final class LoginItemManager {
    static let shared = LoginItemManager()
    private static let legacyDefaultsDomains = ["com.berkegulacar.Livecore"]

    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled, !isEnabled {
            try SMAppService.mainApp.register()
        } else if !enabled {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            case .notRegistered, .notFound:
                break
            @unknown default:
                try SMAppService.mainApp.unregister()
            }
        }
    }

    /// A replacement app is a fresh installation. The public API can remove
    /// this main app's registration; legacy bundle IDs have no targeted
    /// unregister API, but their persisted app preferences can still be purged.
    func resetForNewInstallation() {
        try? setEnabled(false)
        for identifier in Self.legacyDefaultsDomains {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
    }
}

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One borderless window pinned just above the Desktop picture, looping a video
/// on a single screen.
final class WallpaperSurface {
    private let window: WallpaperWindow
    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private let playerItem: AVPlayerItem
    private let screen: NSScreen
    private let scaleType: VideoScaleType

    private var endObserver: NSObjectProtocol?
    private var presentationObserver: NSKeyValueObservation?

    init(screen: NSScreen, videoURL: URL, scaleType: VideoScaleType) {
        self.screen = screen
        self.scaleType = scaleType

        playerItem = AVPlayerItem(url: videoURL)
        player = AVPlayer(playerItem: playerItem)
        playerLayer = AVPlayerLayer(player: player)
        window = WallpaperWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        configureWindow()
        configurePlayer()
        installObservers()
        layout()
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        presentationObserver?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func configureWindow() {
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView.wantsLayer = true
        contentView.layer = CALayer()
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView

        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.needsDisplayOnBoundsChange = true
        contentView.layer?.addSublayer(playerLayer)
    }

    private func configurePlayer() {
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    private func installObservers() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                if finished {
                    self.player.playImmediately(atRate: 1)
                }
            }
        }

        presentationObserver = playerItem.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.layout() }
        }
    }

    func show() {
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        player.playImmediately(atRate: 1)
    }

    func pause() { player.pause() }

    func resume() { player.playImmediately(atRate: 1) }

    func close() {
        player.pause()
        window.orderOut(nil)
        window.close()
    }

    func layout() {
        guard let bounds = window.contentView?.bounds else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.videoGravity = scaleType.videoGravity
        let videoSize = playerItem.presentationSize
        if scaleType == .center, videoSize.width > 0, videoSize.height > 0 {
            playerLayer.frame = NSRect(
                x: (bounds.width - videoSize.width) / 2,
                y: (bounds.height - videoSize.height) / 2,
                width: videoSize.width,
                height: videoSize.height
            ).integral
        } else {
            playerLayer.frame = bounds
        }
        CATransaction.commit()
    }
}

@MainActor
final class WallpaperEngine {
    static let shared = WallpaperEngine()

    private var surfaces: [WallpaperSurface] = []
    private var activeURL: URL?
    private var securityScopedURL: URL?
    private var activeScaleType: VideoScaleType = .fill
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    var isActive: Bool { !surfaces.isEmpty }

    private init() {
        // Screen and session notifications come from the workspace center, not
        // the default one; observing them on `.default` never fires.
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSApplication.didChangeScreenParametersNotification, on: .default) { $0.rebuildForCurrentScreens() }
        observe(NSWorkspace.screensDidSleepNotification, on: workspace) { $0.pause() }
        observe(NSWorkspace.screensDidWakeNotification, on: workspace) { $0.resume() }
        observe(NSWorkspace.sessionDidResignActiveNotification, on: workspace) { $0.pause() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, on: workspace) { $0.resume() }
    }

    deinit {
        observers.forEach { $0.center.removeObserver($0.token) }
    }

    private func observe(
        _ name: NSNotification.Name,
        on center: NotificationCenter,
        handler: @escaping @MainActor (WallpaperEngine) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in handler(WallpaperEngine.shared) }
        }
        observers.append((center, token))
    }

    func start(videoURL: URL, scaleType: VideoScaleType) throws {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw NSError(
                domain: "Livecore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The selected video file could not be found."]
            )
        }
        stop()
        securityScopedURL = videoURL.startAccessingSecurityScopedResource() ? videoURL : nil
        activeURL = videoURL
        activeScaleType = scaleType
        rebuildForCurrentScreens()
    }

    func stop() {
        surfaces.forEach { $0.close() }
        surfaces.removeAll()
        activeURL = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    /// Re-lays out a running Desktop playback for a new scale. Does nothing
    /// when the Desktop is not active, so the setting simply takes effect the
    /// next time playback starts.
    func setScale(_ scale: VideoScaleType) {
        guard activeScaleType != scale else { return }
        activeScaleType = scale
        rebuildForCurrentScreens()
    }

    func pause() { surfaces.forEach { $0.pause() } }

    func resume() {
        guard activeURL != nil else {
            return
        }
        surfaces.forEach { $0.resume() }
    }

    func rebuildForCurrentScreens() {
        guard let activeURL else {
            return
        }
        surfaces.forEach { $0.close() }
        surfaces = NSScreen.screens.map {
            WallpaperSurface(screen: $0, videoURL: activeURL, scaleType: activeScaleType)
        }
        surfaces.forEach { $0.show() }
    }
}

@MainActor
final class PowerAssertionManager {
    static let shared = PowerAssertionManager()

    private var assertionID: IOPMAssertionID = 0
    private var isAsserting = false

    func updateAssertionState() {
        if AppSettings.shared.keepScreenAwakeOnLock {
            guard !isAsserting else { return }
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Livecore Keep Screen Awake on Lock" as CFString,
                &assertionID
            )
            isAsserting = result == kIOReturnSuccess
        } else {
            guard isAsserting else { return }
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isAsserting = false
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var dashboard: DashboardWindowController?
    private var statusItem: NSStatusItem?
    private var keepAwakeMenuItem: NSMenuItem?
    private var scaleMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let needsInstallationCleanup = AppSettings.shared.prepareForCurrentInstallation()
        if needsInstallationCleanup {
            LoginItemManager.shared.resetForNewInstallation()
        }
        NSApp.setActivationPolicy(.accessory)
        PowerAssertionManager.shared.updateAssertionState()
        installStatusMenu()

        if needsInstallationCleanup {
            Task {
                do {
                    try await WallpaperStoreManager.shared.resetForNewInstallation()
                    AppSettings.shared.completeInstallationCleanup()
                } catch {
                    NSApp.presentError(error)
                }
                showSettings()
            }
            return
        }

        do {
            let videoURL = try AppSettings.shared.resolveVideoURL()
            if AppSettings.shared.desktopEnabled, let videoURL {
                try WallpaperEngine.shared.start(
                    videoURL: videoURL,
                    scaleType: AppSettings.shared.scaleType
                )
            }
            if videoURL == nil {
                showSettings()
            }
        } catch {
            showSettings()
            NSApp.presentError(error)
        }
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "play.rectangle.on.rectangle",
            accessibilityDescription: "Livecore"
        )

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Open App", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Play on Desktop", action: #selector(playSavedVideo), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop Desktop Playback", action: #selector(stopPlayback), keyEquivalent: ""))

        let scaleMenu = NSMenu()
        for (index, scale) in VideoScaleType.allCases.enumerated() {
            let scaleItem = NSMenuItem(title: scale.title, action: #selector(changeScale(_:)), keyEquivalent: "")
            scaleItem.tag = index
            scaleItem.state = scale == AppSettings.shared.scaleType ? .on : .off
            scaleMenu.addItem(scaleItem)
        }
        scaleMenuItems = scaleMenu.items
        let scaleRoot = NSMenuItem(title: "Type & Scale", action: nil, keyEquivalent: "")
        scaleRoot.submenu = scaleMenu
        menu.addItem(scaleRoot)

        let awakeItem = NSMenuItem(
            title: "Keep Screen Awake on Lock",
            action: #selector(toggleKeepScreenAwake),
            keyEquivalent: ""
        )
        awakeItem.state = AppSettings.shared.keepScreenAwakeOnLock ? .on : .off
        menu.addItem(awakeItem)
        keepAwakeMenuItem = awakeItem

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Livecore", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        scaleMenu.items.forEach { $0.target = self }

        item.menu = menu
        statusItem = item
    }

    /// The dashboard writes the same settings, so the menu re-reads them every
    /// time it opens instead of trying to stay in sync from the other side.
    func menuWillOpen(_ menu: NSMenu) {
        updateKeepAwakeMenuItemState()
        for item in scaleMenuItems {
            item.state = VideoScaleType.allCases[item.tag] == AppSettings.shared.scaleType ? .on : .off
        }
    }

    func updateKeepAwakeMenuItemState() {
        keepAwakeMenuItem?.state = AppSettings.shared.keepScreenAwakeOnLock ? .on : .off
    }

    @objc private func toggleKeepScreenAwake() {
        AppSettings.shared.keepScreenAwakeOnLock.toggle()
        PowerAssertionManager.shared.updateAssertionState()
        updateKeepAwakeMenuItemState()
        dashboard?.updateKeepAwakeSwitchState()
    }

    @objc private func showSettings() {
        if dashboard == nil {
            dashboard = DashboardWindowController()
        }
        dashboard?.showWindow(nil)
        dashboard?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func playSavedVideo() {
        do {
            guard let url = try AppSettings.shared.resolveVideoURL() else {
                showSettings()
                return
            }
            try WallpaperEngine.shared.start(videoURL: url, scaleType: AppSettings.shared.scaleType)
            AppSettings.shared.desktopEnabled = true
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc private func stopPlayback() {
        WallpaperEngine.shared.stop()
        AppSettings.shared.desktopEnabled = false
    }

    @objc private func changeScale(_ sender: NSMenuItem) {
        guard VideoScaleType.allCases.indices.contains(sender.tag) else {
            return
        }
        let scale = VideoScaleType.allCases[sender.tag]
        AppSettings.shared.scaleType = scale
        WallpaperEngine.shared.setScale(scale)
        dashboard?.updateScaleControlState()
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.run()
}
