import AppKit
import AVFoundation
import Foundation

enum LivecoreProviderError: LocalizedError {
    case wallpaperStoreUnavailable
    case invalidWallpaperStore
    case pluginNotInstalled
    case pluginRegistrationFailed

    var errorDescription: String? {
        switch self {
        case .wallpaperStoreUnavailable: return "The macOS wallpaper store could not be found."
        case .invalidWallpaperStore: return "The macOS wallpaper store has an unexpected format."
        case .pluginNotInstalled: return "The Livecore wallpaper extension is not installed."
        case .pluginRegistrationFailed: return "The Livecore wallpaper extension could not be registered."
        }
    }
}

struct LivecoreWallpaperItem: Codable {
    let id: UUID
    let fileName: String
    let title: String
    let createdAt: Date
}

private struct LivecorePlaybackState: Codable {
    let enabled: Bool
    let updatedAt: Date
}

private enum LivecoreFallbackAsset {
    static let jpegBase64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDADUlKC8oITUvKy88OTU/UIVXUElJUKN1e2GFwarLyL6qurfV8P//1eL/5re6////////////zv//////////////2wBDATk8PFBGUJ1XV53/3Lrc////////////////////////////////////////////////////////////////////wgARCAEOAeADASIAAhEBAxEB/8QAGQABAAMBAQAAAAAAAAAAAAAAAAECAwQF/8QAFgEBAQEAAAAAAAAAAAAAAAAAAAEC/9oADAMBAAIQAxAAAAHpAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMCbcXeWAzngOvTPI134O8RnyHTbLUV5OksgTpncnPk6SwFq2LZ8nSWMzS/B2mmXPc1Klp4us3xxg3QJLGoAAAAABBThkdmvCO6OWpTWncPN7eE6a49Jj16CvBfM0mBO2HSacGmB09XCO5w9BrwXxOrp4R2cE6l8tMC1+rM5op1lGvCW0pYma2OuQAAAAAAAKsrMp00UsSgSgSgSgSgSgSgSgSIAAAAAAAFSyuZsy1oAAAAAABEohKkSKrCqwqsKrCqwqsKrCqwrMgIAAAAAAAhIrXRUSAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAqWYjZSSyiLs5LigAAAAAAAAAAAAAAAAAAAAAAAHP0DmdNRS0ma4zvNiQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAf//EACUQAAMAAwEAAgIBBQEAAAAAAAABAhESEwMQITFAICIwUGCQQf/aAAgBAQABBQL/AJtP0Sc3t/CrUnRFVqdV8/g6oV7FWpOqOqOqOqJrYdKTqjqjqjqib2HSk6o6o6o6om1Q3quqOqOqOqF6JtvB1R1R1R1R1X6HpeBLLlar4qtU3l+c4PV/1Qs0VaQ26J8yq0X5F5yc5OcnJDaify58vrkjkjkh485/LXl9ckXMyiVoqrZxGTkhxKR5zgutiJyc5OcnORQk/wC9dar8kTqvh/RVbPzjPw/t+f0q9Mky6JhSU8JvL50c6OdERgbwqrZ+cfwbwqez84+G8JvL85LrJE7Ored6HsyIPShJ0c6OdHNiWF/ef4by08G9G9E1dO6yROzPR4n4nz+brLN6N6N6I2PR/ZvRvRvRGzPR5ZvRvQ22RB6UStmlhXG3xF5PR4kVNG9G9E1dP/TMmTf62E8mTKMoyjKMoyjKMoyjKMoyjKMoyjKMoyv0smTcVN/p4+MI1RhGqNUao1RhGEYRhGEaowjVGqNUYRhfptJmkn4/5I1Wq6LHT6mtjOR0kZRshP8Ayjh1Wjb0bf8A5KaEqQ1TbglNf5ZrJgwYNTUS/wB7/8QAFBEBAAAAAAAAAAAAAAAAAAAAgP/aAAgBAwEBPwF/f//EABgRAAMBAQAAAAAAAAAAAAAAAAERQHAS/9oACAECAQE/Ad06EjFy1j//xAAjEAACAQQCAQUBAAAAAAAAAAAAMQEQESAhQGFBIjBQYJCx/9oACAEBAAY/AvzbWKminHUZ7xRvgqeBaM7zl6jVNyMeG8t4Xmm6eaXk6NjHw+8bzW8mvYvNbzlecLydHRaBmy8loNcZjGdZerFjGXktRjGXktRjNl5LRXulproYx/T7n9OqMYxjGMYxjGMYxj4vg1bioUCgUCgUCgUCgUCgUCgUCgUCgUC4exfkncvh5p5+U2dHRo8Hiu/l3RjH98//xAArEAACAQMCBQIHAQEAAAAAAAAAAREhMWFBkRBRcfDxgbEgMEBQYKHBkNH/2gAIAQEAAT8h/wA2oZViGhN8FwE5wgSib1+AG0ktwPksmVBpF2Y2Y2Y2Y2aJOC+DCzGzGzGxDQmL4MLMbMbMLGEKRcjMLMbMbMbIlDUiEl2MLMbMbMb4ArfPgawyJCYFxRIxkjuQtQkhyInFeFNVWPK7GvsFQ3aFWyyBqdTtM7TMrKQ9ENuR3YiqcmVmVmVjUA25HVsVdcmVl0OdC4vVNR0mmhHmwysnzfBC1idCsEPVCO0ztMTrN7k+U+vz+qOxVubZfLuLJJdh0mmhM0tB0Q0j5kX0h1FCLJbmWC/MTMx0zExSdI6RP1BEjsMkZ/K+BEzGyM/lcFzMfMyNbRPhWHTAtYpcM2qfoPmH0P7w8gdI6Qp6wIiXz2hnyHTMY0q53kd5EA9hPhWfs6IrioiRzThV0NfYJRbgzGtBUcneR3kd5Eyl6Ie+UuHeR3kd5D1Gmg/klw7yO8i/pHtw05H94bAhUSEJKDTTyZh7jaWvBXDQd5HeRAF+grfhduDmdi5CmmRO3EVysT3C6uY0V2jE3MTcxNzE3MTcxNzE3MTcxNzE3MTcxNzE3MTcxNzE3MTcxNzck1X0M8FKl0Q66Peaiev0EDSahohcrEIiEWG66bHhDxh4Q8IeEPCHjDxh4w8YeMPCHjDwh4Q8IeMEiyL04QQQQQQQQQQQQQQQQiEWVPCJJIShf5IokZoTS9yFp/8ASBMNISM0nYYRLnBSn2F+rUCW4X6fdJoySGpmEg1swuRDUR9IjiOqSZozesk505TAyFCXN1HjbX0n7tIvBMPM61jqEhBNZ/O//9oADAMBAAIAAwAAABDzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzziDzyBzDCAwigxiwwyQxyAwRzzzzzzwjzTByBSDyizTgzzBBABzyxTzzzzzzj/AAswwwwwAQwgaiiyyyyil688888888e8M88888888sOOOOOOOO988888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888488yy8888888888888888888888888sooYA8888888888888888888888888888888//xAAXEQEAAwAAAAAAAAAAAAAAAAABEUBw/9oACAEDAQE/EN0hqAt6XWP/xAAbEQEBAQADAQEAAAAAAAAAAAABEQAwMVFwUP/aAAgBAgEBPxD7n1hGHJTU1NTU1NTUyXeESnDDkhoaGhoaGhoaPPjNfNX97//EACsQAQACAQMDAwMEAwEAAAAAAAEAEVEhMUFh8PEQcZEggcEwobHRQFCQYP/aAAgBAQABPxD/AJtMK0cm0d6LutUfQyF1eCCkF0DSFyuBL2j9iG3o4EDlglBTNQ6KfK1RLbHkridmTsydmTsyEVEOWFcjwbzuydmTsydmTZa7rVEzRg1Z3ZOzJ2ZO7I7IIXrHj6cBzO7J2ZOzJ2ZBpRsuIXobzuydmTsydmQdoRfaJQoi8PH69wmvdwQwdrBP3nL6sd7gyxE9qadazQwTS+xr7yvu2p9vS19jOPeavrgRWtIw3+8KAC2HHWe5TnmUPuqFTq/hBWh37J5WCwGmmRjpLSIKBcHE8rPKzyso51dh3WMkURobDg4nlZay3suAoAtY7QEWsdJe2g2Yls6ca5nlYzrDizWcw6ukaDwZj2uDr1itEd9aWdX8J1fwg1r9hNdRNrbfrlp67T8zqUfLAu6hx09VL0C2I1oNBglAGjZliEXYLY6u6uJ/AtEt7c/LE9FcltCtF81vEfHsZYofV/aGwBetLOl8p0vlNgXiHERPQjHSODBLKLTh+focPQRT9owSii14P8+jN9D94z33jE0b14PBma//AJHMS503H8S5u123gjQ19iNlKtopaQbLmW22nI/iOQutVeJ0vlOl8osFBy3DB0H6+hC0ujmLd9/aB9MbNTuCdwQCKG600I12vJlmNq2bz8QAAUGxKkb6EqGgLeAmz8X8wAAANg9G1iJRhEgNxvadwTuCdwTg28AfePqp+91lMCKNB0TuCdwQuzio16xahF0M9ZqTuCdwSlspsVAVA7Lmbv3h/EGl7uCCDoJpABs5iMRA/Erj9L23luLaq8TWKqBb2J3BO4IJ9400IEAquX/AoxKMSjEoxKMfRRiUYlGJRiUY9KlGJRiUYlGPSpRiUYlGJRj0ox9FGJRj0oxKMSjEoxK/wFBbPbKg0A1VdoGwxta9X7QDXQvg+/MdlI0E/wiVCerPCp4VPCp4VPCp4VPCp4VPCp4VPCp4VPCp4VPCp4VPCoMoZwMszLMksySzJLMksySzJLMksySzJLMksySzJLMksySzJLMksySzJEBvPbEJSG6sG2g4tf1HGlW9L+pxr+sg7kpglICYSa40vY1tNdoncreAAAAOCIWlyieCTxSeCTwSeCTwSeKTxSeKTxSeKTwSeKTwSeCTwSeKRS0sglGCUwSmCUwSmCUwSmCUwSmCUwSmCUwSmCUwSmCUwRbidKHBQNi50/wAsMCDg/wCSP2JgbsLDuKL5dJqmRdA7xcnaBeYli9LW0stdyBanS11uguqptsSD9Q5Qf7QtwCDsS/GhAOxHRh0E2IqkCFW2IddW7Yqx52O1L+ogVNaLfu0iRp3TfV41nRUAkPn/AGzgjoOhNTc2IywKZRRBl7jQ6S2oVaFPvFB1atxNZ2zx/wC7/9k="

