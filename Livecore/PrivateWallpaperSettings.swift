import Foundation
import Wallpaper
import WallpaperTypes

struct LivecoreWallpaperSelection {
    let providerID: String
    let itemID: UUID?
}

/// Type-safe bridge to the private framework behind the macOS Wallpaper pane.
/// The local interface files in `PrivateModules` expose only the ABI surface
/// Livecore needs.
///
/// macOS has no wallpaper slot of its own for the Lock Screen: the Lock Screen
/// renders whatever the Desktop slot holds. Livecore therefore takes the
/// Desktop slot, and the extension paints the user's previous Desktop picture
/// whenever the screen is unlocked so the Desktop still looks untouched.
enum PrivateWallpaperSettings {
    private struct BackupEnvelope: Codable {
        let version: Int
        let settings: WallpaperUserSettings
    }

    /// Snapshot of the wallpaper Livecore is about to replace, used as the
    /// restore point.
    static func captureSettings() async throws -> Data {
        let manager = WallpaperSettingsManager.shared
        try await manager.synchronize()
        return try JSONEncoder().encode(BackupEnvelope(
            version: 1,
            settings: manager.desktopWallpaperUserSettings
        ))
    }

    static func apply(item: LivecoreWallpaperItem, providerID: String) async throws {
        try await refreshViewModels()

        let descriptor = WallpaperChoiceDescriptor(
            provider: WallpaperChoiceProviderID(rawValue: providerID),
            files: [LivecoreWallpaperLibrary.shared.root.appendingPathComponent(item.fileName)],
            configuration: Data(item.id.uuidString.utf8)
        )
        try await update(.allDisplays(WallpaperContentSettings(
            choices: [.init(descriptor: descriptor)],
            useAsDesktopWallpaperAndIdleWallpaper: false
        )))
    }

    /// Restores the first semantically valid backup. Missing, corrupt,
    /// pre-Codable, and known-dead Livecore provider backups fall through to
    /// the next candidate, then to the macOS default.
    static func restore(
        from backups: [Data],
        rejectingProviderIDs: Set<String> = []
    ) async throws {
        let settings = backups.lazy.compactMap {
            restorableSettings(from: $0, rejectingProviderIDs: rejectingProviderIDs)
        }.first ?? systemDefaultSettings()
        try await update(settings)
    }

    static func firstRestorableBackup(
        from backups: [Data],
        rejectingProviderIDs: Set<String>
    ) -> Data? {
        backups.first {
            restorableSettings(
                from: $0,
                rejectingProviderIDs: rejectingProviderIDs
            ) != nil
        }
    }

    static func fallbackBackup() throws -> Data {
        try JSONEncoder().encode(BackupEnvelope(
            version: 1,
            settings: systemDefaultSettings()
        ))
    }

    /// Makes WallpaperAgent re-read the Desktop provider list, which is also
    /// what launches a newly registered wallpaper extension for the first time.
    static func refreshViewModels() async throws {
        let manager = WallpaperSettingsManager.shared
        try await manager.synchronize()
        try await manager.ensureViewModelIsUpToDate(
            contentTypes: Array(ContentType.allCases.prefix(1)),
            reason: .wallpaperInstallation
        )
        try await manager.synchronize()
    }

    /// The first selected choice owned by one of `providerIDs`. A nil item ID
    /// still represents a managed selection whose old configuration is corrupt.
    static func selection(providerIDs: Set<String>) async throws -> LivecoreWallpaperSelection? {
        let manager = WallpaperSettingsManager.shared
        try await manager.synchronize()
        for content in contents(in: manager.desktopWallpaperUserSettings) {
            for choice in content.choices {
                let providerID = choice.descriptor.provider.rawValue
                guard providerIDs.contains(providerID) else { continue }
                let itemID = String(
                    data: choice.descriptor.configuration,
                    encoding: .utf8
                ).flatMap(UUID.init(uuidString:))
                return LivecoreWallpaperSelection(providerID: providerID, itemID: itemID)
            }
        }
        return nil
    }

    static func selectionMatches(itemID: UUID, providerID: String) async throws -> Bool {
        let selection = try await selection(providerIDs: [providerID])
        return selection?.providerID == providerID && selection?.itemID == itemID
    }

    private static func update(_ settings: WallpaperUserSettings) async throws {
        let manager = WallpaperSettingsManager.shared
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try await manager.updateDesktopWallpaperUserSettings(settings)
                try await manager.synchronize()
                if settingsEqual(manager.desktopWallpaperUserSettings, settings) {
                    return
                }
            } catch {
                lastError = error
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw lastError ?? LivecoreProviderError.lockScreenSelectionRejected
    }

    private static func decode(_ data: Data?) -> WallpaperUserSettings? {
        guard let data else { return nil }
        if let envelope = try? JSONDecoder().decode(BackupEnvelope.self, from: data),
           envelope.version == 1 {
            return envelope.settings
        }
        return try? JSONDecoder().decode(WallpaperUserSettings.self, from: data)
    }

    private static func restorableSettings(
        from data: Data,
        rejectingProviderIDs: Set<String>
    ) -> WallpaperUserSettings? {
        let candidate = decode(data) ?? legacyStoreSettings(from: data)
        guard let candidate,
              !containsProvider(in: candidate, ids: rejectingProviderIDs)
        else { return nil }
        return candidate
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

    /// Earliest Livecore builds copied the wallpaper Store plist directly.
    /// Decode only the choice fields needed to escape such a legacy restore
    /// point; newer backups use `BackupEnvelope`.
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
                configuration: raw["Configuration"] as? Data ?? Data()
            ))
        }
        guard !choices.isEmpty else { return nil }
        return .allDisplays(WallpaperContentSettings(
            choices: choices,
            useAsDesktopWallpaperAndIdleWallpaper: isLinked
        ))
    }

    private static func contents(in settings: WallpaperUserSettings) -> [WallpaperContentSettings] {
        switch settings {
        case .allDisplays(let content):
            return [content]
        case .perDisplaySpace(let perDisplay):
            return Array(perDisplay.values)
        @unknown default:
            return []
        }
    }

    private static func containsProvider(
        in settings: WallpaperUserSettings,
        ids: Set<String>
    ) -> Bool {
        guard !ids.isEmpty else { return false }
        return contents(in: settings).contains { content in
            content.choices.contains { ids.contains($0.descriptor.provider.rawValue) }
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
