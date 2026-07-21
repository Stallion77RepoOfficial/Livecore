import AppKit
import AVFoundation
import Foundation

enum LivecoreProviderError: LocalizedError {
    case sharedContainerUnavailable
    case wallpaperStoreUnavailable
    case invalidWallpaperStore
    case pluginNotInstalled

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable: return "Livecore's wallpaper container is unavailable."
        case .wallpaperStoreUnavailable: return "The macOS wallpaper store could not be found."
        case .invalidWallpaperStore: return "The macOS wallpaper store has an unexpected format."
        case .pluginNotInstalled: return "Lock Screen extension is not installed. Tap \"Install Extension\" first."
        }
    }
}

struct LivecoreWallpaperItem: Codable {
    let id: UUID
    let fileName: String
    let title: String
    let createdAt: Date
}

// MARK: - LivecoreWallpaperLibrary

final class LivecoreWallpaperLibrary {
    static let shared = LivecoreWallpaperLibrary()
    static let extensionBundleID = "com.berkegulacar.Livecore.wallpaper-extension"

    /// Fixed UUID — single slot
    static let fixedUUID = UUID(uuidString: "DEADBEEF-1111-2222-3333-444444444444")!

    private let fileManager = FileManager.default

    var root: URL {
        let path = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(Self.extensionBundleID)/Data/Documents/WallpaperLibrary", isDirectory: true)
        try? fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    func importVideo(at source: URL) throws -> LivecoreWallpaperItem {
        let r = root
        try fileManager.createDirectory(at: r, withIntermediateDirectories: true)

        let id = Self.fixedUUID
        let extensionName = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let fileName = "\(id.uuidString).\(extensionName)"
        let destination = r.appendingPathComponent(fileName)

        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        removeSlotFiles(in: r)
        try fileManager.copyItem(at: source, to: destination)

        let item = LivecoreWallpaperItem(
            id: id,
            fileName: fileName,
            title: source.deletingPathExtension().lastPathComponent,
            createdAt: Date()
        )
        let data = try JSONEncoder().encode(item)
        try data.write(to: r.appendingPathComponent("current.json"), options: .atomic)

        makeThumbnail(for: destination, at: r.appendingPathComponent("\(id.uuidString).jpg"))
        return item
    }

    func currentItem() -> LivecoreWallpaperItem? {
        let path = root.appendingPathComponent("current.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(LivecoreWallpaperItem.self, from: data)
    }

    func videoURL(for item: LivecoreWallpaperItem) -> URL? {
        let url = root.appendingPathComponent(item.fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func purge() {
        removeSlotFiles(in: root)
    }

    private func removeSlotFiles(in dir: URL) {
        guard let entries = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in entries { try? fileManager.removeItem(at: file) }
        let tmpDir = URL(fileURLWithPath: "/private/tmp/LivecoreThumbnails", isDirectory: true)
        if let tmpEntries = try? fileManager.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) {
            for file in tmpEntries { try? fileManager.removeItem(at: file) }
        }
    }

    private func makeThumbnail(for videoURL: URL, at destination: URL) {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 640, height: 360)
        guard let image = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil),
              let rep = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else { return }
        try? rep.write(to: destination, options: .atomic)

        // Write to /private/tmp/LivecoreThumbnails/
        let tmpDir = URL(fileURLWithPath: "/private/tmp/LivecoreThumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpURL = tmpDir.appendingPathComponent(destination.lastPathComponent)
        try? rep.write(to: tmpURL, options: .atomic)
    }
}

// MARK: - WallpaperStoreManager

final class WallpaperStoreManager {
    static let shared = WallpaperStoreManager()
    static let providerID = "com.berkegulacar.Livecore.wallpaper-extension"

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.berkegulacar.Livecore.wallpaper-store")

    private var storeURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private var backupURL: URL {
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Livecore", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("LockScreenBackup.plist")
    }

    func isPluginInstalled() -> Bool {
        let out = runProcess("/usr/bin/pluginkit", ["-m", "-i", Self.providerID])
        return out.contains("+")
    }

    func installPlugin() {
        let ext = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Extensions/LivecoreWallpaperExtension.appex")
        guard fileManager.fileExists(atPath: ext) else { return }
        runProcess("/usr/bin/pluginkit", ["-a", ext])
        runProcess("/usr/bin/pluginkit", ["-e", "use", "-i", Self.providerID])
    }

    func uninstallPlugin() {
        restoreLockScreen()
        purgeFromStore()
        LivecoreWallpaperLibrary.shared.purge()
        killProcess("LivecoreWallpaperExtension")

        runProcess("/usr/bin/pluginkit", ["-e", "ignore", "-i", Self.providerID])
        runProcess("/usr/bin/pluginkit", ["-r", "-i", Self.providerID])

        refreshWallpaperServices()
        killProcess("System Settings")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshWallpaperServices()
        }
    }

    func activateLockScreen(item: LivecoreWallpaperItem) throws {
        guard isPluginInstalled() else { throw LivecoreProviderError.pluginNotInstalled }
        try queue.sync {
            var root = try readStore()

            // Backup if not exists and root clean of Livecore
            if !fileManager.fileExists(atPath: backupURL.path) {
                if !hasLivecoreEntries(dict: root),
                   let data = try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) {
                    try? data.write(to: backupURL, options: .atomic)
                }
            }

            let choice: [String: Any] = [
                "Configuration": Data(item.id.uuidString.utf8),
                "Files": [] as [Any],
                "Provider": Self.providerID,
            ]
            injectChoice(choice, section: "Idle", dict: &root)
            try writeStore(root)

            killProcess("LivecoreWallpaperExtension")
            refreshWallpaperServices()
        }
    }