    static var data: Data {
        guard let data = Data(base64Encoded: jpegBase64) else {
            preconditionFailure("Invalid built-in fallback image")
        }
        return data
    }
}

final class LivecoreWallpaperLibrary {
    static let shared = LivecoreWallpaperLibrary()
    static let extensionBundleID = "com.berkegulacar.Livecore.wallpaper-extension"
    static let fixedUUID = UUID(uuidString: "DEADBEEF-1111-2222-3333-444444444444")!

    private let fileManager = FileManager.default

    var root: URL {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(Self.extensionBundleID)/Data/Documents/WallpaperLibrary", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func ensureFallbackImage() throws -> URL {
        let url = root.appendingPathComponent("LivecoreFallback.jpg")
        let data = LivecoreFallbackAsset.data
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    func importVideo(at source: URL) throws -> LivecoreWallpaperItem {
        try ensureFallbackImage()
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let fileName = "\(Self.fixedUUID.uuidString).\(ext)"
        let destination = root.appendingPathComponent(fileName)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        for url in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if url.lastPathComponent != "LivecoreFallback.jpg" && url.lastPathComponent != "playback-state.json" {
                try? fileManager.removeItem(at: url)
            }
        }
        try fileManager.copyItem(at: source, to: destination)

        let item = LivecoreWallpaperItem(
            id: Self.fixedUUID,
            fileName: fileName,
            title: source.deletingPathExtension().lastPathComponent,
            createdAt: Date()
        )
        try JSONEncoder().encode(item).write(
            to: root.appendingPathComponent("current.json"),
            options: .atomic
        )
        makeThumbnail(for: destination, at: root.appendingPathComponent("\(item.id.uuidString).jpg"))
        return item
    }

