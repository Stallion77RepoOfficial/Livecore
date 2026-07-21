import AppKit
import AVFoundation
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
}

final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let videoBookmark = "videoBookmark"
        static let scaleType = "scaleType"
        static let startAutomatically = "startAutomatically"
        static let pauseOnBattery = "pauseOnBattery"
        static let desktopEnabled = "desktopEnabled"
        static let lockScreenEnabled = "lockScreenEnabled"
    }

    private let defaults = UserDefaults.standard

    var scaleType: VideoScaleType {
        get {
            VideoScaleType(rawValue: defaults.string(forKey: Key.scaleType) ?? "") ?? .fill
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.scaleType)
        }
    }

    var startAutomatically: Bool {
        get { defaults.object(forKey: Key.startAutomatically) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.startAutomatically) }
    }

    var pauseOnBattery: Bool {
        get { defaults.bool(forKey: Key.pauseOnBattery) }
        set { defaults.set(newValue, forKey: Key.pauseOnBattery) }
    }

    var desktopEnabled: Bool {
        get { defaults.bool(forKey: Key.desktopEnabled) }
        set { defaults.set(newValue, forKey: Key.desktopEnabled) }
    }

    var lockScreenEnabled: Bool {
        get { defaults.bool(forKey: Key.lockScreenEnabled) }
        set { defaults.set(newValue, forKey: Key.lockScreenEnabled) }
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

    func clearVideo() {
        defaults.removeObject(forKey: Key.videoBookmark)
    }
}

@available(macOS 13.0, *)
final class LoginItemManager {
    static let shared = LoginItemManager()

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WallpaperSurface {
    let window: WallpaperWindow
    let player: AVPlayer
    let playerLayer: AVPlayerLayer
    let playerItem: AVPlayerItem
    let screen: NSScreen

    private let scaleType: VideoScaleType
    private var endObserver: NSObjectProtocol?
    private var presentationObserver: NSKeyValueObservation?

    init(screen: NSScreen, videoURL: URL, scaleType: VideoScaleType) {
        self.screen = screen
        self.scaleType = scaleType

        let item = AVPlayerItem(url: videoURL)
        playerItem = item
        player = AVPlayer(playerItem: item)
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
        configureLayer()
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
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        window.level = NSWindow.Level(rawValue: desktopLevel + 1)
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView.wantsLayer = true
        contentView.layer = CALayer()
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = contentView
    }

    private func configurePlayer() {
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    private func configureLayer() {
        guard let rootLayer = window.contentView?.layer else {
            return
        }
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.needsDisplayOnBoundsChange = true
        rootLayer.addSublayer(playerLayer)
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
            self.player.seek(
                to: .zero,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { finished in
                if finished {
                    self.player.playImmediately(atRate: 1)
                }
            }
        }

        presentationObserver = playerItem.observe(
            \.presentationSize,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.layout()
            }
        }
    }

    func show() {
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        player.playImmediately(atRate: 1)
    }

    func pause() {
        player.pause()
    }

    func resume() {
        player.playImmediately(atRate: 1)
    }

    func close() {
        player.pause()
        window.orderOut(nil)
        window.close()
    }

    func layout() {
        guard let contentView = window.contentView else {
            return
        }
        let bounds = contentView.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch scaleType {
        case .fill:
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.frame = bounds
        case .fit:
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = bounds
        case .stretch:
            playerLayer.videoGravity = .resize
            playerLayer.frame = bounds
        case .center:
            playerLayer.videoGravity = .resizeAspect
            let videoSize = playerItem.presentationSize
            if videoSize.width > 0, videoSize.height > 0 {
                playerLayer.frame = NSRect(
                    x: (bounds.width - videoSize.width) / 2,
                    y: (bounds.height - videoSize.height) / 2,
                    width: videoSize.width,
                    height: videoSize.height
                ).integral
            } else {
                playerLayer.frame = bounds
            }
        }

        CATransaction.commit()
    }
}

@MainActor
final class WallpaperEngine: @unchecked Sendable {
    static let shared = WallpaperEngine()

    private var surfaces: [WallpaperSurface] = []
    private var activeURL: URL?
    private var securityScopedURL: URL?
    private var hasSecurityScope = false
    private var activeScaleType: VideoScaleType = .fill
    private var observers: [NSObjectProtocol] = []

