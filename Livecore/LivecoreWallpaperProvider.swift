import AppKit
import AVFoundation
import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LivecoreProviderError: LocalizedError {
    case wallpaperStoreUnavailable
    case invalidWallpaperStore
    case wallpaperStoreChanged
    case pluginNotInstalled
    case pluginRegistrationFailed(String)
    case lockScreenSelectionUnavailable
    case rendererDidNotStart
    case desktopCaptureFailed(String)
    case rollbackFailed(String)
    case unsupportedSystem

    var errorDescription: String? {
        switch self {
        case .wallpaperStoreUnavailable:
            return "The macOS wallpaper store could not be found."
        case .invalidWallpaperStore:
            return "The macOS wallpaper store has an unexpected format."
        case .wallpaperStoreChanged:
            return "macOS changed the wallpaper while Livecore was applying it. Please try again."
        case .pluginNotInstalled:
            return "The current Livecore wallpaper extension build is not installed."
        case .pluginRegistrationFailed(let detail):
            return "The Livecore wallpaper extension could not be registered. \(detail)"
        case .lockScreenSelectionUnavailable:
            return "macOS rejected the Livecore Lock Screen selection."
        case .rendererDidNotStart:
            return "The Livecore renderer did not start, so the previous wallpaper was restored."
        case .desktopCaptureFailed(let display):
            return "The current Desktop image could not be captured for display \(display). Nothing was changed."
        case .rollbackFailed(let detail):
            return "The wallpaper change failed and macOS could not confirm the rollback. Livecore kept the video files so the screen cannot go black. \(detail)"
        case .unsupportedSystem:
            return "Livecore Lock Screen wallpapers require macOS 14.0 or later."
        }
    }

    var mustPreservePublishedItem: Bool {
        if case .rollbackFailed = self { return true }
        return false
    }
}

struct LivecoreWallpaperItem: Codable, Equatable {
    let id: UUID
    let fileName: String
    let title: String
    let createdAt: Date
    let desktopImageFileNames: [String: String]?

    init(
        id: UUID,
        fileName: String,
        title: String,
        createdAt: Date,
        desktopImageFileNames: [String: String]? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.title = title
        self.createdAt = createdAt
        self.desktopImageFileNames = desktopImageFileNames
    }
}

private struct LivecorePlaybackState: Codable {
    let enabled: Bool
    let updatedAt: Date
}

private struct LivecoreRendererReadyState: Codable {
    let itemID: UUID
    let updatedAt: Date
    let runtimeBuild: String
}

private struct LivecoreSettingsReadyState: Codable {
    let itemID: UUID
    let updatedAt: Date
    let runtimeBuild: String
}

private struct DesktopImageSource {
    let displayID: String
    let url: URL?
}

final class LivecoreWallpaperLibrary: @unchecked Sendable {
    static let shared = LivecoreWallpaperLibrary()
    static let releaseExtensionBundleID = "com.berkegulacar.Livecore.wallpaper-extension"

    static var extensionBundleID: String {
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/LivecoreWallpaperExtension.appex")
        return Bundle(url: extensionURL)?.bundleIdentifier ?? releaseExtensionBundleID
    }

    static var extensionRuntimeBuild: String {
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/LivecoreWallpaperExtension.appex")
        let bundle = Bundle(url: extensionURL)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        guard let executableName = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else {
            return "\(version):missing-executable"
        }
        let executableDirectory = extensionURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let debugLibrary = executableDirectory.appendingPathComponent("\(executableName).debug.dylib")
        let executable = executableDirectory.appendingPathComponent(executableName)
        let codeURL = FileManager.default.fileExists(atPath: debugLibrary.path) ? debugLibrary : executable
        return "\(version):\(machOUUID(at: codeURL) ?? "unreadable-code")"
    }