    func currentItem() -> LivecoreWallpaperItem? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("current.json")) else { return nil }
        return try? JSONDecoder().decode(LivecoreWallpaperItem.self, from: data)
    }

    func setPlaybackEnabled(_ enabled: Bool) throws {
        try ensureFallbackImage()
        let state = LivecorePlaybackState(enabled: enabled, updatedAt: Date())
        try JSONEncoder().encode(state).write(
            to: root.appendingPathComponent("playback-state.json"),
            options: .atomic
        )
    }

    func purge() {
        try? fileManager.removeItem(at: root)
    }

    private func makeThumbnail(for videoURL: URL, at destination: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 960, height: 540)
        guard let image = try? generator.copyCGImage(
            at: CMTime(seconds: 0.1, preferredTimescale: 600),
            actualTime: nil
        ), let data = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.82]
        ) else { return }
        try? data.write(to: destination, options: .atomic)
    }
}

final class WallpaperStoreManager {
    static let shared = WallpaperStoreManager()
    static let providerID = "com.berkegulacar.Livecore.wallpaper-extension"

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.berkegulacar.Livecore.wallpaper-store")

    private var storeURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    func isPluginInstalled() -> Bool {
        runProcess("/usr/bin/pluginkit", ["-m", "-i", Self.providerID]).contains("+")
    }

