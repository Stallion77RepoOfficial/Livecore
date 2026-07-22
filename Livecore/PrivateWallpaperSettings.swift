import Foundation
import Wallpaper
import WallpaperTypes

/// Type-safe bridge to the private framework used by the macOS Wallpaper pane.
/// The local interface files expose only the ABI surface Livecore needs.
@available(macOS 14.0, *)
@MainActor
enum PrivateWallpaperSettings {
    private struct BackupEnvelope: Codable {
        let version: Int
        let settings: WallpaperUserSettings
    }

    static func captureDesktopSettings() async throws -> Data {
        let manager = WallpaperSettingsManager.shared
        try await manager.synchronize()
        return try encode(manager.desktopWallpaperUserSettings)
    }

    static func apply(item: LivecoreWallpaperItem, providerID: String) async throws {
        try await refreshDesktopViewModel()

        let manager = WallpaperSettingsManager.shared
        let videoURL = LivecoreWallpaperLibrary.shared.root.appendingPathComponent(item.fileName)
        let descriptor = WallpaperChoiceDescriptor(
            provider: WallpaperChoiceProviderID(rawValue: providerID),
            files: [videoURL],
            configuration: Data(item.id.uuidString.utf8)
        )
        let content = WallpaperContentSettings(
            choices: [.init(descriptor: descriptor)],
            useAsDesktopWallpaperAndIdleWallpaper: false
        )
        try await manager.updateDesktopWallpaperUserSettings(.allDisplays(content))
        try await manager.synchronize()
    }

    static func refreshDesktopViewModel() async throws {
        let manager = WallpaperSettingsManager.shared
        try await manager.synchronize()
        // The private framework does not export a standalone `.desktop` case
        // accessor, but its CaseIterable order is desktop, then screen saver.
        try await manager.ensureViewModelIsUpToDate(
            contentTypes: Array(ContentType.allCases.prefix(1)),
            reason: .wallpaperInstallation
        )
        try await manager.synchronize()
    }

    static func restoreDesktopSettings(from backupData: Data?) async throws {
        let manager = WallpaperSettingsManager.shared
        try await manager.synchronize()
        let restored = decode(backupData)
            ?? legacyStoreSettings(from: backupData)
            ?? systemDefaultSettings()
        try await manager.updateDesktopWallpaperUserSettings(restored)
        try await manager.synchronize()
    }

    static func restoreSnapshot(from data: Data) async throws {
        guard let settings = decode(data) else {
            throw LivecoreProviderError.invalidWallpaperStore
        }
        let manager = WallpaperSettingsManager.shared
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try await manager.updateDesktopWallpaperUserSettings(settings)
                try await manager.synchronize()
                if settingsEqual(manager.desktopWallpaperUserSettings, settings) { return }
            } catch {
                lastError = error
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw lastError ?? LivecoreProviderError.wallpaperStoreChanged
    }

    static func selectionMatches(itemID: UUID, providerID: String) async throws -> Bool {
        let manager = WallpaperSettingsManager.shared
        try await manager.synchronize()
        return containsChoice(
            in: manager.desktopWallpaperUserSettings,
            providerID: providerID,
            configuration: Data(itemID.uuidString.utf8)
        )
    }

    static func hasAnyProvider(_ ids: Set<String>) async throws -> Bool {
        let manager = WallpaperSettingsManager.shared
        try await manager.synchronize()
        return containsProvider(in: manager.desktopWallpaperUserSettings, ids: ids)
    }

    static func fallbackBackup() throws -> Data { try encode(systemDefaultSettings()) }

    private static func encode(_ settings: WallpaperUserSettings) throws -> Data {
        try JSONEncoder().encode(BackupEnvelope(version: 1, settings: settings))
    }

    private static func decode(_ data: Data?) -> WallpaperUserSettings? {
        guard let data else { return nil }
        if let envelope = try? JSONDecoder().decode(BackupEnvelope.self, from: data),
           envelope.version == 1 {
            return envelope.settings
        }
        return try? JSONDecoder().decode(WallpaperUserSettings.self, from: data)
    }

    private static func systemDefaultSettings() -> WallpaperUserSettings {
        let descriptor = WallpaperChoiceDescriptor(
            provider: WallpaperChoiceProviderID(rawValue: "default"),
            files: [],
            configuration: Data()
        )
        return .allDisplays(WallpaperContentSettings(
            choices: [.init(descriptor: descriptor)],
            useAsDesktopWallpaperAndIdleWallpaper: true
        ))
    }

    private static func legacyStoreSettings(from data: Data?) -> WallpaperUserSettings? {
        guard let data,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let scope = root["AllSpacesAndDisplays"] as? [String: Any]
        else { return nil }

        let isLinked = scope["Type"] as? String == "linked"
        let recordKey = isLinked ? "Linked" : "Desktop"
        guard let record = scope[recordKey] as? [String: Any],
              let content = record["Content"] as? [String: Any],
              let rawChoices = content["Choices"] as? [[String: Any]]
        else { return nil }

        let choices = rawChoices.compactMap { raw -> WallpaperChoice.ID? in
            guard let provider = raw["Provider"] as? String else { return nil }
            let configuration = raw["Configuration"] as? Data ?? Data()
            let files = (raw["Files"] as? [Any] ?? []).compactMap { value -> URL? in
                if let string = value as? String { return URL(string: string) }
                if let dictionary = value as? [String: Any],
                   let relative = dictionary["relative"] as? String {
                    return URL(string: relative)
                }
                return nil
            }
            return WallpaperChoice.ID(descriptor: WallpaperChoiceDescriptor(
                provider: WallpaperChoiceProviderID(rawValue: provider),
                files: files,
                configuration: configuration
            ))
        }
        guard !choices.isEmpty else { return nil }
        return .allDisplays(WallpaperContentSettings(
            choices: choices,
            useAsDesktopWallpaperAndIdleWallpaper: isLinked
        ))
    }

    private static func containsChoice(
        in settings: WallpaperUserSettings,
        providerID: String,
        configuration: Data
    ) -> Bool {
        contents(in: settings).contains { content in
            !content.useAsDesktopWallpaperAndIdleWallpaper
                && content.choices.contains {
                    $0.descriptor.provider.rawValue == providerID
                        && $0.descriptor.configuration == configuration
                }
        }
    }

    private static func containsProvider(
        in settings: WallpaperUserSettings,
        ids: Set<String>
    ) -> Bool {
        contents(in: settings).contains { content in
            content.choices.contains { ids.contains($0.descriptor.provider.rawValue) }
        }
    }

    private static func contents(in settings: WallpaperUserSettings) -> [WallpaperContentSettings] {
        switch settings {
        case .allDisplays(let content):
            return [content]
        case .perDisplaySpace(let settings):
            return Array(settings.values)
        @unknown default:
            return []
        }
    }

    private static func settingsEqual(
        _ lhs: WallpaperUserSettings,
        _ rhs: WallpaperUserSettings
    ) -> Bool {
        switch (lhs, rhs) {
        case (.allDisplays(let left), .allDisplays(let right)):
            return left == right
        case (.perDisplaySpace(let left), .perDisplaySpace(let right)):
            return left == right
        default:
            return false
        }
    }
}
