import ExtensionFoundation
import Foundation
import Darwin
import AppKit
import AVFoundation
import QuartzCore

@main
struct LivecoreWallpaperExtension: AppExtension {
    var configuration: ConnectionHandler {
        ConnectionHandler { connection in
            ExtensionLog.write("XPC connection accepted")
            let handler = WallpaperXPCHandler()
            connection.exportedInterface = WallpaperXPCInterface.makeExportedInterface()
            if let remote = WallpaperXPCInterface.makeRemoteInterface() {
                connection.remoteObjectInterface = remote
            }
            connection.exportedObject = handler
            connection.resume()
            handler.agentProxy = connection.remoteObjectProxy as AnyObject
            return true
        }
    }
}

private enum WallpaperXPCInterface {
    private static let privateClassNames = [
        "WallpaperIDXPC", "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC",
        "WallpaperContentTypeSetXPC", "WallpaperUpdateRequestXPC",
        "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC",
        "WallpaperSettingsViewModelsXPC", "WallpaperExtensionChoiceRequestXPC",
        "WallpaperChoiceRequestAdditionResultXPC", "WallpaperCreationRequestXPC",
        "WallpaperMigrationVersionXPC", "WallpaperDebugRequestXPC",
        "WallpaperDebugResponseXPC"
    ]

    static func makeExportedInterface() -> NSXPCInterface {
        _ = dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_NOW)
        let runtimeProtocol = NSProtocolFromString("WallpaperExtensionXPCProtocol")
        ExtensionLog.write("runtime WallpaperExtensionXPCProtocol found: \(runtimeProtocol != nil)")
        let interface = NSXPCInterface(with: runtimeProtocol ?? LivecoreWallpaperExtensionProtocol.self)
        let allowed = NSSet(array: privateClassNames.compactMap(NSClassFromString) + [
            SettingsViewModelsArchive.self,
            NSString.self, NSNumber.self, NSData.self, NSArray.self,
            NSDictionary.self, NSURL.self, NSError.self
        ]) as! Set<AnyHashable>

        let rules: [(String, Int, Bool)] = [
            ("acquireWithId:request:reply:", 0, false), ("acquireWithId:request:reply:", 1, false),
            ("acquireWithId:request:reply:", 0, true), ("acquireWithId:request:reply:", 1, true),
            ("updateWithId:request:reply:", 0, false), ("updateWithId:request:reply:", 1, false),
            ("updateWithId:request:reply:", 0, true), ("updateWithId:request:reply:", 1, true),
            ("invalidateWithId:reply:", 0, false), ("invalidateWithId:reply:", 0, true),
            ("snapshotWithId:reply:", 0, false), ("snapshotWithId:reply:", 0, true),
            ("snapshotWithId:reply:", 1, true),
            ("provideSettingsViewModelsWithContentTypes:reply:", 0, false),
            ("provideSettingsViewModelsWithContentTypes:reply:", 0, true),
            ("provideSettingsViewModelsWithContentTypes:reply:", 1, true),
            ("selectedChoicesDidChangeFor:reply:", 0, false),
            ("selectedChoicesDidChangeFor:reply:", 0, true)
        ]
        for (name, index, reply) in rules {
            let selector = NSSelectorFromString(name)
            if protocol_getMethodDescription(runtimeProtocol ?? LivecoreWallpaperExtensionProtocol.self, selector, true, true).name != nil {
                interface.setClasses(allowed, for: selector, argumentIndex: index, ofReply: reply)
            }
        }
        ExtensionLog.write("exported XPC interface ready")
        return interface
    }

    static func makeRemoteInterface() -> NSXPCInterface? {
        guard let remoteProtocol = NSProtocolFromString("WallpaperExtensionProxyXPCProtocol") else { return nil }
        return NSXPCInterface(with: remoteProtocol)
    }
}