    func installPlugin() throws {
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/LivecoreWallpaperExtension.appex")
        guard fileManager.fileExists(atPath: extensionURL.path) else {
            throw LivecoreProviderError.pluginRegistrationFailed
        }
        _ = runProcess("/usr/bin/pluginkit", ["-a", extensionURL.path])
        _ = runProcess("/usr/bin/pluginkit", ["-e", "use", "-i", Self.providerID])
        for _ in 0..<8 {
            if isPluginInstalled() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw LivecoreProviderError.pluginRegistrationFailed
    }

    func uninstallPlugin() {
        purgeFromStore()
        LivecoreWallpaperLibrary.shared.purge()
        killProcess("LivecoreWallpaperExtension")
        _ = runProcess("/usr/bin/pluginkit", ["-e", "ignore", "-i", Self.providerID])
        _ = runProcess("/usr/bin/pluginkit", ["-r", "-i", Self.providerID])
        refreshWallpaperServices()
    }

    func activateLockScreen(item: LivecoreWallpaperItem) throws {
        guard isPluginInstalled() else { throw LivecoreProviderError.pluginNotInstalled }
        try queue.sync {
            var root = try readStore()
            let choice = livecoreChoice(configuration: item.id.uuidString)
            injectLockOnly(choice, into: &root)
            try writeStore(root)
            refreshRepeatedly()
        }
    }

    func applyFallbackWallpaper() throws {
        let fallback = try LivecoreWallpaperLibrary.shared.ensureFallbackImage()
        try LivecoreWallpaperLibrary.shared.setPlaybackEnabled(false)

        var desktopError: Error?
        DispatchQueue.main.sync {
            for screen in NSScreen.screens {
                do {
                    try NSWorkspace.shared.setDesktopImageURL(
                        fallback,
                        for: screen,
                        options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue]
                    )
                } catch {
                    desktopError = error
                }
            }
        }
        if let desktopError { throw desktopError }

        if isPluginInstalled() {
            try queue.sync {
                var root = try readStore()
                injectLockOnly(
                    livecoreChoice(configuration: LivecoreWallpaperLibrary.fixedUUID.uuidString),
                    into: &root
                )
                try writeStore(root)
                refreshRepeatedly()
            }
        }
    }

