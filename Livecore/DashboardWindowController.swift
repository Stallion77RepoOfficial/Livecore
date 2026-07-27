import AppKit
import AVKit

@MainActor
final class DashboardWindowController: NSWindowController {
    private let settings = AppSettings.shared
    private let preview = AVPlayerView()
    private let pathLabel = NSTextField(labelWithString: "No video selected")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let scaleControl = NSSegmentedControl(
        labels: VideoScaleType.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let loginSwitch = NSSwitch()
    private let keepAwakeSwitch = NSSwitch()

    private var selectedURL: URL?
    private var previewSecurityScopedURL: URL?
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var isBusy = false
    /// nil until the first successful read of the macOS wallpaper settings.
    private var lockState: LivecoreLockScreenState?
    /// Set when the user picks a different video, so an already-applied Lock
    /// Screen can be replaced without first stopping it.
    private var hasUnappliedSelection = false

    private var localObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    private var chooseButton: NSButton?
    private var playButton: NSButton?
    private var lockScreenButton: NSButton?
    private var stopDesktopButton: NSButton?
    private var stopLockScreenButton: NSButton?
    private var extensionButton: NSButton?

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
        refreshLockScreenState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        localObservers.forEach(NotificationCenter.default.removeObserver)
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        previewSecurityScopedURL?.stopAccessingSecurityScopedResource()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updateScaleControlState()
        refreshLockScreenState()
    }

    // MARK: - Layout

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

