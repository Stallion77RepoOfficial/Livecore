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

    /// `WallpaperSettingsManager` initialises asynchronously and reports an
    /// empty value until WallpaperAgent has answered. Treating that empty value
    /// as the user's real wallpaper is what produced contentless restore points
    /// and made a live Livecore selection look unselected, so every read goes
    /// through here and a contentless snapshot is an error, never a fact.
    private static func currentSettings() async throws -> WallpaperUserSettings {
        let manager = WallpaperSettingsManager.shared
        var lastError: Error?
        for attempt in 0..<5 {
            do {
                try await manager.synchronize()
                let settings = manager.desktopWallpaperUserSettings
                if hasChoices(settings) { return settings }
            } catch {
                lastError = error
            }
            if attempt < 4 { try? await Task.sleep(for: .milliseconds(200)) }
        }
        throw lastError ?? LivecoreProviderError.wallpaperSettingsUnavailable
    }

    /// Snapshot of the wallpaper Livecore is about to replace, used as the
    /// restore point.
    static func captureSettings() async throws -> Data {
        try JSONEncoder().encode(BackupEnvelope(
            version: 1,
            settings: try await currentSettings()
        ))
    }

    static func apply(item: LivecoreWallpaperItem, providerID: String) async throws {
        try await refreshViewModels()

        let descriptor = WallpaperChoiceDescriptor(
            provider: WallpaperChoiceProviderID(rawValue: providerID),
            files: [LivecoreWallpaperLibrary.shared.root.appendingPathComponent(item.fileName)],
            configuration: Data(item.id.uuidString.utf8)
        )
        let choice = WallpaperChoice.ID(descriptor: descriptor)
        try await update(
            .allDisplays(WallpaperContentSettings(
                choices: [choice],
                useAsDesktopWallpaperAndIdleWallpaper: false
            )),
            accept: { selects([choice], in: $0) }
        )
    }

    /// Restores the first semantically valid backup. Missing, corrupt,
    /// contentless, pre-Codable, and known-dead Livecore provider backups fall
    /// through to the next candidate, then to the macOS default.
    static func restore(
        from backups: [Data],
        rejectingProviderIDs: Set<String> = []
    ) async throws {
        let settings = backups.lazy.compactMap {
            restorableSettings(from: $0, rejectingProviderIDs: rejectingProviderIDs)
        }.first ?? systemDefaultSettings()

        try await update(settings) { actual in
            guard hasChoices(actual) else { return false }
            if restored(settings, in: actual) { return true }
            // macOS resolves the `default` provider to a concrete picture of
            // its own, so an exact match is not always reachable. Once the
            // rejected providers are gone the restore has done its job.
            return !rejectingProviderIDs.isEmpty
                && !containsProvider(in: actual, ids: rejectingProviderIDs)
        }
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
    /// Throws rather than reporting "nothing selected" when macOS will not hand
    /// over a readable wallpaper.
    static func selection(providerIDs: Set<String>) async throws -> LivecoreWallpaperSelection? {
        for content in contents(in: try await currentSettings()) {
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

    /// Writes `settings` and waits for macOS to report a state `accept` is
    /// happy with. macOS normalises what it stores — an all-displays write can
    /// come back per-display-space — so acceptance is semantic rather than an
    /// equality check against what was written.
    private static func update(
        _ settings: WallpaperUserSettings,
        accept: (WallpaperUserSettings) -> Bool
    ) async throws {
        let manager = WallpaperSettingsManager.shared
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try await manager.updateDesktopWallpaperUserSettings(settings)
                try await manager.synchronize()
                if accept(manager.desktopWallpaperUserSettings) { return }
            } catch {
                lastError = error
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw lastError ?? LivecoreProviderError.lockScreenSelectionRejected
    }

    /// True when every display scope selects all of `expected`. Used for an
    /// apply, which deliberately puts the same choice on every display.
    private static func selects(
        _ expected: [WallpaperChoice.ID],
        in settings: WallpaperUserSettings
    ) -> Bool {
        let scopes = contents(in: settings)
        guard !scopes.isEmpty, !expected.isEmpty else { return false }
        return scopes.allSatisfy { scope in
            expected.allSatisfy(scope.choices.contains)
        }
    }

    /// True when `actual` is the wallpaper `requested` describes. A restore can
    /// carry a different picture per display, so scopes are matched by key
    /// rather than flattened; macOS may also normalise between the two shapes,
    /// which the last branch tolerates.
    private static func restored(
        _ requested: WallpaperUserSettings,
        in actual: WallpaperUserSettings
    ) -> Bool {
        switch (requested, actual) {
        case (.allDisplays(let wanted), .allDisplays(let live)):
            return wanted.choices == live.choices
        case (.perDisplaySpace(let wanted), .perDisplaySpace(let live)):
            return !wanted.isEmpty && wanted.allSatisfy { scope, content in
                live[scope]?.choices == content.choices
            }
        default:
            let wanted = Set(contents(in: requested).flatMap(\.choices))
            let scopes = contents(in: actual)
            guard !wanted.isEmpty, !scopes.isEmpty else { return false }
            return scopes.allSatisfy { scope in
                !scope.choices.isEmpty && scope.choices.allSatisfy(wanted.contains)
            }
        }
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
        // A contentless backup restores nothing: writing it back leaves the
        // Livecore selection in place and macOS then falls back on its own.
        guard let candidate,
              hasChoices(candidate),
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

    /// False for the value the settings manager reports before WallpaperAgent
    /// has answered, and for any snapshot that names no wallpaper at all.
    private static func hasChoices(_ settings: WallpaperUserSettings) -> Bool {
        contents(in: settings).contains { !$0.choices.isEmpty }
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
}
