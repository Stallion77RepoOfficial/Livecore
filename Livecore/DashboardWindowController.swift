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
    private var isBusy = false

    private var chooseButton: NSButton?
    private var playButton: NSButton?
    private var lockScreenButton: NSButton?
    private var stopButton: NSButton?
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        preview.controlsStyle = .floating
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
        let stop = actionButton(
            "Stop",
            symbol: "stop.fill",
            action: #selector(stopWallpaper)
        )
        let plugin = actionButton(
            "Remove Extension",
            symbol: "trash",
            action: #selector(toggleExtension)
        )

        chooseButton = choose
        playButton = play
        lockScreenButton = lockScreen
        stopButton = stop
        pluginButton = plugin

        let videoButtons = NSStackView(views: [choose, play, lockScreen, stop, plugin])
        videoButtons.orientation = .horizontal
        videoButtons.spacing = 8

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.maximumNumberOfLines = 1
        scaleControl.target = self
        scaleControl.action = #selector(scaleChanged)

        let displayCard = card(
            title: "Appearance",
            subtitle: "Choose how the video fits the display",
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
            subtitle: "Keep Livecore ready in the menu bar",
            content: loginRow
        )

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [
            preview,
            videoButtons,
            displayCard,
            startupCard,
            statusLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
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
        let isInstalled = WallpaperStoreManager.shared.isPluginInstalled()
        let hasVideo = selectedURL != nil
        let isDesktopActive = WallpaperEngine.shared.isActive || settings.desktopEnabled
        let isLockScreenActive = settings.lockScreenEnabled
        let isAnyActive = isDesktopActive || isLockScreenActive

        chooseButton?.isEnabled = !isBusy
        scaleControl.isEnabled = !isBusy
        stopButton?.isEnabled = !isBusy && isAnyActive
        playButton?.isEnabled = !isBusy && hasVideo && !isDesktopActive
        lockScreenButton?.isEnabled = !isBusy && hasVideo && !isLockScreenActive
        pluginButton?.isEnabled = !isBusy

        if isInstalled {
            pluginButton?.title = "Remove Extension"
            pluginButton?.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        } else {
            pluginButton?.title = "Install Extension"
            pluginButton?.image = NSImage(systemSymbolName: "arrow.down.app", accessibilityDescription: nil)
        }
    }

    private func card(title: String, subtitle: String, content: NSView) -> NSView {
        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 14

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [heading, detail, content])
        stack.orientation = .vertical
        stack.alignment = .leading
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
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
        updateButtonStates()
    }

    private func showPreview(_ url: URL) {
        pathLabel.stringValue = url.path
        let player = AVPlayer(url: url)
        player.isMuted = true
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
        showPreview(url)
        setStatus("Video is ready to preview.")
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

            setStatus("Video applied to Desktop.")
            updateButtonStates()
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    @objc private func stopWallpaper() {
        guard WallpaperEngine.shared.isActive || settings.desktopEnabled || settings.lockScreenEnabled else {
            return
        }

        WallpaperEngine.shared.stop()
        settings.desktopEnabled = false
        settings.lockScreenEnabled = false
        setBusy(true)
        setStatus("Stopping playback and applying the built-in Livecore image…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try LivecoreWallpaperLibrary.shared.setPlaybackEnabled(false)
                try WallpaperStoreManager.shared.applyFallbackWallpaper()
                DispatchQueue.main.async {
                    self?.setBusy(false)
                    self?.setStatus("Playback stopped. The built-in Livecore image is active on Desktop and Lock Screen.")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setBusy(false)
                    self?.setStatus(error.localizedDescription, error: true)
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
        setStatus("Installing and selecting Livecore for the Lock Screen…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self, selectedURL] in
            do {
                try WallpaperStoreManager.shared.installPlugin()
                let item = try LivecoreWallpaperLibrary.shared.importVideo(at: selectedURL)
                try LivecoreWallpaperLibrary.shared.setPlaybackEnabled(true)
                try WallpaperStoreManager.shared.activateLockScreen(item: item)

                DispatchQueue.main.async {
                    AppSettings.shared.lockScreenEnabled = true
                    self?.setBusy(false)
                    self?.setStatus("Video applied to the Lock Screen. Desktop was left unchanged.")
                }
            } catch {
                try? LivecoreWallpaperLibrary.shared.setPlaybackEnabled(false)
                DispatchQueue.main.async {
                    AppSettings.shared.lockScreenEnabled = false
                    self?.setBusy(false)
                    self?.setStatus(error.localizedDescription, error: true)
                }
            }
        }
    }

    @objc private func toggleExtension() {
        let isInstalled = WallpaperStoreManager.shared.isPluginInstalled()
        setBusy(true)

        if isInstalled {
            setStatus("Removing Livecore extension…")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                WallpaperStoreManager.shared.uninstallPlugin()
                DispatchQueue.main.async {
                    AppSettings.shared.lockScreenEnabled = false
                    self?.setBusy(false)
                    self?.setStatus("Extension removed from System Settings.")
                }
            }
        } else {
            setStatus("Installing Livecore extension…")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try WallpaperStoreManager.shared.installPlugin()
                    DispatchQueue.main.async {
                        self?.setBusy(false)
                        self?.setStatus("Extension installed into System Settings.")
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
}
