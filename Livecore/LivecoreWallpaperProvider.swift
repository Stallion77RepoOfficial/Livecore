import AppKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO

enum LivecoreProviderError: LocalizedError {
    case extensionMissingFromBundle
    case extensionNotInstalled
    case extensionContainerUnavailable
    case pluginKitFailed(String)
    case videoUnavailable
    case noDisplaysAvailable
    case lockScreenSelectionRejected
    case lockScreenRendererUnavailable
    case lockScreenRollbackFailed

    var errorDescription: String? {
        switch self {
        case .extensionMissingFromBundle:
            return "This Livecore build does not contain the wallpaper extension."
        case .extensionNotInstalled:
            return "Install the Livecore wallpaper extension first."
        case .extensionContainerUnavailable:
            return "macOS has not created the wallpaper extension's storage yet."
        case .pluginKitFailed(let detail):
            return "macOS refused to change the Livecore wallpaper extension. \(detail)"
        case .videoUnavailable:
            return "The prepared video is incomplete, so nothing was changed."
        case .noDisplaysAvailable:
            return "macOS reported no connected displays, so nothing was changed."
        case .lockScreenSelectionRejected:
            return "macOS did not accept the Livecore Lock Screen selection."
        case .lockScreenRendererUnavailable:
            return "The Livecore wallpaper extension did not create a healthy renderer."
        case .lockScreenRollbackFailed:
            return "Livecore could not safely restore the previous Lock Screen. The active assets were kept to prevent a black screen."
        }
    }
}

/// The video library the app writes and the extension reads.
///
/// Storage lives inside the extension's sandbox container, the only directory
/// both processes reach without an App Group. The app never creates that
/// container: `containermanagerd` owns it, and a directory the app made first
/// has no container metadata, so macOS replaces it and silently discards
/// whatever was written there. Writes therefore require the container to exist,
/// which installing the extension guarantees.
final class LivecoreWallpaperLibrary: @unchecked Sendable {
    static let shared = LivecoreWallpaperLibrary()