    func restoreLockScreen() {
        queue.sync {
            if fileManager.fileExists(atPath: backupURL.path),
               let bData = try? Data(contentsOf: backupURL),
               let backup = try? PropertyListSerialization.propertyList(from: bData, format: nil) as? [String: Any],
               var current = try? readStore() {
                restoreIdle(from: backup, into: &current)
                try? writeStore(current)
                try? fileManager.removeItem(at: backupURL)
            }
            purgeFromStore()
        }
    }

    private func hasLivecoreEntries(dict: [String: Any]) -> Bool {
        for k in dict.keys {
            if let sec = dict[k] as? [String: Any] {
                if let content = sec["Content"] as? [String: Any],
                   let choices = content["Choices"] as? [[String: Any]],
                   choices.contains(where: { ($0["Provider"] as? String)?.contains("Livecore") == true }) {
                    return true
                }
                if hasLivecoreEntries(dict: sec) { return true }
            }
        }
        return false
    }

    private func injectChoice(_ choice: [String: Any], section key: String, dict: inout [String: Any]) {
        let now = Date()
        for k in Array(dict.keys) {
            if k == "Linked", let linkedSec = dict["Linked"] as? [String: Any] {
                // Split Linked -> Desktop (original) and Idle (Livecore)
                var idleContent = (linkedSec["Content"] as? [String: Any]) ?? [:]
                idleContent["Choices"] = [choice]

                let desktopSec = linkedSec
                var idleSec = linkedSec
                idleSec["Content"] = idleContent
                idleSec["LastSet"] = now
                idleSec["LastUse"] = now

                dict["Desktop"] = desktopSec
                dict["Idle"] = idleSec
                dict.removeValue(forKey: "Linked")
                if dict["Type"] as? String == "linked" {
                    dict["Type"] = "custom"
                }
            } else if k == key, var sec = dict[k] as? [String: Any] {
                var content = (sec["Content"] as? [String: Any]) ?? [:]
                content["Choices"] = [choice]
                sec["Content"] = content
                sec["LastSet"] = now; sec["LastUse"] = now
                dict[k] = sec
            } else if var nested = dict[k] as? [String: Any] {
                injectChoice(choice, section: key, dict: &nested)
                dict[k] = nested
            }
        }
    }

    private func restoreIdle(from backup: [String: Any], into current: inout [String: Any]) {
        for k in Array(backup.keys) {
            if k == "Linked", let bLinked = backup["Linked"] {
                current["Linked"] = bLinked
                current["Type"] = backup["Type"] ?? "linked"
                current.removeValue(forKey: "Desktop")
                current.removeValue(forKey: "Idle")
            } else if k == "Idle", let bIdle = backup["Idle"] {
                current["Idle"] = bIdle
            } else if var cNested = current[k] as? [String: Any], let bNested = backup[k] as? [String: Any] {
                restoreIdle(from: bNested, into: &cNested)
                current[k] = cNested
            }
        }
    }

    private func purgeFromStore() {
        guard var root = try? readStore() else { return }
        if purgeRecursive(&root) { try? writeStore(root) }
        try? fileManager.removeItem(at: backupURL)
        refreshWallpaperServices()
    }

    @discardableResult
    private func purgeRecursive(_ dict: inout [String: Any]) -> Bool {
        var changed = false
        for k in Array(dict.keys) {
            if var sec = dict[k] as? [String: Any] {
                if let content = sec["Content"] as? [String: Any],
                   let choices = content["Choices"] as? [[String: Any]],
                   choices.contains(where: { ($0["Provider"] as? String)?.contains("Livecore") == true }) {
                    dict.removeValue(forKey: k)
                    changed = true
                } else if purgeRecursive(&sec) {
                    dict[k] = sec
                    changed = true
                }
            }
        }
        return changed
    }

    private func readStore() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: storeURL.path) else { throw LivecoreProviderError.wallpaperStoreUnavailable }
        let data = try Data(contentsOf: storeURL)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw LivecoreProviderError.invalidWallpaperStore
        }
        return root
    }

    private func writeStore(_ root: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: storeURL, options: .atomic)
    }

    @discardableResult
    private func runProcess(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func killProcess(_ name: String) {
        runProcess("/usr/bin/killall", [name])
    }

    private func refreshWallpaperServices() {
        killProcess("WallpaperAgent")
        killProcess("WallpaperVideoExtension")
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.wallpaper.changed"), object: nil, userInfo: nil, deliverImmediately: true)
    }
}
