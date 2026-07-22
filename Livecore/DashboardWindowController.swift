import AppKit
import AVKit

@MainActor
final class DashboardWindowController: NSWindowController {
    private let settings = AppSettings.shared
    private let preview = AVPlayerView()
    private let pathLabel = NSTextField(labelWithString: "No video selected")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let scaleControl = NSSegmentedControl(
        labels: ["Fill", "Fit", "Stretch", "Center"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let loginSwitch = NSSwitch()
    private var selectedURL: URL?
    private var previewSecurityScopedURL: URL?
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var isBusy = false
    private var needsLockScreenApply = true
    private var stateObservers: [NSObjectProtocol] = []

    private var chooseButton: NSButton?
    private var playButton: NSButton?
    private var lockScreenButton: NSButton?
    private var stopDesktopButton: NSButton?
    private var stopLockScreenButton: NSButton?
    private var pluginButton: NSButton?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Livecore"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 780, height: 580)
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        buildUI()
        loadSettings()
        observeExternalState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stateObservers.forEach(NotificationCenter.default.removeObserver)
        stateObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        previewSecurityScopedURL?.stopAccessingSecurityScopedResource()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updateButtonStates()
    }

    private func buildUI() {
        guard let content = window?.contentView else {
            return
        }

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        preview.videoGravity = .resizeAspectFill
        preview.controlsStyle = .none
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 18
        preview.layer?.masksToBounds = true
        preview.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        preview.heightAnchor.constraint(equalToConstant: 330).isActive = true

        let choose = actionButton(
            "Choose Video",
            symbol: "plus",
            action: #selector(chooseVideo),
            prominent: true
        )
        let play = actionButton(
            "Apply to Desktop",
            symbol: "play.fill",
            action: #selector(applyWallpaper),
            prominent: true
        )
        let lockScreen = actionButton(
            "Apply to Lock Screen",
            symbol: "lock.fill",
            action: #selector(applyToLockScreen),
            prominent: true
        )
        let stopDesktop = actionButton(
            "Stop Desktop",
            symbol: "stop.fill",
            action: #selector(stopDesktopWallpaper)
        )
        let stopLockScreen = actionButton(
            "Stop Lock Screen",
            symbol: "lock.slash",
            action: #selector(stopLockScreenWallpaper)
        )
        let plugin = actionButton(
            "Remove Extension",
            symbol: "trash",
            action: #selector(toggleExtension)
        )

        chooseButton = choose
        playButton = play
        lockScreenButton = lockScreen
        stopDesktopButton = stopDesktop
        stopLockScreenButton = stopLockScreen
        pluginButton = plugin

        let videoButtons = NSStackView(views: [choose, play, lockScreen, stopDesktop, stopLockScreen, plugin])
        videoButtons.orientation = .horizontal
        videoButtons.spacing = 8

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.maximumNumberOfLines = 1
        scaleControl.target = self
        scaleControl.action = #selector(scaleChanged)

        let displayCard = card(
            title: "Type & Scale",
            content: NSStackView(views: [scaleControl, pathLabel])
        )
        (displayCard.subviews.last as? NSStackView)?.spacing = 12

        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged)
        let loginRow = NSStackView(views: [
            NSTextField(labelWithString: "Launch automatically at login"),
            NSView(),
            loginSwitch,
        ])
        loginRow.orientation = .horizontal
        loginRow.alignment = .centerY
        let startupCard = card(
            title: "Startup",
            content: loginRow
        )

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let stack: NSStackView = NSStackView(views: [
            preview,
            videoButtons,
            displayCard,
            startupCard,
            statusLabel,
        ])
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        for view in [preview, videoButtons, displayCard, startupCard, statusLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -36),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 30),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -24),
        ])

        updateButtonStates()
    }

    func updateButtonStates() {
        let state = WallpaperStoreManager.shared.lockScreenState()
        let isInstalled = state.pluginInstalled
        let supportsLockScreen = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
        let hasVideo = selectedURL != nil
        let isDesktopActive = WallpaperEngine.shared.isActive || settings.desktopEnabled
        chooseButton?.isEnabled = !isBusy
        scaleControl.isEnabled = !isBusy
        stopDesktopButton?.isEnabled = !isBusy && isDesktopActive
        stopLockScreenButton?.isEnabled = !isBusy && state.canStop
        playButton?.isEnabled = !isBusy && hasVideo && !isDesktopActive
        lockScreenButton?.isEnabled = !isBusy
            && supportsLockScreen
            && hasVideo
            && (needsLockScreenApply || !state.isHealthy)
        pluginButton?.isEnabled = !isBusy && supportsLockScreen

        if state.isHealthy && !needsLockScreenApply {
            lockScreenButton?.title = "Applied to Lock Screen"
            lockScreenButton?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        } else if state.isSelected {
            lockScreenButton?.title = "Repair Lock Screen"
            lockScreenButton?.image = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)
        } else {
            lockScreenButton?.title = "Apply to Lock Screen"
            lockScreenButton?.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        }

        if isInstalled {
            pluginButton?.title = "Remove Extension"
            pluginButton?.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        } else {
            pluginButton?.title = "Install Extension"
            pluginButton?.image = NSImage(systemSymbolName: "arrow.down.app", accessibilityDescription: nil)
        }
    }

    private func card(title: String, subtitle: String = "", content: NSView) -> NSView {
        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 14

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)

        var subviews: [NSView] = [heading]
        if !subtitle.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: subtitle)
            detail.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: 11)
            subviews.append(detail)
        }
        subviews.append(content)

        let stack = NSStackView(views: subviews)
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(stack)
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: visual.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: visual.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: visual.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: visual.bottomAnchor, constant: -12),
        ])
        return visual
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        action: Selector,
        prominent: Bool = false
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded

        if prominent {
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
        }
        if title == "Apply to Desktop" {
            button.keyEquivalent = "\r"
        }
        return button
    }

    private func loadSettings() {
        scaleControl.selectedSegment = VideoScaleType.allCases.firstIndex(of: settings.scaleType) ?? 0
        if #available(macOS 13, *) {
            loginSwitch.state = LoginItemManager.shared.isEnabled ? .on : .off
        }

        do {
            selectedURL = try settings.resolveVideoURL()
            if let selectedURL {
                showPreview(selectedURL)
            }
            // Applied is a runtime-verified state, not merely a persisted store
            // selection. publishCurrentSelectionIfNeeded performs the fresh
            // extension probe and clears this flag only after it succeeds.
            needsLockScreenApply = true
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
        updateButtonStates()
        publishCurrentSelectionIfNeeded()
    }

    private func publishCurrentSelectionIfNeeded() {
        guard let selectedURL,
              WallpaperStoreManager.shared.isPluginInstalled()
        else { return }
        if let item = LivecoreWallpaperLibrary.shared.currentItem(),
           LivecoreWallpaperLibrary.shared.itemIsUsable(item) {
            setBusy(true)
            setStatus("Rendering…")
            Task {
                do {
                    try await WallpaperStoreManager.shared.refreshWallpaperSettingsModel()
                    needsLockScreenApply = !WallpaperStoreManager.shared.lockScreenState().isHealthy
                    setBusy(false)
                    setStatus("Applied to Lock Screen.")
                } catch {
                    needsLockScreenApply = true
                    setBusy(false)
                    setStatus(error.localizedDescription, error: true)
                }
            }
            return
        }

        let previousItem = LivecoreWallpaperLibrary.shared.currentItem()
        let previousState = WallpaperStoreManager.shared.lockScreenState()
        setBusy(true)
        setStatus("Rendering…")
        DispatchQueue.global(qos: .default).async {
            [weak self, selectedURL, previousItem, previousState] in
            Task {
                var preparedItem: LivecoreWallpaperItem?
                do {
                    let item = try LivecoreWallpaperLibrary.shared.prepareVideo(
                        at: selectedURL,
                        inheritingDesktopFrom: previousItem
                    )
                    preparedItem = item
                    try LivecoreWallpaperLibrary.shared.publish(item, playbackEnabled: true)
                    try await WallpaperStoreManager.shared.refreshWallpaperSettingsModel()
                    DispatchQueue.main.async {
                        self?.needsLockScreenApply = true
                        self?.setBusy(false)
                        self?.setStatus("Applied to Lock Screen.")
                    }
                } catch {
                    LivecoreWallpaperLibrary.shared.restore(
                        previousItem,
                        playbackEnabled: previousState.isHealthy
                    )
                    if let preparedItem {
                        LivecoreWallpaperLibrary.shared.discard(preparedItem)
                    }
                    DispatchQueue.main.async {
                        self?.setBusy(false)
                        self?.setStatus(error.localizedDescription, error: true)
                    }
                }
            }
        }
    }

    private func observeExternalState() {
        stateObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateButtonStates() }
        })
        stateObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.wallpaper.changed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateButtonStates() }
        })
    }

    private func showPreview(_ url: URL) {
        playerLooper = nil
        queuePlayer?.pause()
        queuePlayer = nil
        previewSecurityScopedURL?.stopAccessingSecurityScopedResource()
        previewSecurityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        pathLabel.stringValue = url.path
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(playerItem: item)
        player.isMuted = true
        playerLooper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player
        preview.player = player
        player.play()
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        updateButtonStates()
    }

    private func setStatus(_ text: String, error: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        selectedURL = url
        needsLockScreenApply = true
        showPreview(url)
        setStatus("Video is ready. Apply it to Desktop or Lock Screen.")
        updateButtonStates()
    }

    @objc private func applyWallpaper() {
        guard let selectedURL else {
            setStatus("Choose a video first.", error: true)
            return
        }

        do {
            let scale = VideoScaleType.allCases[scaleControl.selectedSegment]
            try settings.saveVideoURL(selectedURL)
            settings.scaleType = scale
            try WallpaperEngine.shared.start(videoURL: selectedURL, scaleType: scale)
            settings.desktopEnabled = true

            if #available(macOS 13, *), !LoginItemManager.shared.isEnabled {
                try? LoginItemManager.shared.setEnabled(true)
                loginSwitch.state = .on
            }

            setStatus("Applied to Desktop.")
            updateButtonStates()
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    @objc private func stopDesktopWallpaper() {
        WallpaperEngine.shared.stop()
        settings.desktopEnabled = false
        setStatus("Desktop restored.")
        updateButtonStates()
    }

    @objc private func stopLockScreenWallpaper() {
        guard WallpaperStoreManager.shared.lockScreenState().canStop else {
            updateButtonStates()
            return
        }
        setBusy(true)
        setStatus("Restoring Lock Screen...")

        DispatchQueue.global(qos: .default).async { [weak self] in
            Task {
                do {
                    try await WallpaperStoreManager.shared.deactivateLockScreen()
                    DispatchQueue.main.async {
                        self?.needsLockScreenApply = self?.selectedURL != nil
                        self?.setBusy(false)
                        self?.setStatus("Lock Screen restored.")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.setBusy(false)
                        self?.setStatus(error.localizedDescription, error: true)
                    }
                }
            }
        }
    }

    @objc private func scaleChanged() {
        settings.scaleType = VideoScaleType.allCases[scaleControl.selectedSegment]
    }

    @objc private func loginChanged() {
        guard #available(macOS 13, *) else {
            return
        }
        do {
            try LoginItemManager.shared.setEnabled(loginSwitch.state == .on)
        } catch {
            loginSwitch.state = LoginItemManager.shared.isEnabled ? .on : .off
            setStatus(error.localizedDescription, error: true)
        }
    }

    @objc private func applyToLockScreen() {
        guard let selectedURL else {
            setStatus("Choose a video first.", error: true)
            return
        }

        let scale = VideoScaleType.allCases[scaleControl.selectedSegment]
        do {
            try settings.saveVideoURL(selectedURL)
            settings.scaleType = scale
        } catch {
            setStatus(error.localizedDescription, error: true)
            return
        }

        setBusy(true)
        setStatus("Rendering…")
        let previousItem = LivecoreWallpaperLibrary.shared.currentItem()
        let previousState = WallpaperStoreManager.shared.lockScreenState()

        DispatchQueue.global(qos: .default).async { [weak self, selectedURL, previousItem, previousState] in
            Task {
                var preparedItem: LivecoreWallpaperItem?
                do {
                    let item = try LivecoreWallpaperLibrary.shared.prepareVideo(
                        at: selectedURL,
                        inheritingDesktopFrom: previousItem
                    )
                    preparedItem = item
                    try LivecoreWallpaperLibrary.shared.publish(item, playbackEnabled: true)
                    try await WallpaperStoreManager.shared.installPlugin()
                    try await WallpaperStoreManager.shared.activateLockScreen(item: item)

                    DispatchQueue.main.async {
                        self?.needsLockScreenApply = false
                        self?.setBusy(false)
                        self?.setStatus("Applied to Lock Screen.")
                    }
                } catch {
                    let mustPreserve = (error as? LivecoreProviderError)?.mustPreservePublishedItem == true
                    if !mustPreserve {
                        LivecoreWallpaperLibrary.shared.restore(
                            previousItem,
                            playbackEnabled: previousState.isHealthy
                        )
                        if let preparedItem {
                            LivecoreWallpaperLibrary.shared.discard(preparedItem)
                        }
                    }
                    WallpaperStoreManager.shared.refreshWallpaperSettings()
                    DispatchQueue.main.async {
                        self?.needsLockScreenApply = true
                        self?.setBusy(false)
                        self?.setStatus(error.localizedDescription, error: true)
                    }
                }
            }
        }
    }

    @objc private func toggleExtension() {
        let isInstalled = WallpaperStoreManager.shared.isPluginInstalled()
        setBusy(true)

        if isInstalled {
            setStatus("Removing Livecore extension…")
            DispatchQueue.global(qos: .default).async { [weak self] in
                Task {
                    do {
                        try await WallpaperStoreManager.shared.uninstallPlugin()
                        DispatchQueue.main.async {
                            self?.needsLockScreenApply = self?.selectedURL != nil
                            self?.setBusy(false)
                            self?.setStatus("Extension removed.")
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self?.setBusy(false)
                            self?.setStatus(error.localizedDescription, error: true)
                        }
                    }
                }
            }
        } else {
            setStatus("Installing Livecore extension…")
            let sourceURL = selectedURL
            let previousItem = LivecoreWallpaperLibrary.shared.currentItem()
            let previousState = WallpaperStoreManager.shared.lockScreenState()
            DispatchQueue.global(qos: .default).async {
                [weak self, sourceURL, previousItem, previousState] in
                Task {
                    var preparedItem: LivecoreWallpaperItem?
                    do {
                        if let sourceURL {
                            let item = try LivecoreWallpaperLibrary.shared.prepareVideo(
                                at: sourceURL,
                                inheritingDesktopFrom: previousItem
                            )
                            preparedItem = item
                            try LivecoreWallpaperLibrary.shared.publish(item, playbackEnabled: true)
                        } else if let previousItem {
                            try LivecoreWallpaperLibrary.shared.publish(previousItem, playbackEnabled: true)
                        }
                        try await WallpaperStoreManager.shared.installPlugin()
                        DispatchQueue.main.async {
                            self?.needsLockScreenApply = true
                            self?.setBusy(false)
                            self?.setStatus("Extension installed.")
                        }
                    } catch {
                        LivecoreWallpaperLibrary.shared.restore(
                            previousItem,
                            playbackEnabled: previousState.isHealthy
                        )
                        if let preparedItem {
                            LivecoreWallpaperLibrary.shared.discard(preparedItem)
                        }
                        DispatchQueue.main.async {
                            self?.setBusy(false)
                            self?.setStatus(error.localizedDescription, error: true)
                        }
                    }
                }
            }
        }
    }
}