    /// Read the linker-generated UUID from the exact extension image that the
    /// current app embeds. The extension reports the UUID of the image actually
    /// loaded in its process, so a stale Xcode process cannot impersonate a
    /// freshly rebuilt extension merely by sharing CFBundleVersion and path.
    private static func machOUUID(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 32 else {
            return nil
        }
        func uint32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data[offset..<(offset + 4)].withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            }
        }
        guard uint32(at: 0) == 0xfeedfacf, let commandCount = uint32(at: 16) else {
            return nil
        }
        var offset = 32
        for _ in 0..<commandCount {
            guard let command = uint32(at: offset),
                  let commandSizeValue = uint32(at: offset + 4)
            else { return nil }
            let commandSize = Int(commandSizeValue)
            guard commandSize >= 8, offset <= data.count - commandSize else { return nil }
            if command == 0x1b, commandSize >= 24 {
                let bytes = data[(offset + 8)..<(offset + 24)]
                let hex = bytes.map { String(format: "%02X", $0) }.joined()
                return [
                    String(hex.prefix(8)),
                    String(hex.dropFirst(8).prefix(4)),
                    String(hex.dropFirst(12).prefix(4)),
                    String(hex.dropFirst(16).prefix(4)),
                    String(hex.dropFirst(20).prefix(12)),
                ].joined(separator: "-")
            }
            offset += commandSize
        }
        return nil
    }

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "com.livecore.app").wallpaper-library", qos: .default)

    var root: URL {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(Self.extensionBundleID)/Data/Documents/WallpaperLibrary",
                isDirectory: true
            )
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var lockScreenBackupURL: URL { root.appendingPathComponent("lock-screen-backup.plist") }
    var rendererReadyURL: URL { root.appendingPathComponent("renderer-ready.json") }
    var settingsReadyURL: URL { root.appendingPathComponent("settings-ready.json") }

    func prepareVideo(
        at source: URL,
        inheritingDesktopFrom previousItem: LivecoreWallpaperItem? = nil
    ) throws -> LivecoreWallpaperItem {
        // AppKit must be queried on the main thread. Capture these URLs before
        // taking the library queue so the main thread can never wait on that
        // queue while a background preparation waits on main.sync.
        let desktopSources = desktopImageSources()
        return try queue.sync {
            let itemID = UUID()
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
            let fileName = "\(itemID.uuidString).\(ext)"
            let destination = root.appendingPathComponent(fileName)
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }

            var createdURLs: [URL] = []
            do {
                try fileManager.copyItem(at: source, to: destination)
                createdURLs.append(destination)

                let thumbnailURL = root.appendingPathComponent("\(itemID.uuidString).jpg")
                try makeThumbnail(for: destination, at: thumbnailURL)
                createdURLs.append(thumbnailURL)

                let backgrounds = try copyDesktopBackgrounds(
                    for: itemID,
                    inheritingFrom: previousItem,
                    desktopSources: desktopSources,
                    createdURLs: &createdURLs
                )
                let item = LivecoreWallpaperItem(
                    id: itemID,
                    fileName: fileName,
                    title: source.deletingPathExtension().lastPathComponent,
                    createdAt: Date(),
                    desktopImageFileNames: backgrounds.isEmpty ? nil : backgrounds
                )
                let metadataURL = itemMetadataURL(item.id)
                try JSONEncoder().encode(item).write(to: metadataURL, options: .atomic)
                createdURLs.append(metadataURL)
                return item
            } catch {
                createdURLs.forEach { try? fileManager.removeItem(at: $0) }
                throw error
            }
        }
    }

    @discardableResult
    func importVideo(at source: URL) throws -> LivecoreWallpaperItem {
        let previous = currentItem()
        let item = try prepareVideo(at: source, inheritingDesktopFrom: previous)
        do {
            try publish(item, playbackEnabled: true)
            return item
        } catch {
            discard(item)
            throw error
        }
    }

    func publish(_ item: LivecoreWallpaperItem, playbackEnabled: Bool) throws {
        try queue.sync {
            guard itemIsUsableLocked(item) else { throw CocoaError(.fileReadNoSuchFile) }
            try JSONEncoder().encode(item).write(to: itemMetadataURL(item.id), options: .atomic)
            try JSONEncoder().encode(item).write(to: root.appendingPathComponent("current.json"), options: .atomic)
            try writePlaybackStateLocked(playbackEnabled)
            try? fileManager.removeItem(at: rendererReadyURL)
            try? fileManager.removeItem(at: settingsReadyURL)
        }
    }

    func restore(_ item: LivecoreWallpaperItem?, playbackEnabled: Bool) {
        queue.sync {
            let currentURL = root.appendingPathComponent("current.json")
            if let item, itemIsUsableLocked(item), let data = try? JSONEncoder().encode(item) {
                try? data.write(to: currentURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: currentURL)
            }
            try? writePlaybackStateLocked(playbackEnabled)
            try? fileManager.removeItem(at: rendererReadyURL)
            try? fileManager.removeItem(at: settingsReadyURL)
        }
    }

    func discard(_ item: LivecoreWallpaperItem) {
        queue.sync {
            guard currentItemLocked()?.id != item.id else { return }
            assetURLs(for: item).forEach { try? fileManager.removeItem(at: $0) }
        }
    }

    func removeObsoleteAssets(keeping item: LivecoreWallpaperItem) {
        queue.sync {
            let preserved = Set(assetURLs(for: item).map(\.lastPathComponent) + [
                "current.json", "playback-state.json", "renderer-ready.json", "settings-ready.json",
                "lock-screen-backup.plist",
            ])
            for url in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where !preserved.contains(url.lastPathComponent) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func currentItem() -> LivecoreWallpaperItem? { queue.sync { currentItemLocked() } }

    func item(withID id: UUID) -> LivecoreWallpaperItem? {
        queue.sync {
            if let data = try? Data(contentsOf: itemMetadataURL(id)),
               let item = try? JSONDecoder().decode(LivecoreWallpaperItem.self, from: data) {
                return item
            }
            let current = currentItemLocked()
            return current?.id == id ? current : nil
        }
    }

    func itemIsUsable(_ item: LivecoreWallpaperItem) -> Bool { queue.sync { itemIsUsableLocked(item) } }

    func setPlaybackEnabled(_ enabled: Bool) throws {
        try queue.sync { try writePlaybackStateLocked(enabled) }
    }

    func clearRendererReadyMarker() {
        queue.sync { try? fileManager.removeItem(at: rendererReadyURL) }
    }

    func clearSettingsReadyMarker() {
        queue.sync { try? fileManager.removeItem(at: settingsReadyURL) }
    }

    func rendererIsReady(for itemID: UUID, since date: Date) -> Bool {
        queue.sync {
            guard let data = try? Data(contentsOf: rendererReadyURL),
                  let state = try? JSONDecoder().decode(LivecoreRendererReadyState.self, from: data)
            else { return false }
            return state.itemID == itemID
                && state.updatedAt >= date
                && state.runtimeBuild == Self.extensionRuntimeBuild
        }
    }

    func rendererWasConfirmed(for itemID: UUID) -> Bool {
        rendererIsReady(for: itemID, since: .distantPast)
    }

    func settingsModelIsReady(for itemID: UUID, since date: Date) -> Bool {
        queue.sync {
            guard let data = try? Data(contentsOf: settingsReadyURL),
                  let state = try? JSONDecoder().decode(LivecoreSettingsReadyState.self, from: data)
            else { return false }
            return state.itemID == itemID
                && state.updatedAt >= date
                && state.runtimeBuild == Self.extensionRuntimeBuild
        }
    }

    func purge() {
        queue.sync { try? fileManager.removeItem(at: root) }
    }

    private func currentItemLocked() -> LivecoreWallpaperItem? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("current.json")) else { return nil }
        return try? JSONDecoder().decode(LivecoreWallpaperItem.self, from: data)
    }

    private func itemMetadataURL(_ id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json")
    }

    private func assetURLs(for item: LivecoreWallpaperItem) -> [URL] {
        var urls = [
            root.appendingPathComponent(item.fileName),
            root.appendingPathComponent("\(item.id.uuidString).jpg"),
            itemMetadataURL(item.id),
        ]
        urls.append(contentsOf: (item.desktopImageFileNames ?? [:]).values.map { root.appendingPathComponent($0) })
        return urls
    }

    private func itemIsUsableLocked(_ item: LivecoreWallpaperItem) -> Bool {
        guard fileManager.fileExists(atPath: root.appendingPathComponent(item.fileName).path),
              fileManager.fileExists(atPath: root.appendingPathComponent("\(item.id.uuidString).jpg").path),
              let desktopFiles = item.desktopImageFileNames,
              desktopFiles["default"] != nil
        else { return false }
        return desktopFiles.values.allSatisfy {
            fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    private func writePlaybackStateLocked(_ enabled: Bool) throws {
        let state = LivecorePlaybackState(enabled: enabled, updatedAt: Date())
        try JSONEncoder().encode(state).write(
            to: root.appendingPathComponent("playback-state.json"),
            options: .atomic
        )
    }

    private func copyDesktopBackgrounds(
        for itemID: UUID,
        inheritingFrom previousItem: LivecoreWallpaperItem?,
        desktopSources: [DesktopImageSource],
        createdURLs: inout [URL]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        guard !desktopSources.isEmpty else {
            throw LivecoreProviderError.desktopCaptureFailed("unknown")
        }

        for source in desktopSources {
            let displayID = source.displayID
            if let previousName = previousItem?.desktopImageFileNames?[displayID] {
                let source = root.appendingPathComponent(previousName)
                if fileManager.fileExists(atPath: source.path) {
                    let name = "\(itemID.uuidString).desktop.\(displayID).jpg"
                    let destination = root.appendingPathComponent(name)
                    try fileManager.copyItem(at: source, to: destination)
                    createdURLs.append(destination)
                    result[displayID] = name
                    continue
                }
            }
            guard let sourceURL = source.url,
                  let data = desktopImageData(at: sourceURL)
            else { throw LivecoreProviderError.desktopCaptureFailed(displayID) }
            let name = "\(itemID.uuidString).desktop.\(displayID).jpg"
            let destination = root.appendingPathComponent(name)
            try data.write(to: destination, options: .atomic)
            createdURLs.append(destination)
            result[displayID] = name
        }
        guard let primaryDisplayID = desktopSources.first?.displayID,
              let fallbackName = result[primaryDisplayID]
        else { throw LivecoreProviderError.desktopCaptureFailed("default") }
        // A display connected after Apply has no captured display ID yet. Give
        // it a deliberate primary-display still instead of a black renderer.
        result["default"] = fallbackName
        return result
    }

    private func desktopImageSources() -> [DesktopImageSource] {
        let collect = {
            NSScreen.screens.map { screen -> DesktopImageSource in
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                return DesktopImageSource(
                    displayID: number?.stringValue ?? "default",
                    url: NSWorkspace.shared.desktopImageURL(for: screen)
                )
            }
        }
        if Thread.isMainThread { return collect() }
        return DispatchQueue.main.sync(execute: collect)
    }

    private func desktopImageData(at source: URL) -> Data? {
        if let data = try? Data(contentsOf: source), !data.isEmpty {
            return data
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.jpegRepresentation(
            of: ciImage,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        )
    }

    private func makeThumbnail(for videoURL: URL, at destination: URL) throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 960, height: 540)
        let cgImage = try generator.copyCGImage(
            at: CMTime(seconds: 0.1, preferredTimescale: 600),
            actualTime: nil
        )
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let data = context.jpegRepresentation(
            of: ciImage,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.82]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: destination, options: .atomic)
    }
}