// WallpaperExtensionKit is private. Keep its wire protocol isolated here so
// macOS-specific changes do not leak into the video library and renderer.
@objc(WallpaperExtensionXPCProtocol)
protocol LivecoreWallpaperExtensionProtocol {
    func provideSettingsViewModels(
        withContentTypes contentTypes: NSObject?,
        reply: @escaping (WallpaperSettingsViewModelsXPC?, NSError?) -> Void
    )
    func selectedChoicesDidChange(for choices: NSObject?, reply: @escaping (NSError?) -> Void)
    func acquire(withId identifier: NSObject?, request: NSObject?, reply: @escaping (WallpaperRemoteContextXPC?, NSError?) -> Void)
    func update(withId identifier: NSObject?, request: NSObject?, reply: @escaping (WallpaperRemoteContextXPC?, NSError?) -> Void)
    func invalidate(withId identifier: NSObject?, reply: @escaping (NSError?) -> Void)
    func snapshot(withId identifier: NSObject?, reply: @escaping (WallpaperSnapshotXPC?, NSError?) -> Void)
    @objc(addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:) func addChoiceRequest(_ request: NSObject?, process: NSObject?, reply: @escaping (NSObject?, NSError?) -> Void)
    @objc(removeChoiceRequestWithChoiceRequest:reply:) func removeChoiceRequest(_ request: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(migrateSelectedChoiceFor:reply:) func migrateSelectedChoice(_ choice: NSObject?, reply: @escaping (NSObject?, NSError?) -> Void)
    func migrate(from: NSObject?, to: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(isChoiceDownloadedWith:reply:) func isChoiceDownloaded(_ choice: NSObject?, reply: @escaping (Bool, NSError?) -> Void)
    @objc(downloadWithChoiceID:reply:) func download(_ choice: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(pauseDownloadFor:reply:) func pauseDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(cancelDownloadFor:reply:) func cancelDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(resumeDownloadFor:reply:) func resumeDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(removeDownloadFor:reply:) func removeDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(canSkipShuffledContentWithId:reply:) func canSkip(_ identifier: NSObject?, reply: @escaping (Bool, NSError?) -> Void)
    @objc(skipShuffledContentWithId:reply:) func skip(_ identifier: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(invokeContextMenuActionWithMenuItemID:groupItemID:reply:) func invokeContextMenuAction(_ menu: NSObject?, groupItemID: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(handleDebugRequestFor:reply:) func handleDebugRequest(_ request: NSObject?, reply: @escaping (NSObject?, NSError?) -> Void)
    func handleNotification(named: String, reply: @escaping (NSError?) -> Void)
}

@objc(WallpaperExtensionProxyXPCProtocol)
private protocol LivecoreWallpaperExtensionProxyProtocol {
    func updateSettingsViewModels(_ models: NSObject?, reply: @escaping (NSError?) -> Void)
}

final class WallpaperXPCHandler: NSObject, LivecoreWallpaperExtensionProtocol {
    private let renderer = LivecoreRemoteRenderer.shared
    var agentProxy: AnyObject?
    func provideSettingsViewModels(withContentTypes contentTypes: NSObject?, reply: @escaping (WallpaperSettingsViewModelsXPC?, NSError?) -> Void) {
        ExtensionLog.write("provideSettingsViewModels called")
        let models = SettingsModelBridge.makeViewModels()
        reply(models, nil)
    }

    func selectedChoicesDidChange(for choices: NSObject?, reply: @escaping (NSError?) -> Void) {
        ExtensionLog.write("selectedChoicesDidChange called")
        reply(nil)
    }

    private func resolveItem(from object: NSObject?) -> SharedWallpaperItem? {
        guard let object else { return SharedWallpaperLibrary.currentItem() }
        let sel = Selector(("configuration"))
        if object.responds(to: sel),
           let unmanaged = object.perform(sel),
           let data = unmanaged.takeUnretainedValue() as? Data,
           let str = String(data: data, encoding: .utf8),
           let uuid = UUID(uuidString: str),
           let item = SharedWallpaperLibrary.item(forUUIDString: uuid.uuidString) {
            return item
        }
        let str = String(describing: object)
        if let range = str.range(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", options: .regularExpression),
           let uuid = UUID(uuidString: String(str[range])),
           let item = SharedWallpaperLibrary.item(forUUIDString: uuid.uuidString) {
            return item
        }
        return SharedWallpaperLibrary.currentItem()
    }

    func acquire(withId identifier: NSObject?, request: NSObject?, reply: @escaping (WallpaperRemoteContextXPC?, NSError?) -> Void) {
        ExtensionLog.write("acquire called")
        let item = resolveItem(from: request ?? identifier)
        if let item {
            renderer.acquire(for: item, reply: reply)
        } else {
            reply(nil, LivecoreExtensionError.rendererNotReady as NSError)
        }
    }

    func update(withId identifier: NSObject?, request: NSObject?, reply: @escaping (WallpaperRemoteContextXPC?, NSError?) -> Void) {
        let item = resolveItem(from: request ?? identifier)
        if let item {
            renderer.acquire(for: item, reply: reply)
        } else {
            reply(nil, LivecoreExtensionError.rendererNotReady as NSError)
        }
    }

    func invalidate(withId identifier: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    func snapshot(withId identifier: NSObject?, reply: @escaping (WallpaperSnapshotXPC?, NSError?) -> Void) {
        ExtensionLog.write("snapshot called")
        let item = resolveItem(from: identifier)
        if let item {
            renderer.snapshot(for: item, reply: reply)
        } else {
            reply(nil, LivecoreExtensionError.rendererNotReady as NSError)
        }
    }

    @objc(migrateSelectedChoiceFor:reply:)
    func migrateSelectedChoice(_ choice: NSObject?, reply: @escaping (NSObject?, NSError?) -> Void) {
        ExtensionLog.write("migrateSelectedChoice called")
        reply(choice, nil)
    }

    @objc(migrateFrom:to:reply:)
    func migrate(from: NSObject?, to: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    @objc(addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:)
    func addChoiceRequest(_ request: NSObject?, process: NSObject?, reply: @escaping (NSObject?, NSError?) -> Void) {
        reply(nil, nil)
    }

    @objc(removeChoiceRequestWithChoiceRequest:reply:)
    func removeChoiceRequest(_ request: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    @objc(isChoiceDownloadedWith:reply:)
    func isChoiceDownloaded(_ choice: NSObject?, reply: @escaping (Bool, NSError?) -> Void) { reply(true, nil) }

    @objc(downloadWithChoiceID:reply:)
    func download(_ choice: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    @objc(pauseDownloadFor:reply:)
    func pauseDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    @objc(cancelDownloadFor:reply:)
    func cancelDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    @objc(resumeDownloadFor:reply:)
    func resumeDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    @objc(removeDownloadFor:reply:)
    func removeDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    @objc(canSkipShuffledContentWithId:reply:)
    func canSkip(_ identifier: NSObject?, reply: @escaping (Bool, NSError?) -> Void) { reply(false, nil) }

    @objc(skipShuffledContentWithId:reply:)
    func skip(_ identifier: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    @objc(invokeContextMenuActionWithMenuItemID:groupItemID:reply:)
    func invokeContextMenuAction(_ menu: NSObject?, groupItemID: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    @objc(handleDebugRequestFor:reply:)
    func handleDebugRequest(_ request: NSObject?, reply: @escaping (NSObject?, NSError?) -> Void) { reply(nil, nil) }

    @objc(handleNotificationWithNamed:reply:)
    func handleNotification(named: String, reply: @escaping (NSError?) -> Void) { reply(nil) }
}

private enum ExtensionLog {
    static func write(_ message: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("livecore-extension.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum LivecoreExtensionError: Int, Error {
    case rendererNotReady = 1
}

private final class LivecoreRemoteRenderer {
    static let shared = LivecoreRemoteRenderer()
    private var activePlayers: [AVPlayer] = []
    private var activeLayers: [CALayer] = []
    private var observers: [NSObjectProtocol] = []
    private var kvos: [NSKeyValueObservation] = []

    func acquire(for item: SharedWallpaperItem, reply: @escaping (WallpaperRemoteContextXPC?, NSError?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                reply(nil, LivecoreExtensionError.rendererNotReady as NSError); return
            }

            for player in self.activePlayers {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            self.activePlayers.removeAll()
            for layer in self.activeLayers {
                layer.removeFromSuperlayer()
            }
            self.activeLayers.removeAll()
            for observer in self.observers {
                NotificationCenter.default.removeObserver(observer)
            }
            self.observers.removeAll()
            self.kvos.removeAll()

            guard let url = SharedWallpaperLibrary.videoURL(for: item) else {
                ExtensionLog.write("acquire: video URL unavailable")
                reply(nil, LivecoreExtensionError.rendererNotReady as NSError); return
            }

            let asset = AVURLAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.preventsDisplaySleepDuringVideoPlayback = false

            let observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    if finished { player?.play() }
                }
            }
            self.observers.append(observer)

            let root = CALayer()
            root.frame = CGRect(x: 0, y: 0, width: 3840, height: 2160)
            root.backgroundColor = NSColor.black.cgColor
            if let thumbURL = SharedWallpaperLibrary.thumbnailURL(for: item),
               let nsImage = NSImage(contentsOf: thumbURL),
               let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                root.contents = cgImage
            }

            let video = AVPlayerLayer(player: player)
            video.frame = root.bounds
            video.videoGravity = .resizeAspectFill
            video.backgroundColor = NSColor.clear.cgColor
            video.opacity = 0.0
            root.addSublayer(video)

            let kvo = playerItem.observe(\.status, options: [.initial, .new]) { [weak video, weak player] pItem, _ in
                if pItem.status == .readyToPlay {
                    DispatchQueue.main.async {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        video?.opacity = 1.0
                        CATransaction.commit()
                        player?.play()
                    }
                }
            }
            self.kvos.append(kvo)

            guard let remote = LCCreateRemoteContext(root) else {
                ExtensionLog.write("acquire: LCCreateRemoteContext returned nil")
                reply(nil, LivecoreExtensionError.rendererNotReady as NSError); return
            }

            self.activePlayers.append(player)
            self.activeLayers.append(root)

            player.play()
            ExtensionLog.write("acquire: player initialized for '\(item.title)'")
            reply(remote, nil)
        }
    }

    func snapshot(for item: SharedWallpaperItem, reply: @escaping (WallpaperSnapshotXPC?, NSError?) -> Void) {
        DispatchQueue.main.async {
            if let thumbURL = SharedWallpaperLibrary.thumbnailURL(for: item),
               let nsImage = NSImage(contentsOf: thumbURL),
               let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let snapshot = LCCreateWallpaperSnapshot(cgImage) {
                ExtensionLog.write("snapshot: returned CGImage snapshot")
                reply(snapshot, nil)
                return
            }

            guard let url = SharedWallpaperLibrary.videoURL(for: item) else {
                ExtensionLog.write("snapshot: video URL unavailable")
                reply(nil, LivecoreExtensionError.rendererNotReady as NSError)
                return
            }

            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 3840, height: 2160)
            generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.1, preferredTimescale: 600)) { image, _, error in
                DispatchQueue.main.async {
                    if let image, let snapshot = LCCreateWallpaperSnapshot(image) {
                        ExtensionLog.write("snapshot: generated async video snapshot")
                        reply(snapshot, nil)
                        return
                    }
                    reply(nil, (error ?? LivecoreExtensionError.rendererNotReady) as NSError)
                }
            }
        }
    }
}

enum SettingsModelBridge {
    static func makeViewModels() -> WallpaperSettingsViewModelsXPC? {
        _ = dlopen(
            "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit",
            RTLD_NOW
        )
        guard NSClassFromString("WallpaperSettingsViewModelsXPC") != nil else {
            ExtensionLog.write("WallpaperSettingsViewModelsXPC class not found")
            return nil
        }

        // Single-slot: only 1 item ever
        guard let item = SharedWallpaperLibrary.currentItem() else {
            ExtensionLog.write("makeViewModels: no current item, returning empty")
            return remap(SettingsViewModelsArchive(value: .empty))
        }

        let thumbURL = SharedWallpaperLibrary.thumbnailURL(for: item)
        let vidURL = SharedWallpaperLibrary.videoURL(for: item)
        guard let displayURL = thumbURL ?? vidURL else {
            ExtensionLog.write("makeViewModels: no thumbnail or video file")
            return remap(SettingsViewModelsArchive(value: .empty))
        }

        ExtensionLog.write("makeViewModels: item='\(item.title)' thumb=\(thumbURL != nil)")

        let provider = ChoiceProviderID(rawValue: "com.berkegulacar.Livecore.wallpaper-extension")
        let wireDescriptor = WallpaperChoiceDescriptor(
            provider: provider, files: [], configuration: Data(item.id.uuidString.utf8)
        )
        let thumbnail = Thumbnail.image(displayURL)
        let choice = WallpaperChoice(
            id: ChoiceID(descriptor: wireDescriptor),
            localizedDescription: item.title,
            thumbnail: thumbnail, isDownloaded: true, options: []
        )
        let settingsItem = SettingsItem(
            id: ChoiceIDDescriptor(id: item.id.uuidString),
            localizedName: item.title, thumbnail: thumbnail,
            choice: choice, contentBadge: .video,
            showInTopLevel: true, sortOrder: 0, disposability: .none
        )
        let group = SettingsGroup(
            id: GroupID(id: "livecore"), items: [settingsItem],
            localizedName: "Livecore", disposability: .none,
            sortOrder: 0, sortID: GroupID(id: "other"),
            allChoiceID: nil, shouldHideItemLabels: false,
            contextMenu: nil, thumbnail: nil
        )
        return remap(
            SettingsViewModelsArchive(value: SettingsViewModels(
                desktop: SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false),
                screenSaver: nil
            ))
        )
    }

    private static func remap(_ shim: SettingsViewModelsArchive) -> WallpaperSettingsViewModelsXPC? {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: shim, requiringSecureCoding: true)
            guard let runtimeClass = NSClassFromString("WallpaperSettingsViewModelsXPC"),
                  let result = try NSKeyedUnarchiver.unarchivedObject(
                    ofClasses: [runtimeClass, NSDictionary.self, NSArray.self, NSString.self,
                                NSNumber.self, NSData.self, NSURL.self],
                    from: data
                  ) as AnyObject? else { return nil }
            ExtensionLog.write("Settings model remapped: true")
            return unsafeBitCast(result, to: WallpaperSettingsViewModelsXPC.self)
        } catch {
            ExtensionLog.write("Settings remap failed: \(String(reflecting: error)); \((error as NSError).userInfo)")
            return nil
        }
    }
}

private struct SharedWallpaperItem: Codable {
    let id: UUID
    let fileName: String
    let title: String
    let createdAt: Date
}

private enum SharedWallpaperLibrary {
    static var root: URL? {
        // Inside the sandboxed extension, documentDirectory resolves to
        // ~/Library/Containers/com.berkegulacar.Livecore.wallpaper-extension/Data/Documents/
        // which is where the main app writes files to.
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WallpaperLibrary", isDirectory: true)
    }

    static func currentItem() -> SharedWallpaperItem? {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("current.json")) else { return nil }
        return try? JSONDecoder().decode(SharedWallpaperItem.self, from: data)
    }

    // Single-slot: always return currentItem()
    static func item(forUUIDString uuidString: String?) -> SharedWallpaperItem? {
        return currentItem()
    }

    static func videoURL(for item: SharedWallpaperItem) -> URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(item.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func thumbnailURL(for item: SharedWallpaperItem) -> URL? {
        let tmpDir = URL(fileURLWithPath: "/private/tmp/LivecoreThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpURL = tmpDir.appendingPathComponent("\(item.id.uuidString).jpg")

        guard let root else { return nil }
        let url = root.appendingPathComponent("\(item.id.uuidString).jpg")
        if FileManager.default.fileExists(atPath: url.path) {
            if !FileManager.default.fileExists(atPath: tmpURL.path) {
                try? FileManager.default.copyItem(at: url, to: tmpURL)
            }
            return tmpURL
        }
        return nil
    }
}

// WallpaperExtensionKit's Settings types are Swift Codable values wrapped in
// NSSecureCoding containers. These local values intentionally mirror that wire
// representation without linking the private framework at build time.
private struct SettingsViewModels: Codable {
    let desktop: SettingsViewModel?
    let screenSaver: SettingsViewModel?
    static let empty = SettingsViewModels(
        desktop: SettingsViewModel(groups: [], refreshPolicy: .default, isModificationDisabled: false),
        screenSaver: nil
    )
}
private struct SettingsViewModel: Codable {
    let groups: [SettingsGroup]
    let refreshPolicy: RefreshPolicy
    let isModificationDisabled: Bool
}
private enum RefreshPolicy: Codable { case `default` }
private enum Thumbnail: Codable {
    case image(URL)
    private enum CodingKeys: String, CodingKey { case image }
    private enum ImageCodingKeys: String, CodingKey { case url }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let image = try container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
        self = .image(try image.decode(URL.self, forKey: .url))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var image = container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
        if case let .image(url) = self { try image.encode(url, forKey: .url) }
    }
}
private enum ContentBadge: Codable { case none, video, dynamic }
private enum Disposability: Codable { case none, removable, purgeable }
private struct ChoiceProviderID: Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}
private struct ChoiceID: Codable { let descriptor: WallpaperChoiceDescriptor }
private struct ChoiceIDDescriptor: Codable { let id: String }
private struct GroupID: Codable { let id: String }
private struct WallpaperOption: Codable {}
private struct ContextMenu: Codable { let items: [ContextMenuItem] }
private struct ContextMenuItem: Codable { let id: String; let descriptor: ContextMenuItemDescriptor }
private struct ContextMenuItemDescriptor: Codable { let identifier: String; let name: String }
private struct WallpaperChoiceDescriptor: Codable {
    let provider: ChoiceProviderID
    let files: [URL]
    let configuration: Data
}
private struct WallpaperChoice: Codable {
    let id: ChoiceID
    let localizedDescription: String
    let thumbnail: Thumbnail
    let isDownloaded: Bool
    let options: [WallpaperOption]
}
private struct SettingsItem: Codable {
    let id: ChoiceIDDescriptor
    let localizedName: String
    let thumbnail: Thumbnail
    let choice: WallpaperChoice
    let contentBadge: ContentBadge
    let showInTopLevel: Bool
    let sortOrder: Int
    let disposability: Disposability
}
private struct SettingsGroup: Codable {
    let id: GroupID
    let items: [SettingsItem]
    let localizedName: String
    let disposability: Disposability
    let sortOrder: Int
    let sortID: GroupID?
    let allChoiceID: ChoiceID?
    let shouldHideItemLabels: Bool?
    let contextMenu: ContextMenu?
    let thumbnail: URL?
}

@objc(LivecoreSettingsViewModelsArchive)
private final class SettingsViewModelsArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let value: SettingsViewModels
    init(value: SettingsViewModels) { self.value = value; super.init() }
    required init?(coder: NSCoder) { return nil }
    override var classForKeyedArchiver: AnyClass { NSClassFromString("WallpaperSettingsViewModelsXPC") ?? Self.self }

    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else { return }
        do {
            try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
            ExtensionLog.write("Settings model encoded")
        } catch {
            ExtensionLog.write("Settings encode failed: \(error.localizedDescription)")
        }
    }
}