        let choose = actionButton("Choose Video", symbol: "plus", action: #selector(chooseVideo), prominent: true)
        let play = actionButton("Apply to Desktop", symbol: "play.fill", action: #selector(applyToDesktop), prominent: true)
        play.keyEquivalent = "\r"
        let lockScreen = actionButton("Apply to Lock Screen", symbol: "lock.fill", action: #selector(applyToLockScreen), prominent: true)
        let stopDesktop = actionButton("Stop Desktop", symbol: "stop.fill", action: #selector(stopDesktopWallpaper))
        let stopLockScreen = actionButton("Stop Lock Screen", symbol: "lock.slash", action: #selector(stopLockScreenWallpaper))
        let extensionToggle = actionButton("Remove Extension", symbol: "trash", action: #selector(toggleExtension))

        chooseButton = choose
        playButton = play
        lockScreenButton = lockScreen
        stopDesktopButton = stopDesktop
        stopLockScreenButton = stopLockScreen
        extensionButton = extensionToggle

        let videoButtons = NSStackView(views: [choose, play, lockScreen, stopDesktop, stopLockScreen, extensionToggle])
        videoButtons.orientation = .horizontal
        videoButtons.spacing = 8

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.maximumNumberOfLines = 1
        scaleControl.target = self
        scaleControl.action = #selector(scaleChanged)

        let scaleStack = NSStackView(views: [scaleControl, pathLabel])
        scaleStack.spacing = 12
        let displayCard = card(title: "Type & Scale", content: scaleStack)

        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged)
        keepAwakeSwitch.target = self
        keepAwakeSwitch.action = #selector(keepAwakeChanged)

        let loginRow = switchRow("Launch automatically at login", control: loginSwitch)
        let keepAwakeRow = switchRow("Keep display awake on Lock Screen", control: keepAwakeSwitch)
        let startupStack = NSStackView(views: [loginRow, keepAwakeRow])
        startupStack.orientation = .vertical
        startupStack.alignment = .leading
        startupStack.spacing = 10
        loginRow.widthAnchor.constraint(equalTo: startupStack.widthAnchor).isActive = true
        keepAwakeRow.widthAnchor.constraint(equalTo: startupStack.widthAnchor).isActive = true

        let startupCard = card(title: "Startup & Power", content: startupStack)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let rows: [NSView] = [preview, videoButtons, displayCard, startupCard, statusLabel]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        for view in rows {
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

    private func card(title: String, content: NSView) -> NSView {
        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 14

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)

        let stack = NSStackView(views: [heading, content])
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

    private func switchRow(_ title: String, control: NSSwitch) -> NSStackView {
        let row = NSStackView(views: [NSTextField(labelWithString: title), NSView(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
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
        return button
    }

    // MARK: - State

    private func loadSettings() {
        updateScaleControlState()
        loginSwitch.state = LoginItemManager.shared.isEnabled ? .on : .off
        keepAwakeSwitch.state = settings.keepScreenAwakeOnLock ? .on : .off

        do {
            selectedURL = try settings.resolveVideoURL()
            if let selectedURL {
                showPreview(selectedURL)
            }
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    /// Reads the live macOS wallpaper state. Livecore never changes anything
    /// here: installing the extension and applying a wallpaper are explicit
    /// actions the user takes.
    private func refreshLockScreenState() {
        Task {
            do {
                lockState = try await WallpaperStoreManager.shared.lockScreenState()
            } catch {
                lockState = nil
                setStatus(error.localizedDescription, error: true)
            }
            updateButtonStates()
        }
    }

    private func updateButtonStates() {
        let hasVideo = selectedURL != nil
        let isDesktopActive = WallpaperEngine.shared.isActive || settings.desktopEnabled

        chooseButton?.isEnabled = !isBusy
        scaleControl.isEnabled = !isBusy
        playButton?.isEnabled = !isBusy && hasVideo && !isDesktopActive
        stopDesktopButton?.isEnabled = !isBusy && isDesktopActive

        // Everything below needs to know what macOS is actually showing.
        guard let lockState else {
            stopLockScreenButton?.isEnabled = false
            lockScreenButton?.isEnabled = false
            extensionButton?.isEnabled = false
            return
        }

        stopLockScreenButton?.isEnabled = !isBusy && lockState.isSelected
        extensionButton?.isEnabled = !isBusy
        // The Lock Screen renderer *is* the extension. Without it there is
        // nothing to apply, and Livecore will not quietly install it. Once a
        // video is live the button stays locked until the user stops the Lock
        // Screen or picks a different video.
        lockScreenButton?.isEnabled = !isBusy
            && hasVideo
            && lockState.extensionInstalled
            && (!lockState.isApplied || hasUnappliedSelection)

        if lockState.isApplied {
            setButton(lockScreenButton, "Applied to Lock Screen", symbol: "checkmark.circle.fill")
        } else if lockState.isSelected {
            setButton(lockScreenButton, "Repair Lock Screen", symbol: "wrench.and.screwdriver.fill")
        } else {
            setButton(lockScreenButton, "Apply to Lock Screen", symbol: "lock.fill")
        }

        if lockState.extensionInstalled {
            setButton(extensionButton, "Remove Extension", symbol: "trash")
        } else {
            setButton(extensionButton, "Install Extension", symbol: "arrow.down.app")
        }
    }

    private func setButton(_ button: NSButton?, _ title: String, symbol: String) {
        button?.title = title
        button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func observeExternalState() {
        localObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateScaleControlState()
                self?.refreshLockScreenState()
            }
        })
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.wallpaper.changed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshLockScreenState() }
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

    /// Runs one wallpaper mutation off the main thread, keeping the UI busy for
    /// its duration and refreshing the real macOS state afterwards.
    private func perform(
        _ progress: String,
        success: String,
        marksSelectionApplied: Bool = false,
        work: @escaping @Sendable () async throws -> Void
    ) {
        setBusy(true)
        setStatus(progress)
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<Void, Error>
            do {
                try await work()
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await self?.finish(
                outcome,
                success: success,
                marksSelectionApplied: marksSelectionApplied
            )
        }
    }

    private func finish(
        _ outcome: Result<Void, Error>,
        success: String,
        marksSelectionApplied: Bool
    ) {
        switch outcome {
        case .success:
            if marksSelectionApplied {
                hasUnappliedSelection = false
            }
            setStatus(success)
        case .failure(let error):
            setStatus(error.localizedDescription, error: true)
        }
        setBusy(false)
        refreshLockScreenState()
    }

    // MARK: - Actions

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        selectedURL = url
        hasUnappliedSelection = true
        showPreview(url)
        setStatus("Video is ready. Apply it to Desktop or Lock Screen.")
        updateButtonStates()
    }

    @objc private func applyToDesktop() {
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
        setStatus("Applying to Desktop…")
        Task {
            do {
                try await WallpaperEngine.shared.start(
                    videoURL: selectedURL,
                    scaleType: scale
                )
                settings.desktopEnabled = true
                setStatus("Applied to Desktop.")
            } catch {
                setStatus(error.localizedDescription, error: true)
            }
            setBusy(false)
            updateButtonStates()
        }
    }

    @objc private func stopDesktopWallpaper() {
        WallpaperEngine.shared.stop()
        settings.desktopEnabled = false
        setStatus("Desktop restored.")
        updateButtonStates()
    }

    @objc private func applyToLockScreen() {
        guard let selectedURL else {
            setStatus("Choose a video first.", error: true)
            return
        }
        guard lockState?.extensionInstalled == true else {
            setStatus("Install the Livecore wallpaper extension first.", error: true)
            return
        }
        do {
            try settings.saveVideoURL(selectedURL)
            settings.scaleType = VideoScaleType.allCases[scaleControl.selectedSegment]
        } catch {
            setStatus(error.localizedDescription, error: true)
            return
        }

        let videoURL = selectedURL
        perform(
            "Rendering…",
            success: "Applied to Lock Screen.",
            marksSelectionApplied: true
        ) {
            try await WallpaperStoreManager.shared.applyLockScreen(videoURL: videoURL)
        }
    }

    @objc private func stopLockScreenWallpaper() {
        perform("Restoring Lock Screen…", success: "Lock Screen restored.") {
            try await WallpaperStoreManager.shared.deactivateLockScreen()
            await MainActor.run {
                if WallpaperEngine.shared.isActive {
                    try? DesktopBackdropManager.shared.apply(
                        scaleType: AppSettings.shared.scaleType
                    )
                } else {
                    DesktopBackdropManager.shared.restore()
                }
            }
        }
    }

    @objc private func toggleExtension() {
        if lockState?.extensionInstalled == true {
            perform("Removing Livecore extension…", success: "Extension removed.") {
                try await WallpaperStoreManager.shared.uninstallExtension()
                await MainActor.run {
                    if WallpaperEngine.shared.isActive {
                        try? DesktopBackdropManager.shared.apply(
                            scaleType: AppSettings.shared.scaleType
                        )
                    } else {
                        DesktopBackdropManager.shared.restore()
                    }
                }
            }
        } else {
            perform("Installing Livecore extension…", success: "Extension installed.") {
                try await WallpaperStoreManager.shared.installExtension()
            }
        }
    }

    @objc private func scaleChanged() {
        let scale = VideoScaleType.allCases[scaleControl.selectedSegment]
        settings.scaleType = scale
        WallpaperEngine.shared.setScale(scale)
    }

    /// The menu bar writes the same setting, so the window re-reads it whenever
    /// it comes forward instead of trying to stay in sync from the other side.
    func updateScaleControlState() {
        scaleControl.selectedSegment = VideoScaleType.allCases.firstIndex(of: settings.scaleType) ?? 0
    }

    func updateKeepAwakeSwitchState() {
        keepAwakeSwitch.state = settings.keepScreenAwakeOnLock ? .on : .off
    }

    @objc private func loginChanged() {
        do {
            try LoginItemManager.shared.setEnabled(loginSwitch.state == .on)
        } catch {
            loginSwitch.state = LoginItemManager.shared.isEnabled ? .on : .off
            setStatus(error.localizedDescription, error: true)
        }
    }

    @objc private func keepAwakeChanged() {
        settings.keepScreenAwakeOnLock = (keepAwakeSwitch.state == .on)
        PowerAssertionManager.shared.updateAssertionState()
        (NSApp.delegate as? AppDelegate)?.updateKeepAwakeMenuItemState()
    }
}