    static var embeddedExtensionURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/LivecoreWallpaperExtension.appex")
    }

    /// Identifier of the extension this build embeds, read from the appex so
    /// there is exactly one source of truth for the container path.
    static let extensionBundleID: String = {
        guard let identifier = Bundle(url: embeddedExtensionURL)?.bundleIdentifier else {
            preconditionFailure("Livecore.app was built without its wallpaper extension")
        }
        return identifier
    }()

    private let containerURL: URL
    private let containerDocumentsURL: URL
    private let reader: LivecoreLibraryReader
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.livecore.app.wallpaper-library", qos: .userInitiated)

    private init() {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(Self.extensionBundleID)",
                isDirectory: true
            )
        containerURL = container
        containerDocumentsURL = container
            .appendingPathComponent("Data/Documents", isDirectory: true)
        reader = LivecoreLibraryReader(
            root: containerDocumentsURL.appendingPathComponent(
                LivecoreLibraryFile.directoryName,
                isDirectory: true
            )
        )
    }

    var root: URL { reader.root }
    var lockScreenBackupURL: URL { reader.url(LivecoreLibraryFile.lockScreenBackup) }
    var legacyLockScreenBackupURL: URL { reader.url("lock-screen-backup.plist") }

    /// True only for a container provisioned by containermanagerd. Older
    /// Livecore builds could create a look-alike Documents path without this
    /// metadata; writing there loses the assets when macOS later replaces it.
    var containerExists: Bool {
        let metadataURL = containerURL.appendingPathComponent(
            ".com.apple.containermanagerd.metadata.plist"
        )
        guard fileManager.fileExists(atPath: containerDocumentsURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let metadata = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ) as? [String: Any],
              metadata["MCMMetadataIdentifier"] as? String == Self.extensionBundleID
        else { return false }
        return true
    }

    func currentItem() -> LivecoreWallpaperItem? { queue.sync { reader.currentItem() } }

    func item(withID id: UUID) -> LivecoreWallpaperItem? { queue.sync { reader.item(id) } }

    func itemIsUsable(_ item: LivecoreWallpaperItem) -> Bool {
        queue.sync { reader.itemIsUsable(item) }
    }

    /// Copies a video, its poster frame and one still per display into the
    /// library without changing what is published.
    func prepareVideo(
        at source: URL,
        inheritingDesktopFrom previousItem: LivecoreWallpaperItem?
    ) async throws -> LivecoreWallpaperItem {
        let displays = await desktopPictures()
        guard let primaryDisplayID = displays.first?.displayID else {
            throw LivecoreProviderError.noDisplaysAvailable
        }

        let itemID = UUID()
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let poster = try await jpeg(
            from: source,
            at: CMTime(seconds: 0.1, preferredTimescale: 600),
            maximumSize: NSSize(width: 1920, height: 1080)
        )
        // Preferred still is the Desktop picture the display is showing right
        // now, so taking over the Desktop slot stays invisible while unlocked.
        // When macOS will not name a usable picture the video's own poster is
        // the only sensible thing to paint.
        var stills: [String: (name: String, data: Data)] = [:]
        for display in displays {
            stills[display.displayID] = (
                LivecoreLibraryFile.desktopImage(itemID, displayID: display.displayID),
                await desktopStill(at: display.url)
                    ?? inheritedStill(from: previousItem, displayID: display.displayID)
                    ?? poster
            )
        }

        var names = stills.mapValues(\.name)
        // A display connected later has no still of its own.
        names[LivecoreLibraryFile.defaultDisplayKey] = names[primaryDisplayID]

        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let item = LivecoreWallpaperItem(
            id: itemID,
            fileName: "\(itemID.uuidString).\(ext)",
            title: source.deletingPathExtension().lastPathComponent,
            desktopImageFileNames: names
        )

        return try queue.sync {
            try makeLibraryDirectory()
            do {
                try poster.write(to: reader.thumbnailURL(for: item), options: .atomic)
                for still in stills.values {
                    try still.data.write(to: reader.url(still.name), options: .atomic)
                }
                try fileManager.copyItem(at: source, to: reader.videoURL(for: item))
                try JSONEncoder().encode(item).write(
                    to: reader.url(LivecoreLibraryFile.metadata(item.id)),
                    options: .atomic
                )
                return item
            } catch {
                reader.assetURLs(for: item).forEach { try? fileManager.removeItem(at: $0) }
                throw error
            }
        }
    }

    /// Makes `item` the one the extension renders.
    func publish(_ item: LivecoreWallpaperItem) throws {
        try queue.sync {
            guard reader.itemIsUsable(item) else { throw LivecoreProviderError.videoUnavailable }
            try JSONEncoder().encode(item).write(
                to: reader.url(LivecoreLibraryFile.current),
                options: .atomic
            )
        }
    }

    func unpublish() throws {
        try queue.sync {
            let current = reader.url(LivecoreLibraryFile.current)
            guard fileManager.fileExists(atPath: current.path) else { return }
            try fileManager.removeItem(at: current)
        }
    }

    /// Deletes an item that was prepared but never became the published one.
    func discard(_ item: LivecoreWallpaperItem) {
        queue.sync {
            guard reader.currentItem()?.id != item.id else { return }
            reader.assetURLs(for: item).forEach { try? fileManager.removeItem(at: $0) }
        }
    }

    func purge() throws {
        try queue.sync {
            guard fileManager.fileExists(atPath: root.path) else { return }
            try fileManager.removeItem(at: root)
        }
    }

    /// With every extension process stopped, only the published item and
    /// restore points can still be needed. This removes failed-apply orphans
    /// without guessing while a renderer may have a file open.
    func pruneUnpublishedItems(retaining selectedItemID: UUID?) throws {
        try queue.sync {
            guard fileManager.fileExists(atPath: root.path) else { return }
            var retained: Set<String> = []
            var retainedIDs: Set<UUID> = []
            if let current = reader.currentItem() {
                retainedIDs.insert(current.id)
                retained.formUnion(reader.assetURLs(for: current).map {
                    $0.standardizedFileURL.path
                })
            }
            if let selectedItemID, !retainedIDs.contains(selectedItemID) {
                // A partial earlier mutation can leave Wallpaper settings and
                // current.json out of sync. If its metadata is unavailable,
                // preserve everything rather than delete the selected video.
                guard let selected = reader.item(selectedItemID) else { return }
                retained.formUnion(reader.assetURLs(for: selected).map {
                    $0.standardizedFileURL.path
                })
            }
            retained.insert(reader.url(LivecoreLibraryFile.current).standardizedFileURL.path)
            retained.insert(lockScreenBackupURL.standardizedFileURL.path)
            retained.insert(legacyLockScreenBackupURL.standardizedFileURL.path)

            for url in try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                      !retained.contains(url.standardizedFileURL.path)
                else { continue }
                try fileManager.removeItem(at: url)
            }
        }
    }

    @MainActor
    private func desktopPictures() -> [(displayID: String, url: URL?)] {
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return (
                number?.stringValue ?? LivecoreLibraryFile.defaultDisplayKey,
                NSWorkspace.shared.desktopImageURL(for: screen)
            )
        }
    }

    /// The Desktop picture re-encoded as a JPEG, or nil when macOS has none to
    /// give. Decoding matters: the URL may name a video (aerial and dynamic
    /// wallpapers), and copying raw bytes into a `.jpg` would leave the
    /// renderer with a still it cannot load.
    private func desktopStill(at source: URL?) async -> Data? {
        // A library path is a Livecore video from an earlier apply, never the
        // Desktop the user chose.
        guard let source,
              !source.path.contains("/\(LivecoreLibraryFile.directoryName)/")
        else { return nil }

        if let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
            return image.livecoreJPEGData(quality: 0.9)
        }
        return try? await jpeg(from: source, at: .zero, maximumSize: nil)
    }

    private func inheritedStill(
        from item: LivecoreWallpaperItem?,
        displayID: String
    ) -> Data? {
        guard let item,
              let url = reader.desktopImageURL(for: item, displayID: displayID)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    private func jpeg(from url: URL, at time: CMTime, maximumSize: NSSize?) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        if let maximumSize { generator.maximumSize = maximumSize }
        guard let data = try await generator.image(at: time).image.livecoreJPEGData(quality: 0.9)
        else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    private func makeLibraryDirectory() throws {
        guard containerExists else { throw LivecoreProviderError.extensionContainerUnavailable }
        guard !fileManager.fileExists(atPath: root.path) else { return }
        // No intermediates: creating the container itself is macOS's job.
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
    }

}