    var isActive: Bool { !surfaces.isEmpty }

    private init() {
        let center = NotificationCenter.default
        let engine = self

        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in engine.rebuildForCurrentScreens() }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in engine.pause() }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in engine.resume() }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in engine.pause() }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in engine.resume() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
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
        hasSecurityScope = videoURL.startAccessingSecurityScopedResource()
        securityScopedURL = videoURL
        activeURL = videoURL
        activeScaleType = scaleType
        rebuildForCurrentScreens()
    }

    func stop() {
        surfaces.forEach { $0.close() }
        surfaces.removeAll()
        activeURL = nil

        if let securityScopedURL, hasSecurityScope {
            securityScopedURL.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = nil
        hasSecurityScope = false
    }

    func pause() {
        surfaces.forEach { $0.pause() }
    }

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindowController: DashboardWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusMenu()

        let settings = AppSettings.shared
        do {
            let videoURL = try settings.resolveVideoURL()

            if settings.desktopEnabled, let videoURL {
                try WallpaperEngine.shared.start(
                    videoURL: videoURL,
                    scaleType: settings.scaleType
                )
            }

            if settings.lockScreenEnabled,
               let item = LivecoreWallpaperLibrary.shared.currentItem() {
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try LivecoreWallpaperLibrary.shared.setPlaybackEnabled(true)
                        try WallpaperStoreManager.shared.activateLockScreen(item: item)
                    } catch {
                        try? LivecoreWallpaperLibrary.shared.setPlaybackEnabled(false)
                        DispatchQueue.main.async {
                            AppSettings.shared.lockScreenEnabled = false
                        }
                    }
                }
            }

            if videoURL == nil {
                showSettings()
            }
        } catch {
            showSettings()
            NSApp.presentError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let shouldApplyFallback = WallpaperEngine.shared.isActive
            || AppSettings.shared.desktopEnabled
            || AppSettings.shared.lockScreenEnabled

        WallpaperEngine.shared.stop()
        AppSettings.shared.desktopEnabled = false
        AppSettings.shared.lockScreenEnabled = false

        if shouldApplyFallback {
            try? LivecoreWallpaperLibrary.shared.setPlaybackEnabled(false)
            try? WallpaperStoreManager.shared.applyFallbackWallpaper()
        }
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "play.rectangle.on.rectangle",
            accessibilityDescription: "Livecore"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open App", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Play on Desktop", action: #selector(playSavedVideo), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop and Use Livecore Image", action: #selector(stopPlayback), keyEquivalent: ""))

        let scaleMenu = NSMenu()
        for (index, scale) in VideoScaleType.allCases.enumerated() {
            let scaleItem = NSMenuItem(
                title: scale.title,
                action: #selector(changeScale(_:)),
                keyEquivalent: ""
            )
            scaleItem.tag = index
            scaleItem.state = scale == AppSettings.shared.scaleType ? .on : .off
            scaleItem.target = self
            scaleMenu.addItem(scaleItem)
        }
        let scaleRoot = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        scaleRoot.submenu = scaleMenu
        menu.addItem(scaleRoot)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Livecore", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }

        item.menu = menu
        statusItem = item
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = DashboardWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func playSavedVideo() {
        do {
            guard let url = try AppSettings.shared.resolveVideoURL() else {
                showSettings()
                return
            }
            try WallpaperEngine.shared.start(
                videoURL: url,
                scaleType: AppSettings.shared.scaleType
            )
            AppSettings.shared.desktopEnabled = true
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc private func stopPlayback() {
        WallpaperEngine.shared.stop()
        AppSettings.shared.desktopEnabled = false
        AppSettings.shared.lockScreenEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try LivecoreWallpaperLibrary.shared.setPlaybackEnabled(false)
                try WallpaperStoreManager.shared.applyFallbackWallpaper()
            } catch {
                DispatchQueue.main.async {
                    NSApp.presentError(error)
                }
            }
        }
    }

    @objc private func changeScale(_ sender: NSMenuItem) {
        guard VideoScaleType.allCases.indices.contains(sender.tag) else {
            return
        }
        AppSettings.shared.scaleType = VideoScaleType.allCases[sender.tag]
        if AppSettings.shared.desktopEnabled {
            playSavedVideo()
        }
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