    private func livecoreChoice(configuration: String) -> [String: Any] {
        [
            "Configuration": Data(configuration.utf8),
            "Files": [] as [Any],
            "Provider": Self.providerID,
        ]
    }

    private func injectLockOnly(_ choice: [String: Any], into dictionary: inout [String: Any]) {
        let now = Date()
        for key in Array(dictionary.keys) {
            if key == "Linked", let linked = dictionary[key] as? [String: Any] {
                // Preserve the linked selection as Desktop and only replace Idle.
                var idle = linked
                var content = (idle["Content"] as? [String: Any]) ?? [:]
                content["Choices"] = [choice]
                idle["Content"] = content
                idle["LastSet"] = now
                idle["LastUse"] = now
                dictionary["Desktop"] = linked
                dictionary["Idle"] = idle
                dictionary["Type"] = "custom"
                dictionary.removeValue(forKey: "Linked")
                continue
            }
            if key == "Idle", var idle = dictionary[key] as? [String: Any] {
                var content = (idle["Content"] as? [String: Any]) ?? [:]
                content["Choices"] = [choice]
                idle["Content"] = content
                idle["LastSet"] = now
                idle["LastUse"] = now
                dictionary[key] = idle
                continue
            }
            if var nested = dictionary[key] as? [String: Any] {
                injectLockOnly(choice, into: &nested)
                dictionary[key] = nested
            }
        }
    }

    private func readStore() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw LivecoreProviderError.wallpaperStoreUnavailable
        }
        let data = try Data(contentsOf: storeURL)
        guard let root = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: Any] else {
            throw LivecoreProviderError.invalidWallpaperStore
        }
        return root
    }

    private func writeStore(_ root: [String: Any]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
        let temporary = storeURL.deletingLastPathComponent()
            .appendingPathComponent("Index.plist.livecore.tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: storeURL.path) {
            _ = try fileManager.replaceItemAt(storeURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: storeURL)
        }
    }

    private func purgeFromStore() {
        guard var root = try? readStore() else { return }
        if purgeLivecoreEntries(&root) { try? writeStore(root) }
    }

    @discardableResult
    private func purgeLivecoreEntries(_ dictionary: inout [String: Any]) -> Bool {
        var changed = false
        for key in Array(dictionary.keys) {
            if var section = dictionary[key] as? [String: Any] {
                if let content = section["Content"] as? [String: Any],
                   let choices = content["Choices"] as? [[String: Any]],
                   choices.contains(where: { ($0["Provider"] as? String) == Self.providerID }) {
                    dictionary.removeValue(forKey: key)
                    changed = true
                } else if purgeLivecoreEntries(&section) {
                    dictionary[key] = section
                    changed = true
                }
            }
        }
        return changed
    }

    private func refreshRepeatedly() {
        killProcess("LivecoreWallpaperExtension")
        refreshWallpaperServices()
        for delay in [0.25, 0.75, 1.5] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshWallpaperServices()
            }
        }
    }

    @discardableResult
    private func runProcess(_ path: String, _ arguments: [String]) -> String {
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
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func killProcess(_ name: String) {
        _ = runProcess("/usr/bin/killall", [name])
    }

    private func refreshWallpaperServices() {
        killProcess("WallpaperAgent")
        killProcess("WallpaperVideoExtension")
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.wallpaper.changed"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
