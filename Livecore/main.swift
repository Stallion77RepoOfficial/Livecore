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

    /// App deletion does not remove UserDefaults, so a replaced bundle must not
    /// silently resume a wallpaper the previous installation chose.
    ///
    /// The video bookmark is deliberately kept: it is the user's own grant, not
    /// installation state. Clearing `desktopEnabled` is what actually stops the
    /// silent resume, and wiping the selection on top of it made an ordinary
    /// app update look like a factory reset.
    func prepareForCurrentInstallation() -> Bool {
        let identity = currentInstallationIdentity()
        if defaults.string(forKey: Key.installationIdentity) != identity {
            defaults.set(identity, forKey: Key.installationIdentity)
            defaults.set(false, forKey: Key.desktopEnabled)
            defaults.set(true, forKey: Key.installationCleanupPending)
        }
        return defaults.bool(forKey: Key.installationCleanupPending)
    }

    func completeInstallationCleanup() {
        defaults.set(false, forKey: Key.installationCleanupPending)
    }

    /// Where the bundle lives plus which build it is.
    ///
    /// Both survive a restart. The executable's `st_dev` and `st_ino` do not:
    /// APFS assigns a volume's device number at mount time, so it can differ
    /// between boots, and every restart then looked like a fresh installation
    /// and reset the user's setup. App Translocation moves the executable to a
    /// per-launch path for the same reason, which the bundle URL also avoids.
    private func currentInstallationIdentity() -> String {
        let bundle = Bundle.main
        let path = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let shortVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(path)#\(shortVersion)(\(build))"
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
        // Exactly the Desktop level: one step above it and "Show Desktop" slides
        // this window aside with the ordinary ones, uncovering the real Desktop
        // picture underneath. Icons live at `.desktopIconWindow`, so they stay
        // above the video without needing the extra step.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.isExcludedFromWindowsMenu = true
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
final class DesktopBackdropManager {
    static let shared = DesktopBackdropManager()

    private struct Snapshot: Codable {
        let displayID: UInt32
        let imageURL: URL
        let optionsArchive: Data
    }

    private static let snapshotsKey = "desktopBackdropSnapshots"
    private let workspace = NSWorkspace.shared
    private let defaults = UserDefaults.standard
    private var snapshots: [UInt32: Snapshot] = [:]

    /// Derived from a fixed location rather than remembered in a property, so a
    /// later launch can still recognise — and clear — a poster an interrupted
    /// session left sitting on the Desktop.
    private let posterURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Livecore/desktop-backdrop.jpg")

    private var posterIsReady: Bool {
        FileManager.default.fileExists(atPath: posterURL.path)
    }

    private init() {
        if let data = defaults.data(forKey: Self.snapshotsKey),
           let values = try? JSONDecoder().decode([Snapshot].self, from: data) {
            snapshots = Dictionary(uniqueKeysWithValues: values.map { ($0.displayID, $0) })
        }
    }

    func activate(videoURL: URL, scaleType: VideoScaleType) async throws {
        // Always regenerate: the poster now lives at a fixed path, so a stale
        // one from a previously chosen video would otherwise be reused.
        try await makePoster(from: videoURL)
        try apply(scaleType: scaleType)
    }

    func apply(scaleType: VideoScaleType) throws {
        guard posterIsReady else { return }
        var capturedNewSnapshot = false

        for screen in NSScreen.screens {
            let currentURL = workspace.desktopImageURL(for: screen)
            // A live Livecore extension URL means macOS currently owns the Lock
            // Screen selection. Writing through NSWorkspace here would replace
            // that private selection and make the Lock Screen silently fall
            // back later.
            guard !Self.isExtensionWallpaper(currentURL) else { continue }
            let displayID = Self.displayID(for: screen)
            // Never snapshot a library path: it is Livecore's own asset, and a
            // dead one restores to nothing.
            if snapshots[displayID] == nil,
               let imageURL = currentURL,
               !Self.isLibraryPath(imageURL) {
                let options = workspace.desktopImageOptions(for: screen) ?? [:]
                let archive = try NSKeyedArchiver.archivedData(
                    withRootObject: options,
                    requiringSecureCoding: false
                )
                snapshots[displayID] = Snapshot(
                    displayID: displayID,
                    imageURL: imageURL,
                    optionsArchive: archive
                )
                capturedNewSnapshot = true
            }
        }

        // Persist the restore point before macOS is changed. A crash can then
        // never turn Livecore's poster into the user's permanent wallpaper.
        if capturedNewSnapshot {
            try persistSnapshots()
        }

        do {
            for screen in NSScreen.screens {
                let currentURL = workspace.desktopImageURL(for: screen)
                guard !Self.isExtensionWallpaper(currentURL),
                      currentURL?.standardizedFileURL != posterURL.standardizedFileURL
                else { continue }
                try workspace.setDesktopImageURL(
                    posterURL,
                    for: screen,
                    options: Self.options(for: scaleType)
                )
            }
        } catch {
            restore()
            throw error
        }
    }

    func restore() {
        var failed = false
        var deferred = false

        for screen in NSScreen.screens {
            let currentURL = workspace.desktopImageURL(for: screen)
            if Self.isExtensionWallpaper(currentURL) {
                // Keep the restore point until the Lock Screen selection is
                // removed. Restoring now would remove that selection.
                deferred = true
                continue
            }
            let displayID = Self.displayID(for: screen)
            let target: (url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any])?
            if let snapshot = snapshots[displayID] {
                let options = (try? NSKeyedUnarchiver.unarchivedObject(
                    ofClasses: [NSDictionary.self, NSString.self, NSNumber.self, NSColor.self],
                    from: snapshot.optionsArchive
                )) as? [NSWorkspace.DesktopImageOptionKey: Any] ?? [:]
                target = (snapshot.imageURL, options)
            } else if isStrandedLivecoreWallpaper(currentURL) {
                // Something of Livecore's is on the Desktop with no restore
                // point behind it: an earlier session was interrupted before it
                // recorded one, or a failed apply left a dead extension asset
                // selected. Either way nothing else would ever take it down.
                target = Self.systemDefaultPicture.map { ($0, [:]) }
            } else {
                target = nil
            }
            guard let target else { continue }
            do {
                try workspace.setDesktopImageURL(
                    target.url,
                    for: screen,
                    options: target.options
                )
            } catch {
                failed = true
            }
        }

        guard !failed, !deferred else { return }
        snapshots.removeAll()
        defaults.removeObject(forKey: Self.snapshotsKey)
        removePoster()
    }

    /// Livecore's own poster, or a library asset a failed apply left selected
    /// after deleting it. Both are pictures only Livecore could have put there
    /// and neither can be displayed as the user's wallpaper.
    private func isStrandedLivecoreWallpaper(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.standardizedFileURL == posterURL.standardizedFileURL { return true }
        return Self.isLibraryPath(url) && !FileManager.default.fileExists(atPath: url.path)
    }

    /// Something macOS ships that is always safe to fall back to. The named
    /// pictures move between releases, so an unrecoverable Desktop is avoided
    /// by taking whatever the wallpaper folder actually holds.
    private static let systemDefaultPicture: URL? = {
        let fileManager = FileManager.default
        let named = [
            "/System/Library/CoreServices/DefaultDesktop.heic",
            "/System/Library/CoreServices/DefaultBackground.jpg",
        ].map(URL.init(fileURLWithPath:))
        if let existing = named.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return existing
        }
        let extensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
        return (try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/System/Library/Desktop Pictures"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .min { $0.lastPathComponent < $1.lastPathComponent }
    }()

    private func persistSnapshots() throws {
        let data = try JSONEncoder().encode(Array(snapshots.values))
        defaults.set(data, forKey: Self.snapshotsKey)
    }

    private func makePoster(from videoURL: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(
            at: CMTime(seconds: 0.1, preferredTimescale: 600)
        ).image
        guard let data = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.92]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try FileManager.default.createDirectory(
            at: posterURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: posterURL, options: .atomic)
    }

    private func removePoster() {
        try? FileManager.default.removeItem(at: posterURL)
    }

    private static func displayID(for screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }

    /// True only while the Lock Screen extension is really painting this
    /// screen. A library path whose asset is gone is a dead selection left by a
    /// failed apply: macOS is already showing its own fallback there, so the
    /// Desktop poster must be written instead of deferred, otherwise the menu
    /// bar and Dock keep tinting from that fallback.
    private static func isExtensionWallpaper(_ url: URL?) -> Bool {
        guard let url, isLibraryPath(url) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func isLibraryPath(_ url: URL) -> Bool {
        url.path.contains("/\(LivecoreLibraryFile.directoryName)/")
    }

    private static func options(
        for scaleType: VideoScaleType
    ) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        let scaling: NSImageScaling
        let allowClipping: Bool
        switch scaleType {
        case .fill:
            scaling = .scaleProportionallyUpOrDown
            allowClipping = true
        case .fit:
            scaling = .scaleProportionallyUpOrDown
            allowClipping = false
        case .stretch:
            scaling = .scaleAxesIndependently
            allowClipping = true
        case .center:
            scaling = .scaleNone
            allowClipping = false
        }
        return [
            .imageScaling: scaling.rawValue,
            .allowClipping: allowClipping,
            .fillColor: NSColor.black,
        ]
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
        observe(NSApplication.didChangeScreenParametersNotification, on: .default) {
            try? $0.rebuildForCurrentScreens()
        }
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

    func start(videoURL: URL, scaleType: VideoScaleType) async throws {
        stop()
        // Take the security scope before looking: a bookmark-resolved URL is
        // not readable until its scope is open.
        securityScopedURL = videoURL.startAccessingSecurityScopedResource() ? videoURL : nil
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            stop()
            throw NSError(
                domain: "Livecore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The selected video file could not be found."]
            )
        }
        activeURL = videoURL
        activeScaleType = scaleType
        do {
            try await DesktopBackdropManager.shared.activate(
                videoURL: videoURL,
                scaleType: scaleType
            )
            try rebuildForCurrentScreens(applyBackdrop: false)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        DesktopBackdropManager.shared.restore()
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
        try? DesktopBackdropManager.shared.apply(scaleType: scale)
        try? rebuildForCurrentScreens(applyBackdrop: false)
    }

    func pause() { surfaces.forEach { $0.pause() } }

    func resume() {
        guard activeURL != nil else {
            return
        }
        surfaces.forEach { $0.resume() }
    }

    func rebuildForCurrentScreens(applyBackdrop: Bool = true) throws {
        guard let activeURL else {
            return
        }
        if applyBackdrop {
            try DesktopBackdropManager.shared.apply(scaleType: activeScaleType)
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
    private var playMenuItem: NSMenuItem?
    private var stopMenuItem: NSMenuItem?
    private var keepAwakeMenuItem: NSMenuItem?
    private var scaleMenuItems: [NSMenuItem] = []
    private var isQuitCleanupRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let needsInstallationCleanup = AppSettings.shared.prepareForCurrentInstallation()
        if needsInstallationCleanup {
            DesktopBackdropManager.shared.restore()
            LoginItemManager.shared.resetForNewInstallation()
        }
        NSApp.setActivationPolicy(.accessory)
        PowerAssertionManager.shared.updateAssertionState()
        installStatusMenu()

        if needsInstallationCleanup {
            Task {
                do {
                    try await WallpaperStoreManager.shared.resetForNewInstallation()
                    DesktopBackdropManager.shared.restore()
                    AppSettings.shared.completeInstallationCleanup()
                } catch {
                    NSApp.presentError(error)
                }
                showSettings()
            }
            return
        }

        // A session that was killed mid-playback leaves its poster as the
        // Desktop picture. Nothing else would ever take it back down.
        if !AppSettings.shared.desktopEnabled {
            DesktopBackdropManager.shared.restore()
        }

        Task {
            do {
                let videoURL = try AppSettings.shared.resolveVideoURL()
                if AppSettings.shared.desktopEnabled, let videoURL {
                    try await WallpaperEngine.shared.start(
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
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let statusImage = NSImage(
            systemSymbolName: "play.rectangle.on.rectangle",
            accessibilityDescription: "Livecore"
        )
        statusImage?.isTemplate = true
        item.button?.image = statusImage
        item.isVisible = true

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Open App", action: #selector(showSettings), keyEquivalent: ","))
        let playItem = NSMenuItem(
            title: "Play on Desktop",
            action: #selector(playSavedVideo),
            keyEquivalent: ""
        )
        let stopItem = NSMenuItem(
            title: "Stop Desktop Playback",
            action: #selector(stopPlayback),
            keyEquivalent: ""
        )
        menu.addItem(playItem)
        menu.addItem(stopItem)
        playMenuItem = playItem
        stopMenuItem = stopItem

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
        updatePlaybackMenuItemStates()
        updateKeepAwakeMenuItemState()
        for item in scaleMenuItems {
            item.state = VideoScaleType.allCases[item.tag] == AppSettings.shared.scaleType ? .on : .off
        }
    }

    private func updatePlaybackMenuItemStates() {
        let hasVideo = (try? AppSettings.shared.resolveVideoURL()) != nil
        let isDesktopActive = WallpaperEngine.shared.isActive
        playMenuItem?.isEnabled = hasVideo && !isDesktopActive
        stopMenuItem?.isEnabled = isDesktopActive
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
        Task {
            do {
                guard let url = try AppSettings.shared.resolveVideoURL() else {
                    showSettings()
                    return
                }
                try await WallpaperEngine.shared.start(
                    videoURL: url,
                    scaleType: AppSettings.shared.scaleType
                )
                AppSettings.shared.desktopEnabled = true
                updatePlaybackMenuItemStates()
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    @objc private func stopPlayback() {
        WallpaperEngine.shared.stop()
        AppSettings.shared.desktopEnabled = false
        updatePlaybackMenuItemStates()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitCleanupRunning else { return .terminateLater }
        isQuitCleanupRunning = true

        // Disappear immediately so the asynchronous WallpaperAgent handshake
        // never presents as a frozen app during quit.
        dashboard?.window?.orderOut(nil)

        Task {
            do {
                try await WallpaperStoreManager.shared.deactivateLockScreen()
                WallpaperEngine.shared.stop()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                isQuitCleanupRunning = false
                showSettings()
                sender.reply(toApplicationShouldTerminate: false)
                sender.presentError(error)
            }
        }
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.run()
}