private extension CGImage {
    func livecoreJPEGData(quality: Double) -> Data? {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.jpegRepresentation(
            of: CIImage(cgImage: self),
            colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}

struct LivecoreLockScreenState {
    let extensionInstalled: Bool
    let selectedProviderID: String?
    let selectedItemID: UUID?
    let assetsAvailable: Bool
    let rendererResponsive: Bool

    var isSelected: Bool { selectedProviderID != nil }
    var isApplied: Bool {
        extensionInstalled
            && selectedProviderID == WallpaperStoreManager.providerID
            && selectedItemID != nil
            && assetsAvailable
            && rendererResponsive
    }
}

private actor WallpaperMutationGate {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !isOccupied {
            isOccupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// One-shot listener for the extension's non-persistent renderer health
/// notifications. Nothing is written to disk and a stale process cannot make a
/// later app launch appear healthy.
private final class DistributedSignalWaiter: @unchecked Sendable {
    private let center = DistributedNotificationCenter.default()
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    init(name: Notification.Name, object: String?) {
        observer = center.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard object == nil || notification.object as? String == object else { return }
            self?.finish(true)
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    func wait(timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()

            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(false)
            }
        }
    }

    private func finish(_ value: Bool) {
        let continuation: CheckedContinuation<Bool, Never>?
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

/// Installs the wallpaper extension and owns every Lock Screen mutation.
///
/// Dashboard actions, quit teardown and fresh-install cleanup can overlap.
/// They all pass through the same gate so a late rollback cannot undo a newer
/// operation.
final class WallpaperStoreManager: @unchecked Sendable {
    static let shared = WallpaperStoreManager()

    static var providerID: String { LivecoreWallpaperLibrary.extensionBundleID }
    private static let legacyProviderIDs: Set<String> = [
        "com.livecore.app.wallpaper-extension.debug",
        "com.berkegulacar.Livecore.wallpaper-extension",
        "com.berkegulacar.Livecore.wallpaper-extension.debug",
    ]
    private static var knownProviderIDs: Set<String> {
        legacyProviderIDs.union([providerID])
    }

    private struct PluginRecord {
        let election: Character?
        let url: URL

        var isEnabled: Bool {
            guard let election else { return true }
            return election == "+" || election == "!"
        }
    }

    private let fileManager = FileManager.default
    private let mutationGate = WallpaperMutationGate()
    private var library: LivecoreWallpaperLibrary { .shared }
    private var embeddedExtensionURL: URL { LivecoreWallpaperLibrary.embeddedExtensionURL }

    // MARK: - State

    func isExtensionInstalled() throws -> Bool {
        try pluginRecords(for: Self.providerID).contains {
            $0.isEnabled && sameFile($0.url, embeddedExtensionURL)
        }
    }

    func lockScreenState() async throws -> LivecoreLockScreenState {
        let selection = try await PrivateWallpaperSettings.selection(
            providerIDs: Self.knownProviderIDs
        )
        let item: LivecoreWallpaperItem? = selection.flatMap { selection in
            guard selection.providerID == Self.providerID, let id = selection.itemID else {
                return nil
            }
            return library.item(withID: id)
        }
        let installed = try isExtensionInstalled()
        var rendererResponsive = false
        if installed, let item, library.itemIsUsable(item) {
            let waiter = DistributedSignalWaiter(
                name: LivecoreNotification.rendererReady,
                object: item.id.uuidString
            )
            notifyAssetsChanged()
            rendererResponsive = await waiter.wait(timeout: .seconds(2))
        }
        return LivecoreLockScreenState(
            extensionInstalled: installed,
            selectedProviderID: selection?.providerID,
            selectedItemID: selection?.itemID,
            assetsAvailable: item.map(library.itemIsUsable) ?? false,
            rendererResponsive: rendererResponsive
        )
    }

    // MARK: - Install / uninstall

    func installExtension() async throws {
        try await withMutation {
            try await self.installExtensionLocked()
        }
    }

    private func installExtensionLocked() async throws {
        guard fileManager.fileExists(atPath: embeddedExtensionURL.path) else {
            throw LivecoreProviderError.extensionMissingFromBundle
        }

        let selection = try await PrivateWallpaperSettings.selection(
            providerIDs: Self.knownProviderIDs
        )
        if let selection, selection.providerID != Self.providerID {
            try await deactivateLockScreenLocked()
        }

        try await recycleExtensionLocked(
            purgeLegacyLibrariesAfterExit: selection?.providerID != Self.providerID
        )
    }

    /// Forces WallpaperAgent off any stale executable before selecting the
    /// embedded record again. Apply uses this too, so Repair never requires the
    /// user to manually remove and reinstall the extension.
    private func recycleExtensionLocked(
        purgeLegacyLibrariesAfterExit: Bool = false
    ) async throws {
        let wasEnabled = try isExtensionInstalled()
        let currentSelection = try await PrivateWallpaperSettings.selection(
            providerIDs: [Self.providerID]
        )
        let shouldRestoreElection = wasEnabled
            || currentSelection?.providerID == Self.providerID

        // LaunchServices owns registration. Elections select the embedded
        // record; explicit registration would create a versionless PluginKit
        // stub that WallpaperAgent cannot launch.
        for identifier in Self.knownProviderIDs {
            _ = try? run("-e", "ignore", "-i", identifier)
        }
        do {
            guard await terminateExtensionProcesses() else {
                throw LivecoreProviderError.pluginKitFailed(
                    "The previous Livecore wallpaper extension process did not exit."
                )
            }
            if currentSelection == nil || currentSelection?.itemID != nil {
                try library.pruneUnpublishedItems(
                    retaining: currentSelection?.itemID
                )
            }
            try removeStalePluginRecords(keepEmbeddedCurrent: true)
            if purgeLegacyLibrariesAfterExit {
                try purgeLegacyLibraries()
            }
            try run("-e", "ignore", "-i", Self.providerID)
            try await Task.sleep(for: .milliseconds(250))
            try run("-e", "use", "-i", Self.providerID)

            guard try isExtensionInstalled() else {
                throw LivecoreProviderError.pluginKitFailed(
                    "macOS has not registered an extension for \(Bundle.main.bundleURL.path)."
                )
            }
            try await waitForExtensionContainer()
            notifyAssetsChanged()
        } catch {
            let operationError = error
            guard shouldRestoreElection else { throw operationError }
            _ = try? run("-e", "use", "-i", Self.providerID)
            try? await Task.sleep(for: .milliseconds(250))
            notifyAssetsChanged()
            guard (try? isExtensionInstalled()) == true else {
                throw LivecoreProviderError.pluginKitFailed(
                    "The extension refresh failed and its previous election could not be restored."
                )
            }
            throw operationError
        }
    }

    func uninstallExtension() async throws {
        try await withMutation {
            try await self.deactivateLockScreenLocked()
            for identifier in Self.knownProviderIDs {
                _ = try? self.run("-e", "ignore", "-i", identifier)
            }
            guard await self.terminateExtensionProcesses() else {
                throw LivecoreProviderError.pluginKitFailed(
                    "The Livecore wallpaper extension process did not exit, so its assets were kept."
                )
            }
            try self.removeStalePluginRecords(keepEmbeddedCurrent: true)
            try self.purgeAllLibraries()
            self.notifyAssetsChanged()
            guard try !self.isExtensionInstalled() else {
                throw LivecoreProviderError.pluginKitFailed("The extension stayed enabled.")
            }
        }
    }

    /// Runs once for each concrete installed executable. App deletion leaves
    /// UserDefaults, WallpaperAgent elections, extension processes and sandbox
    /// containers behind, so all four are treated as uninstall state.
    func resetForNewInstallation() async throws {
        try await withMutation {
            try await self.deactivateLockScreenLocked()
            for identifier in Self.knownProviderIDs {
                _ = try? self.run("-e", "ignore", "-i", identifier)
            }
            guard await self.terminateExtensionProcesses() else {
                throw LivecoreProviderError.pluginKitFailed(
                    "A previous Livecore wallpaper extension process did not exit, so its assets were kept."
                )
            }
            try self.removeStalePluginRecords(keepEmbeddedCurrent: true)
            try self.purgeAllLibraries()
            self.notifyAssetsChanged()
            guard try !self.isExtensionInstalled() else {
                throw LivecoreProviderError.pluginKitFailed(
                    "The previous extension election stayed enabled."
                )
            }
        }
    }

    private func waitForExtensionContainer() async throws {
        var lastRefreshError: Error?
        for _ in 0..<10 {
            let wasProvisioned = library.containerExists
            do {
                // Even a provisioned container gets one successful refresh so
                // WallpaperAgent observes the newly elected executable.
                try await PrivateWallpaperSettings.refreshViewModels()
                if library.containerExists { return }
            } catch {
                lastRefreshError = error
            }
            try await Task.sleep(
                for: wasProvisioned ? .milliseconds(100) : .milliseconds(500)
            )
        }
        if library.containerExists { return }
        if let lastRefreshError { throw lastRefreshError }
        throw LivecoreProviderError.extensionContainerUnavailable
    }

    // MARK: - Lock Screen

    func applyLockScreen(videoURL: URL) async throws {
        try await withMutation {
            try await self.applyLockScreenLocked(videoURL: videoURL)
        }
    }

    private func applyLockScreenLocked(videoURL: URL) async throws {
        guard try isExtensionInstalled() else { throw LivecoreProviderError.extensionNotInstalled }
        try await recycleExtensionLocked()

        let previousItem = library.currentItem()
        let beforeSettings = try await PrivateWallpaperSettings.captureSettings()
        let previousSelection = try await PrivateWallpaperSettings.selection(
            providerIDs: Self.knownProviderIDs
        )

        let item = try await library.prepareVideo(
            at: videoURL,
            inheritingDesktopFrom: previousItem
        )
        let ready = DistributedSignalWaiter(
            name: LivecoreNotification.rendererReady,
            object: item.id.uuidString
        )
        let failedItemRetired = DistributedSignalWaiter(
            name: LivecoreNotification.rendererRetired,
            object: item.id.uuidString
        )
        let previousItemWasSelected = previousSelection?.providerID == Self.providerID
            && previousSelection?.itemID == previousItem?.id
        let retired = previousItemWasSelected ? previousItem.map {
            DistributedSignalWaiter(
                name: LivecoreNotification.rendererRetired,
                object: $0.id.uuidString
            )
        } : nil
        var itemWasPublished = false

        do {
            // `prepareVideo` creates the library directory on a clean install.
            // Store the restore point only after that succeeds.
            let restorePoint: Data
            if previousSelection == nil {
                restorePoint = beforeSettings
            } else if let inheritedBackup = PrivateWallpaperSettings.firstRestorableBackup(
                from: backupDataCandidates(),
                rejectingProviderIDs: Self.knownProviderIDs
            ) {
                restorePoint = inheritedBackup
            } else {
                restorePoint = try PrivateWallpaperSettings.fallbackBackup()
            }
            try restorePoint.write(to: library.lockScreenBackupURL, options: .atomic)
            // Every legacy process was stopped during recycle and its only
            // valid restore point now lives in the current container.
            try purgeLegacyLibraries()
            try library.publish(item)
            itemWasPublished = true
            try await PrivateWallpaperSettings.apply(item: item, providerID: Self.providerID)
            guard try await selectionSettles(on: item.id, providerID: Self.providerID) else {
                throw LivecoreProviderError.lockScreenSelectionRejected
            }
            notifyAssetsChanged()
            guard await ready.wait(timeout: .seconds(8)) else {
                throw LivecoreProviderError.lockScreenRendererUnavailable
            }
        } catch {
            let operationError = error
            do {
                try await PrivateWallpaperSettings.restore(from: [beforeSettings])
                if let previousItem {
                    try library.publish(previousItem)
                } else {
                    try library.unpublish()
                }
                notifyAssetsChanged()
                let retiredAfterRollback = if itemWasPublished,
                                              extensionProcessesAreRunning() {
                    await failedItemRetired.wait(timeout: .seconds(7))
                } else {
                    true
                }
                if retiredAfterRollback {
                    library.discard(item)
                }
            } catch {
                // The new selection may still be live. Keep its current marker
                // and every asset rather than manufacturing a black wallpaper.
                notifyAssetsChanged()
                throw LivecoreProviderError.lockScreenRollbackFailed
            }
            throw operationError
        }

        guard let previousItem, previousItem.id != item.id else { return }
        let retiredAcknowledged = if let retired {
            await retired.wait(timeout: .seconds(7))
        } else {
            false
        }
        if !previousItemWasSelected
            || !extensionProcessesAreRunning()
            || retiredAcknowledged {
            library.discard(previousItem)
        }
    }

    private func selectionSettles(
        on expected: UUID,
        providerID: String,
        timeout: TimeInterval = 5
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var consecutiveMatches = 0
        repeat {
            if try await PrivateWallpaperSettings.selectionMatches(
                itemID: expected,
                providerID: providerID
            ) {
                consecutiveMatches += 1
                if consecutiveMatches == 3 { return true }
            } else {
                consecutiveMatches = 0
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }

    func deactivateLockScreen() async throws {
        try await withMutation {
            try await self.deactivateLockScreenLocked()
        }
    }

    private func deactivateLockScreenLocked() async throws {
        let selection = try await PrivateWallpaperSettings.selection(
            providerIDs: Self.knownProviderIDs
        )
        guard let selection else { return }
        let selectedItem: LivecoreWallpaperItem? = if selection.providerID == Self.providerID,
                                                      let itemID = selection.itemID {
            library.item(withID: itemID)
        } else {
            nil
        }

        let retired = selection.itemID.map {
            DistributedSignalWaiter(
                name: LivecoreNotification.rendererRetired,
                object: $0.uuidString
            )
        }
        try await PrivateWallpaperSettings.restore(
            from: backupDataCandidates(),
            rejectingProviderIDs: Self.knownProviderIDs
        )
        guard try await selectionLeavesKnownProviders() else {
            throw LivecoreProviderError.lockScreenSelectionRejected
        }

        removeBackupFiles()
        try? library.unpublish()
        notifyAssetsChanged()
        let retiredAcknowledged = if let retired {
            await retired.wait(timeout: .seconds(7))
        } else {
            false
        }
        if !extensionProcessesAreRunning() {
            try purgeAllLibraries()
        } else if retiredAcknowledged, let selectedItem {
            library.discard(selectedItem)
        }
    }

    private func selectionLeavesKnownProviders(timeout: TimeInterval = 5) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var consecutiveMatches = 0
        repeat {
            if try await PrivateWallpaperSettings.selection(
                providerIDs: Self.knownProviderIDs
            ) == nil {
                consecutiveMatches += 1
                if consecutiveMatches == 3 { return true }
            } else {
                consecutiveMatches = 0
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }

    // MARK: - Plumbing

    private func notifyAssetsChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            LivecoreNotification.assetsChanged,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func withMutation<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        await mutationGate.enter()
        do {
            let result = try await operation()
            await mutationGate.leave()
            return result
        } catch {
            await mutationGate.leave()
            throw error
        }
    }

    private func pluginRecords(for identifier: String) throws -> [PluginRecord] {
        let output = try run("-m", "-A", "-D", "-v", "-i", identifier)
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let path = fields.last.map(String.init), path.hasPrefix("/") else { return nil }
            let first = line.trimmingCharacters(in: .whitespaces).first
            let election = "+-!=?".contains(first ?? " ") ? first : nil
            return PluginRecord(election: election, url: URL(fileURLWithPath: path))
        }
    }

    private func removeStalePluginRecords(keepEmbeddedCurrent: Bool) throws {
        for identifier in Self.knownProviderIDs {
            for record in try pluginRecords(for: identifier) {
                if keepEmbeddedCurrent,
                   identifier == Self.providerID,
                   sameFile(record.url, embeddedExtensionURL) {
                    continue
                }
                let removedExplicitly = (try? run("-r", record.url.path)) != nil
                if let appURL = containingApplication(for: record.url) {
                    if sameFile(appURL, Bundle.main.bundleURL) {
                        guard removedExplicitly else {
                            throw LivecoreProviderError.pluginKitFailed(
                                "A legacy extension is still embedded in this Livecore app."
                            )
                        }
                    } else {
                        try runLaunchServices("-u", appURL.path)
                    }
                } else if !removedExplicitly {
                    throw LivecoreProviderError.pluginKitFailed(
                        "The stale extension at \(record.url.path) could not be unregistered."
                    )
                }
            }
        }

        let staleRecords = try Self.knownProviderIDs.flatMap { identifier in
            try pluginRecords(for: identifier).filter { record in
                !(keepEmbeddedCurrent
                    && identifier == Self.providerID
                    && sameFile(record.url, embeddedExtensionURL))
            }
        }
        guard staleRecords.isEmpty else {
            throw LivecoreProviderError.pluginKitFailed(
                "LaunchServices kept \(staleRecords.count) stale Livecore extension record(s)."
            )
        }
    }

    private func containingApplication(for extensionURL: URL) -> URL? {
        var candidate = extensionURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private func terminateExtensionProcesses() async -> Bool {
        for identifier in Self.knownProviderIDs {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: identifier
            ).forEach { $0.terminate() }
        }
        if await waitForExtensionProcessesToExit(timeout: 2) { return true }
        for identifier in Self.knownProviderIDs {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: identifier
            ).forEach { $0.forceTerminate() }
        }
        return await waitForExtensionProcessesToExit(timeout: 2)
    }

    private func waitForExtensionProcessesToExit(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !extensionProcessesAreRunning() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return !extensionProcessesAreRunning()
    }

    private func extensionProcessesAreRunning() -> Bool {
        Self.knownProviderIDs.contains { identifier in
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: identifier
            ).isEmpty
        }
    }

    private var backupURLs: [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        var urls = [library.lockScreenBackupURL, library.legacyLockScreenBackupURL]
        for identifier in Self.legacyProviderIDs {
            let root = home
                .appendingPathComponent(
                    "Library/Containers/\(identifier)/Data/Documents",
                    isDirectory: true
                )
                .appendingPathComponent(LivecoreLibraryFile.directoryName, isDirectory: true)
            urls.append(root.appendingPathComponent(LivecoreLibraryFile.lockScreenBackup))
            urls.append(root.appendingPathComponent("lock-screen-backup.plist"))
        }
        return urls
    }

    private func backupDataCandidates() -> [Data] {
        backupURLs.compactMap { try? Data(contentsOf: $0) }
    }

    private func removeBackupFiles() {
        for url in backupURLs where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func purgeAllLibraries() throws {
        try library.purge()
        try purgeLegacyLibraries()
    }

    private func purgeLegacyLibraries() throws {
        let home = fileManager.homeDirectoryForCurrentUser
        for identifier in Self.legacyProviderIDs {
            let root = home
                .appendingPathComponent(
                    "Library/Containers/\(identifier)/Data/Documents",
                    isDirectory: true
                )
                .appendingPathComponent(LivecoreLibraryFile.directoryName, isDirectory: true)
            if fileManager.fileExists(atPath: root.path) {
                try fileManager.removeItem(at: root)
            }
        }
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL
            == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    @discardableResult
    private func run(_ arguments: String...) throws -> String {
        try runProcess(
            executable: "/usr/bin/pluginkit",
            arguments: arguments
        )
    }

    @discardableResult
    private func runLaunchServices(_ arguments: String...) throws -> String {
        try runProcess(
            executable: "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                + "LaunchServices.framework/Support/lsregister",
            arguments: arguments
        )
    }

    private func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LivecoreProviderError.pluginKitFailed(
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }
}
