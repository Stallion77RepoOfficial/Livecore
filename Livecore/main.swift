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
            .fullScreenAuxiliary
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
        player.automaticallyWaitsToMinimizeStalling = true
    }

    private func configureLayer() {
        guard let rootLayer = window.contentView?.layer else { return }
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
            guard let self else { return }
            self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                if finished { self.player.play() }
            }
        }

        presentationObserver = playerItem.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.layout()
            }
        }
    }

    func show() {
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        player.play()
    }

    func pause() {
        player.pause()
    }

    func resume() {
        player.play()
    }

    func close() {
        player.pause()
        window.orderOut(nil)
        window.close()
    }

    func layout() {
        guard let contentView = window.contentView else { return }
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
                domain: "LiveCore",
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
        guard activeURL != nil else { return }
        surfaces.forEach { $0.resume() }
    }

    func rebuildForCurrentScreens() {
        guard let activeURL else { return }

        surfaces.forEach { $0.close() }
        surfaces = NSScreen.screens.map {
            WallpaperSurface(screen: $0, videoURL: activeURL, scaleType: activeScaleType)
        }
        surfaces.forEach { $0.show() }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings = AppSettings.shared

    private let pathLabel = NSTextField(labelWithString: "No video selected")
    private let chooseButton = NSButton(title: "Choose Video…", target: nil, action: nil)
    private let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Launch automatically at login", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply and Play", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private var selectedURL: URL?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Livecore"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        buildUI()
        loadSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        chooseButton.target = self
        chooseButton.action = #selector(chooseVideo)
        applyButton.target = self
        applyButton.action = #selector(applyAndPlay)
        applyButton.keyEquivalent = "\r"
        stopButton.target = self
        stopButton.action = #selector(stopPlayback)
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginItemChanged)

        scalePopup.addItems(withTitles: VideoScaleType.allCases.map(\.title))

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 2
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let videoRow = NSStackView(views: [pathLabel, chooseButton])
        videoRow.orientation = .horizontal
        videoRow.spacing = 12
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)

        let scaleLabel = NSTextField(labelWithString: "Appearance:")
        let scaleRow = NSStackView(views: [scaleLabel, scalePopup])
        scaleRow.orientation = .horizontal
        scaleRow.spacing = 12
        scaleRow.alignment = .centerY
        scaleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let buttonSpacer = NSView()
        let buttonRow = NSStackView(views: [buttonSpacer, stopButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [videoRow, scaleRow, loginCheckbox, statusLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        videoRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scaleRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24)
        ])
    }

    private func loadSettings() {
        scalePopup.selectItem(at: VideoScaleType.allCases.firstIndex(of: settings.scaleType) ?? 0)

        if #available(macOS 13.0, *) {
            loginCheckbox.state = LoginItemManager.shared.isEnabled ? .on : .off
        } else {
            loginCheckbox.isEnabled = false
            loginCheckbox.toolTip = "This option requires macOS 13 or later."
        }

        do {
            selectedURL = try settings.resolveVideoURL()
            pathLabel.stringValue = selectedURL?.path ?? "No video selected"
        } catch {
            selectedURL = nil
            pathLabel.stringValue = "The saved video is unavailable; choose it again."
        }
    }

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a wallpaper video"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedURL = url
        pathLabel.stringValue = url.path
        statusLabel.stringValue = ""
    }

    @objc private func applyAndPlay() {
        guard let selectedURL else {
            statusLabel.stringValue = "Choose a video first."
            NSSound.beep()
            return
        }

        let scale = VideoScaleType.allCases[scalePopup.indexOfSelectedItem]

        do {
            try settings.saveVideoURL(selectedURL)
            settings.scaleType = scale
            try WallpaperEngine.shared.start(videoURL: selectedURL, scaleType: scale)
            statusLabel.stringValue = "The video is playing on every display."
        } catch {
            statusLabel.stringValue = error.localizedDescription
            presentError(error)
        }
    }

    @objc private func stopPlayback() {
        WallpaperEngine.shared.stop()
        statusLabel.stringValue = "Playback stopped."
    }

    @objc private func loginItemChanged() {
        guard #available(macOS 13.0, *) else { return }

        do {
            try LoginItemManager.shared.setEnabled(loginCheckbox.state == .on)
            settings.startAutomatically = loginCheckbox.state == .on
        } catch {
            loginCheckbox.state = LoginItemManager.shared.isEnabled ? .on : .off
            statusLabel.stringValue = "Could not change the startup setting: \(error.localizedDescription)"
            presentError(error)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindowController: DashboardWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusMenu()

        do {
            if let url = try AppSettings.shared.resolveVideoURL() {
                try WallpaperEngine.shared.start(
                    videoURL: url,
                    scaleType: AppSettings.shared.scaleType
                )
                if AppSettings.shared.lockScreenEnabled,
                   let item = LivecoreWallpaperLibrary.shared.currentItem() {
                    DispatchQueue.global(qos: .utility).async {
                        try? WallpaperStoreManager.shared.activateLockScreen(item: item)
                    }
                }
            } else {
                showSettings()
            }
        } catch {
            showSettings()
            NSApp.presentError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WallpaperEngine.shared.stop()
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "play.rectangle.on.rectangle",
            accessibilityDescription: "LiveCore"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open App", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Play", action: #selector(playSavedVideo), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stopPlayback), keyEquivalent: ""))
        let scaleMenu = NSMenu()
        for (index, scale) in VideoScaleType.allCases.enumerated() {
            let scaleItem = NSMenuItem(title: scale.title, action: #selector(changeScale(_:)), keyEquivalent: "")
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
            try WallpaperEngine.shared.start(videoURL: url, scaleType: AppSettings.shared.scaleType)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc private func stopPlayback() {
        WallpaperEngine.shared.stop()
    }

    @objc private func changeScale(_ sender: NSMenuItem) {
        guard VideoScaleType.allCases.indices.contains(sender.tag) else { return }
        AppSettings.shared.scaleType = VideoScaleType.allCases[sender.tag]
        playSavedVideo()
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
