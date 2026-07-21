import AppKit
import AVFoundation

enum AerialIntegrationError: LocalizedError {
    case directoryUnavailable
    case noAssets
    case ffmpegUnavailable
    case invalidTarget
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable: return "The Apple Aerial directory is unavailable. Download an Aerial in System Settings first."
        case .noAssets: return "No downloaded Aerial movie could be found."
        case .ffmpegUnavailable: return "HEVC conversion requires ffmpeg. Install it with Homebrew first."
        case .invalidTarget: return "The selected target is outside the trusted Aerial directory."
        case .conversionFailed(let message): return "HEVC conversion failed: \(message)"
        }
    }
}

final class AerialIntegration {
    static let shared = AerialIntegration()
    private let previousSystemWallpaperKey = "aerial.previousSystemWallpaperURL"
    private let activeAssetKey = "aerial.activeAssetID"

    let userDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    let legacyDirectory = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true)

    var availableDirectory: URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: userDirectory.path) { return userDirectory }
        if fm.fileExists(atPath: legacyDirectory.path) { return legacyDirectory }
        return nil
    }

    func assets() throws -> [URL] {
        guard let directory = availableDirectory else { throw AerialIntegrationError.directoryUnavailable }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw AerialIntegrationError.noAssets }

        let urls = enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension.lowercased() == "mov" && !$0.lastPathComponent.contains(".livecore-backup.")
        }
        guard !urls.isEmpty else { throw AerialIntegrationError.noAssets }
        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func displayName(for assetURL: URL) -> String {
        guard let root = availableDirectory else { return assetURL.deletingPathExtension().lastPathComponent }
        let manifestURL = root.appendingPathComponent("manifest/entries.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = rootObject["assets"] as? [[String: Any]] else {
            return assetURL.deletingPathExtension().lastPathComponent
        }
        let identifier = assetURL.deletingPathExtension().lastPathComponent
        guard let entry = assets.first(where: { $0["id"] as? String == identifier }) else { return identifier }
        let label = (entry["accessibilityLabel"] as? String) ?? (entry["localizedNameKey"] as? String) ?? "Apple Aerial"
        return "\(label) · \(identifier.prefix(8))"
    }

    func revealDirectory() throws {
        guard let directory = availableDirectory else { throw AerialIntegrationError.directoryUnavailable }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func isSelectedByWallpaperStore(_ assetURL: URL) -> Bool {
        let index = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: index) else { return false }
        let identifier = assetURL.deletingPathExtension().lastPathComponent
        let providerMarkers = ["com.apple.wallpaper.aerial", "com.apple.wallpaper.extension.aerials"]
        let hasProvider = providerMarkers.contains { data.range(of: Data($0.utf8)) != nil }
        return hasProvider && data.range(of: Data(identifier.utf8)) != nil
    }

    func openWallpaperSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func install(source: URL, replacing target: URL) throws -> URL {
        guard let root = availableDirectory,
              target.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw AerialIntegrationError.invalidTarget
        }

        let fm = FileManager.default
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: fm.isExecutableFile(atPath:))
        guard let ffmpeg else { throw AerialIntegrationError.ffmpegUnavailable }

        let temporary = fm.temporaryDirectory.appendingPathComponent("Livecore-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: temporary) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y", "-i", source.path,
            "-map", "0:v:0",
            "-vf", "scale=3840:2160:force_original_aspect_ratio=increase,crop=3840:2160,format=p010le,fps=240",
            "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-tag:v", "hvc1",
            "-pix_fmt", "p010le", "-an", "-movflags", "+faststart", temporary.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw AerialIntegrationError.conversionFailed(String(data: data, encoding: .utf8) ?? "Unknown error")
        }

        let thumbnail = root.appendingPathComponent("thumbnails").appendingPathComponent(target.deletingPathExtension().lastPathComponent).appendingPathExtension("png")
        let temporaryThumbnail = fm.temporaryDirectory.appendingPathComponent("Livecore-\(UUID().uuidString).png")
        defer { try? fm.removeItem(at: temporaryThumbnail) }
        let thumbnailProcess = Process()
        thumbnailProcess.executableURL = URL(fileURLWithPath: ffmpeg)
        thumbnailProcess.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", temporary.path, "-frames:v", "1", temporaryThumbnail.path]
        try thumbnailProcess.run()
        thumbnailProcess.waitUntilExit()

        let backup = target.deletingPathExtension().appendingPathExtension("livecore-backup.mov")
        if !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: target, to: backup)
        }
        _ = try fm.replaceItemAt(target, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
        if thumbnailProcess.terminationStatus == 0, fm.fileExists(atPath: thumbnail.path) {
            let thumbnailBackup = thumbnail.deletingPathExtension().appendingPathExtension("livecore-backup.png")
            if !fm.fileExists(atPath: thumbnailBackup.path) {
                try fm.copyItem(at: thumbnail, to: thumbnailBackup)
            }
            _ = try fm.replaceItemAt(thumbnail, withItemAt: temporaryThumbnail, backupItemName: nil, options: .usingNewMetadataOnly)
        }
        activateSystemWallpaper(target)
        UserDefaults.standard.set(target.deletingPathExtension().lastPathComponent, forKey: activeAssetKey)
        return backup
    }

    func restoreActiveInstallation() {
        guard let identifier = UserDefaults.standard.string(forKey: activeAssetKey),
              let target = try? assets().first(where: { $0.deletingPathExtension().lastPathComponent == identifier }) else { return }
        try? restore(target: target)
        refreshWallpaperProcesses()
    }

    func reapplyActiveInstallation(source: URL) throws {
        guard let identifier = UserDefaults.standard.string(forKey: activeAssetKey),
              let target = try assets().first(where: { $0.deletingPathExtension().lastPathComponent == identifier }) else { return }
        _ = try install(source: source, replacing: target)
        refreshWallpaperProcesses()
    }

    func restore(target: URL) throws {
        let backup = target.deletingPathExtension().appendingPathExtension("livecore-backup.mov")
        guard FileManager.default.fileExists(atPath: backup.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        _ = try FileManager.default.replaceItemAt(target, withItemAt: backup, backupItemName: nil)
        if let root = availableDirectory {
            let thumbnail = root.appendingPathComponent("thumbnails").appendingPathComponent(target.deletingPathExtension().lastPathComponent).appendingPathExtension("png")
            let thumbnailBackup = thumbnail.deletingPathExtension().appendingPathExtension("livecore-backup.png")
            if FileManager.default.fileExists(atPath: thumbnailBackup.path) {
                _ = try FileManager.default.replaceItemAt(thumbnail, withItemAt: thumbnailBackup, backupItemName: nil)
            }
        }
        restoreSystemWallpaper()
    }

    private func activateSystemWallpaper(_ target: URL) {
        let domain = "com.apple.wallpaper" as CFString
        let key = "SystemWallpaperURL" as CFString
        if UserDefaults.standard.string(forKey: previousSystemWallpaperKey) == nil,
           let previous = CFPreferencesCopyAppValue(key, domain) as? String {
            UserDefaults.standard.set(previous, forKey: previousSystemWallpaperKey)
        }
        CFPreferencesSetAppValue(key, target.absoluteString as CFString, domain)
        CFPreferencesAppSynchronize(domain)
    }

    private func restoreSystemWallpaper() {
        guard let previous = UserDefaults.standard.string(forKey: previousSystemWallpaperKey) else { return }
        let domain = "com.apple.wallpaper" as CFString
        CFPreferencesSetAppValue("SystemWallpaperURL" as CFString, previous as CFString, domain)
        CFPreferencesAppSynchronize(domain)
        UserDefaults.standard.removeObject(forKey: previousSystemWallpaperKey)
    }

    func refreshWallpaperProcesses() {
        // macOS 26 uses the ExtensionKit Aerials provider. Older releases used
        // WallpaperVideoExtension, so refresh both generations plus the image
        // provider that can retain the lock-screen poster in memory.
        for name in [
            "WallpaperAerialsExtension",
            "WallpaperImageExtension",
            "WallpaperVideoExtension",
            "WallpaperAgent"
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [name]
            try? process.run()
        }
    }
}
