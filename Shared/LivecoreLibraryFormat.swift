import Foundation

/// On-disk description of one prepared video.
///
/// The app writes these files into the extension's container and the sandboxed
/// extension only reads them. Both targets compile this file, so the two sides
/// of the boundary cannot drift apart.
struct LivecoreWallpaperItem: Codable, Equatable {
    let id: UUID
    let fileName: String
    let title: String
    /// Kept on the wire for compatibility with extension processes from older
    /// Livecore builds, which require this field when decoding an item.
    let createdAt: Date
    /// Still shown per display while the screen is unlocked, keyed by display
    /// ID. macOS has no separate Lock Screen slot — the Lock Screen shows the
    /// Desktop picture — so Livecore owns the Desktop wallpaper and paints the
    /// user's previous Desktop picture whenever it is not playing. A `default`
    /// entry covers displays connected after the item was prepared.
    let desktopImageFileNames: [String: String]

    init(
        id: UUID,
        fileName: String,
        title: String,
        createdAt: Date = Date(),
        desktopImageFileNames: [String: String]
    ) {
        self.id = id
        self.fileName = fileName
        self.title = title
        self.createdAt = createdAt
        self.desktopImageFileNames = desktopImageFileNames
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, title, createdAt, desktopImageFileNames
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fileName = try values.decode(String.self, forKey: .fileName)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        desktopImageFileNames = try values.decode(
            [String: String].self,
            forKey: .desktopImageFileNames
        )
    }
}

/// Names of the files that make up a library directory.
enum LivecoreLibraryFile {
    static let directoryName = "WallpaperLibrary"
    static let current = "current.json"
    static let lockScreenBackup = "lock-screen-backup.json"
    static let defaultDisplayKey = "default"

    static func metadata(_ id: UUID) -> String { "\(id.uuidString).json" }
    static func thumbnail(_ id: UUID) -> String { "\(id.uuidString).jpg" }
    static func desktopImage(_ id: UUID, displayID: String) -> String {
        "\(id.uuidString).desktop.\(displayID).jpg"
    }
}

/// Read-only view of a library directory.
struct LivecoreLibraryReader {
    let root: URL

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    func currentItem() -> LivecoreWallpaperItem? {
        decode(at: url(LivecoreLibraryFile.current))
    }

    func item(_ id: UUID) -> LivecoreWallpaperItem? {
        decode(at: url(LivecoreLibraryFile.metadata(id)))
    }

    func videoURL(for item: LivecoreWallpaperItem) -> URL {
        url(item.fileName)
    }

    func thumbnailURL(for item: LivecoreWallpaperItem) -> URL {
        url(LivecoreLibraryFile.thumbnail(item.id))
    }

    func desktopImageURL(for item: LivecoreWallpaperItem, displayID: String) -> URL? {
        let names = item.desktopImageFileNames
        guard let name = names[displayID] ?? names[LivecoreLibraryFile.defaultDisplayKey]
        else { return nil }
        return url(name)
    }

    func assetURLs(for item: LivecoreWallpaperItem) -> [URL] {
        var urls = [
            videoURL(for: item),
            thumbnailURL(for: item),
            url(LivecoreLibraryFile.metadata(item.id)),
        ]
        // `default` aliases another display's file, so deduplicate.
        urls.append(contentsOf: Set(item.desktopImageFileNames.values).map(url))
        return urls
    }

    /// True when every file the renderer needs is present. A missing still
    /// would show up as a black wallpaper, so an incomplete item is never worth
    /// selecting.
    func itemIsUsable(_ item: LivecoreWallpaperItem) -> Bool {
        item.desktopImageFileNames[LivecoreLibraryFile.defaultDisplayKey] != nil
            && assetURLs(for: item).allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            }
    }

    private func decode(at url: URL) -> LivecoreWallpaperItem? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LivecoreWallpaperItem.self, from: data)
    }
}

/// Process-local and distributed lifecycle signals shared by the app and its
/// wallpaper extension. They carry state only; nothing is persisted or logged.
enum LivecoreNotification {
    static let assetsChanged = Notification.Name("com.livecore.app.assets-changed")
    static let rendererReady = Notification.Name("com.livecore.app.renderer-ready")
    static let rendererRetired = Notification.Name("com.livecore.app.renderer-retired")
}