struct LivecoreLockScreenState {
    let pluginInstalled: Bool
    let selectedConfiguration: UUID?
    let hasRestorePoint: Bool
    let assetsAvailable: Bool
    let rendererConfirmed: Bool

    var isSelected: Bool { selectedConfiguration != nil }
    var isHealthy: Bool { pluginInstalled && isSelected && assetsAvailable && rendererConfirmed }
    var canStop: Bool { isSelected || hasRestorePoint }
}

private actor WallpaperMutationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class WallpaperStoreManager: @unchecked Sendable {
    static let shared = WallpaperStoreManager()

    private struct ProcessResult {
        let status: Int32
        let output: String
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
    private let queue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "com.livecore.app").wallpaper-lifecycle", qos: .default)
    private let mutationGate = WallpaperMutationGate()

    static var providerID: String { LivecoreWallpaperLibrary.extensionBundleID }
    private static var knownProviderIDs: Set<String> {
        [providerID, LivecoreWallpaperLibrary.releaseExtensionBundleID]
    }

    private var storeURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private var embeddedExtensionURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions/LivecoreWallpaperExtension.appex")
    }

    func isPluginInstalled() -> Bool {
        pluginRecords(for: Self.providerID).contains {
            sameFile($0.url, embeddedExtensionURL) && $0.isEnabled
        }
    }

    func lockScreenState() -> LivecoreLockScreenState {
        queue.sync {
            let configuration = (try? readStore()).flatMap(selectedLivecoreDesktopConfiguration)
            let item = configuration.flatMap(LivecoreWallpaperLibrary.shared.item(withID:))
            return LivecoreLockScreenState(
                pluginInstalled: isPluginInstalled(),
                selectedConfiguration: configuration,
                hasRestorePoint: fileManager.fileExists(atPath: LivecoreWallpaperLibrary.shared.lockScreenBackupURL.path),
                assetsAvailable: item.map(LivecoreWallpaperLibrary.shared.itemIsUsable) ?? false,
                rendererConfirmed: item.map {
                    LivecoreWallpaperLibrary.shared.rendererWasConfirmed(for: $0.id)
                } ?? false
            )
        }
    }

    func isLockScreenActive() -> Bool { lockScreenState().isHealthy }

    func refreshWallpaperSettings() { notifyWallpaperChanged() }

    func installPlugin() async throws {
        guard #available(macOS 14.0, *) else { throw LivecoreProviderError.unsupportedSystem }
        try queue.sync {
            let extensionURL = embeddedExtensionURL
            guard fileManager.fileExists(atPath: extensionURL.path) else {
                throw LivecoreProviderError.pluginRegistrationFailed("The embedded extension is missing.")
            }
            let launchServices = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            _ = runProcess(launchServices, ["-f", Bundle.main.bundleURL.path])
            let registration = runProcess("/usr/bin/pluginkit", ["-a", extensionURL.path])
            guard registration.status == 0 else {
                throw LivecoreProviderError.pluginRegistrationFailed(registration.output)
            }
            let enable = runProcess("/usr/bin/pluginkit", ["-e", "use", "-i", Self.providerID])
            guard enable.status == 0 else {
                throw LivecoreProviderError.pluginRegistrationFailed(enable.output)
            }

            for _ in 0..<30 {
                if isPluginInstalled() {
                    let hasManagedSelection = (try? readStore())
                        .flatMap(selectedLivecoreDesktopConfiguration) != nil
                    unregisterObsoletePluginRecords(
                        keeping: extensionURL,
                        includeAlternateProviders: !hasManagedSelection
                    )
                    guard isPluginInstalled() else {
                        throw LivecoreProviderError.pluginRegistrationFailed(
                            "PluginKit discarded the extension from the current app build."
                        )
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw LivecoreProviderError.pluginRegistrationFailed(
                "PluginKit did not enable the extension embedded in this app build."
            )
        }
        if LivecoreWallpaperLibrary.shared.currentItem() != nil {
            do {
                try await refreshWallpaperSettingsModel(attempts: 2)
            } catch {
                try await recyclePluginRegistration()
                try await refreshWallpaperSettingsModel(attempts: 5)
            }
        }
    }

    func refreshWallpaperSettingsModel() async throws {
        try await refreshWallpaperSettingsModel(attempts: 5)
    }

    private func refreshWallpaperSettingsModel(attempts: Int) async throws {
        guard #available(macOS 14.0, *) else { throw LivecoreProviderError.unsupportedSystem }
        guard isPluginInstalled() else { throw LivecoreProviderError.pluginNotInstalled }
        guard let item = LivecoreWallpaperLibrary.shared.currentItem(),
              LivecoreWallpaperLibrary.shared.itemIsUsable(item)
        else { throw LivecoreProviderError.rendererDidNotStart }

        let startedAt = Date()
        LivecoreWallpaperLibrary.shared.clearSettingsReadyMarker()
        for _ in 0..<attempts {
            notifyWallpaperChanged()
            try await PrivateWallpaperSettings.refreshDesktopViewModel()
            if await waitForSettingsModel(item.id, since: startedAt, timeout: 2) {
                notifyWallpaperChanged()
                return
            }
        }
        throw LivecoreProviderError.pluginRegistrationFailed(
            "WallpaperAgent did not load the provider model from the current extension build."
        )
    }

    private func recyclePluginRegistration() async throws {
        try queue.sync {
            let disable = runProcess("/usr/bin/pluginkit", ["-e", "ignore", "-i", Self.providerID])
            guard disable.status == 0 else {
                throw LivecoreProviderError.pluginRegistrationFailed(disable.output)
            }
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            try queue.sync {
                let registration = runProcess("/usr/bin/pluginkit", ["-a", embeddedExtensionURL.path])
                guard registration.status == 0 else {
                    throw LivecoreProviderError.pluginRegistrationFailed(registration.output)
                }
                let enable = runProcess("/usr/bin/pluginkit", ["-e", "use", "-i", Self.providerID])
                guard enable.status == 0 else {
                    throw LivecoreProviderError.pluginRegistrationFailed(enable.output)
                }
            }
            // Re-enabling causes ExtensionKit to retire the disabled process.
            // Give that handoff one event-loop turn before requesting a model.
            try await Task.sleep(for: .milliseconds(350))
            guard isPluginInstalled() else {
                throw LivecoreProviderError.pluginRegistrationFailed(
                    "PluginKit did not re-enable the extension after refreshing it."
                )
            }
        } catch {
            let recycleError = error
            // Never leave the provider elected "ignore". Best-effort repair
            // preserves an already selected Livecore renderer even when the
            // new build itself could not be registered.
            let providerRecovered = queue.sync {
                _ = runProcess("/usr/bin/pluginkit", ["-a", embeddedExtensionURL.path])
                let enable = runProcess("/usr/bin/pluginkit", ["-e", "use", "-i", Self.providerID])
                guard enable.status == 0 else { return false }
                for _ in 0..<10 {
                    if pluginRecords(for: Self.providerID).contains(where: \.isEnabled) {
                        return true
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                return false
            }
            guard providerRecovered else {
                throw LivecoreProviderError.rollbackFailed(
                    "PluginKit could not re-enable the provider after a refresh failure. "
                        + recycleError.localizedDescription
                )
            }
            throw recycleError
        }
    }

    func uninstallPlugin() async throws {
        await mutationGate.enter()
        do {
            try await deactivateLockScreenLocked()
            try queue.sync {
                for identifier in Self.knownProviderIDs {
                    let disable = runProcess("/usr/bin/pluginkit", ["-e", "ignore", "-i", identifier])
                    guard disable.status == 0 else {
                        throw LivecoreProviderError.pluginRegistrationFailed(disable.output)
                    }
                    for record in pluginRecords(for: identifier) {
                        _ = runProcess("/usr/bin/pluginkit", ["-r", record.url.path])
                    }
                }
                for _ in 0..<20 where isPluginInstalled() {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                guard !isPluginInstalled() else {
                    throw LivecoreProviderError.pluginRegistrationFailed("PluginKit kept the extension enabled.")
                }
                LivecoreWallpaperLibrary.shared.purge()
                notifyWallpaperChanged()
            }
            await mutationGate.leave()
        } catch {
            await mutationGate.leave()
            throw error
        }
    }

    func activateLockScreen(item: LivecoreWallpaperItem) async throws {
        guard #available(macOS 14.0, *) else { throw LivecoreProviderError.unsupportedSystem }
        await mutationGate.enter()
        do {
            guard isPluginInstalled() else { throw LivecoreProviderError.pluginNotInstalled }
            guard LivecoreWallpaperLibrary.shared.itemIsUsable(item) else {
                throw LivecoreProviderError.rendererDidNotStart
            }

            let previousSettings = try await PrivateWallpaperSettings.captureDesktopSettings()
            let backupURL = LivecoreWallpaperLibrary.shared.lockScreenBackupURL
            let previousBackup = try? Data(contentsOf: backupURL)
            let wasManaged = (try? await PrivateWallpaperSettings.hasAnyProvider(Self.knownProviderIDs)) == true
            let previousManagedConfiguration = (try? readStore())
                .flatMap(selectedLivecoreDesktopConfiguration)
            if !wasManaged {
                try previousSettings.write(to: backupURL, options: .atomic)
            } else if previousBackup == nil {
                try await PrivateWallpaperSettings.fallbackBackup().write(
                    to: backupURL,
                    options: .atomic
                )
            }

            let activationDate = Date()
            LivecoreWallpaperLibrary.shared.clearRendererReadyMarker()
            do {
                try await PrivateWallpaperSettings.apply(item: item, providerID: Self.providerID)
                notifyWallpaperChanged()
                guard await waitForStableSelection(item.id, timeout: 8) else {
                    throw LivecoreProviderError.lockScreenSelectionUnavailable
                }
                guard await waitForRenderer(item.id, since: activationDate, timeout: 10) else {
                    throw LivecoreProviderError.rendererDidNotStart
                }
                LivecoreWallpaperLibrary.shared.removeObsoleteAssets(keeping: item)
                queue.sync {
                    unregisterObsoletePluginRecords(
                        keeping: embeddedExtensionURL,
                        includeAlternateProviders: true
                    )
                }
            } catch {
                let activationError = error
                do {
                    try await PrivateWallpaperSettings.restoreSnapshot(from: previousSettings)
                    notifyWallpaperChanged()
                    guard await waitForRollbackSelection(
                        previousManagedConfiguration,
                        timeout: 4
                    ) else { throw LivecoreProviderError.wallpaperStoreChanged }
                    restoreBackupFile(previousBackup, at: backupURL)
                } catch {
                    // Keep the newly published item and the original restore
                    // point. Deleting them while macOS may still reference the
                    // new UUID is exactly what produces a black Lock Screen.
                    notifyWallpaperChanged()
                    throw LivecoreProviderError.rollbackFailed(error.localizedDescription)
                }
                throw activationError
            }
            await mutationGate.leave()
        } catch {
            await mutationGate.leave()
            throw error
        }
    }

    func deactivateLockScreen() async throws {
        guard #available(macOS 14.0, *) else { throw LivecoreProviderError.unsupportedSystem }
        await mutationGate.enter()
        do {
            try await deactivateLockScreenLocked()
            await mutationGate.leave()
        } catch {
            await mutationGate.leave()
            throw error
        }
    }

    private func deactivateLockScreenLocked() async throws {
        guard #available(macOS 14.0, *) else { throw LivecoreProviderError.unsupportedSystem }
        let backupURL = LivecoreWallpaperLibrary.shared.lockScreenBackupURL
        let backup = try? Data(contentsOf: backupURL)
        let hadManagedSelection = (try? await PrivateWallpaperSettings.hasAnyProvider(Self.knownProviderIDs)) == true
        guard hadManagedSelection || backup != nil else {
            try? LivecoreWallpaperLibrary.shared.setPlaybackEnabled(false)
            return
        }

        let before = try await PrivateWallpaperSettings.captureDesktopSettings()
        let previousManagedConfiguration = (try? readStore())
            .flatMap(selectedLivecoreDesktopConfiguration)

        do {
            try await PrivateWallpaperSettings.restoreDesktopSettings(from: backup)
            notifyWallpaperChanged()
            guard await waitForNoLivecoreSelection(timeout: 8) else {
                throw LivecoreProviderError.lockScreenSelectionUnavailable
            }
            try LivecoreWallpaperLibrary.shared.setPlaybackEnabled(false)
            try? fileManager.removeItem(at: backupURL)
            LivecoreWallpaperLibrary.shared.clearRendererReadyMarker()
        } catch {
            let deactivationError = error
            do {
                try await PrivateWallpaperSettings.restoreSnapshot(from: before)
                notifyWallpaperChanged()
                guard await waitForRollbackSelection(
                    previousManagedConfiguration,
                    timeout: 4
                ) else { throw LivecoreProviderError.wallpaperStoreChanged }
                if hadManagedSelection {
                    try LivecoreWallpaperLibrary.shared.setPlaybackEnabled(true)
                }
            } catch {
                notifyWallpaperChanged()
                throw LivecoreProviderError.rollbackFailed(error.localizedDescription)
            }
            throw deactivationError
        }
    }

    private func selectedLivecoreDesktopConfiguration(in root: [String: Any]) -> UUID? {
        livecoreConfiguration(in: root, desktopOnly: true)
    }

    private func livecoreConfiguration(in value: Any?, desktopOnly: Bool) -> UUID? {
        if let dictionary = value as? [String: Any] {
            if let provider = dictionary["Provider"] as? String,
               Self.knownProviderIDs.contains(provider),
               let data = dictionary["Configuration"] as? Data,
               let string = String(data: data, encoding: .utf8),
               let id = UUID(uuidString: string) {
                return id
            }
            if desktopOnly {
                if let id = livecoreConfiguration(in: dictionary["Desktop"], desktopOnly: false)
                    ?? livecoreConfiguration(in: dictionary["Linked"], desktopOnly: false) {
                    return id
                }
                return dictionary.compactMap { key, nested -> UUID? in
                    guard key != "Idle" && key != "SystemDefault" else { return nil }
                    return livecoreConfiguration(in: nested, desktopOnly: true)
                }.first
            }
            return dictionary.values.compactMap {
                livecoreConfiguration(in: $0, desktopOnly: false)
            }.first
        }
        if let array = value as? [Any] {
            return array.compactMap { livecoreConfiguration(in: $0, desktopOnly: false) }.first
        }
        return nil
    }

    @available(macOS 14.0, *)
    private func waitForStableSelection(_ itemID: UUID, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var stableReads = 0
        while Date() < deadline {
            let frameworkMatches = (try? await PrivateWallpaperSettings.selectionMatches(
                itemID: itemID,
                providerID: Self.providerID
            )) == true
            if frameworkMatches,
               let root = try? readStore(),
               selectedLivecoreDesktopConfiguration(in: root) == itemID {
                stableReads += 1
                if stableReads >= 8 { return true }
            } else {
                stableReads = 0
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func waitForRenderer(_ itemID: UUID, since date: Date, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if LivecoreWallpaperLibrary.shared.rendererIsReady(for: itemID, since: date) { return true }
            if let root = try? readStore(), selectedLivecoreDesktopConfiguration(in: root) != itemID { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func waitForSettingsModel(
        _ itemID: UUID,
        since date: Date,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if LivecoreWallpaperLibrary.shared.settingsModelIsReady(for: itemID, since: date) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @available(macOS 14.0, *)
    private func waitForNoLivecoreSelection(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var stableReads = 0
        while Date() < deadline {
            let frameworkIsClear = (try? await PrivateWallpaperSettings.hasAnyProvider(
                Self.knownProviderIDs
            )) == false
            if frameworkIsClear,
               let root = try? readStore(),
               selectedLivecoreDesktopConfiguration(in: root) == nil {
                stableReads += 1
                if stableReads >= 6 { return true }
            } else {
                stableReads = 0
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func waitForRollbackSelection(
        _ expectedConfiguration: UUID?,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var stableReads = 0
        while Date() < deadline {
            do {
                let root = try readStore()
                let actual = selectedLivecoreDesktopConfiguration(in: root)
                if actual == expectedConfiguration {
                    stableReads += 1
                    if stableReads >= 4 { return true }
                } else {
                    stableReads = 0
                }
            } catch {
                // A missing/corrupt store is unknown, never evidence that a
                // rollback to an expected nil selection succeeded.
                stableReads = 0
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func readStore() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw LivecoreProviderError.wallpaperStoreUnavailable
        }
        let data = try Data(contentsOf: storeURL)
        guard let root = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: Any] else { throw LivecoreProviderError.invalidWallpaperStore }
        return root
    }

    private func restoreBackupFile(_ data: Data?, at url: URL) {
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? fileManager.removeItem(at: url)
        }
    }

    private func notifyWallpaperChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.wallpaper.changed"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.berkegulacar.Livecore.assets-changed"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            darwinCenter,
            CFNotificationName("com.apple.wallpaper.changed" as CFString),
            nil,
            nil,
            true
        )
        CFNotificationCenterPostNotification(
            darwinCenter,
            CFNotificationName("com.berkegulacar.Livecore.assets-changed" as CFString),
            nil,
            nil,
            true
        )
    }

    private func pluginRecords(for identifier: String) -> [PluginRecord] {
        let result = runProcess("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", identifier])
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let path = fields.last.map(String.init), path.hasPrefix("/") else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let first = trimmed.first
            let election: Character? = ["+", "-", "!", "=", "?"].contains(first.map(String.init) ?? "")
                ? first
                : nil
            return PluginRecord(election: election, url: URL(fileURLWithPath: path))
        }
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL
            == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    /// ExtensionKit may keep launching a previously built copy when several
    /// registrations share one bundle identifier. Keep the verified embedded
    /// copy registered first, then remove only obsolete paths so there is never
    /// a provider-registration gap.
    private func unregisterObsoletePluginRecords(
        keeping currentURL: URL,
        includeAlternateProviders: Bool
    ) {
        for record in pluginRecords(for: Self.providerID)
        where !sameFile(record.url, currentURL) {
            _ = runProcess("/usr/bin/pluginkit", ["-r", record.url.path])
        }
        guard includeAlternateProviders else { return }
        for identifier in Self.knownProviderIDs where identifier != Self.providerID {
            _ = runProcess("/usr/bin/pluginkit", ["-e", "ignore", "-i", identifier])
            for record in pluginRecords(for: identifier) {
                _ = runProcess("/usr/bin/pluginkit", ["-r", record.url.path])
            }
        }
    }

    @discardableResult
    private func runProcess(_ path: String, _ arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessResult(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return ProcessResult(status: -1, output: error.localizedDescription)
        }
    }
}
