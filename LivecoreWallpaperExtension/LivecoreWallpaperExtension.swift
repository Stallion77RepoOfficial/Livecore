import AppKit
import AVFoundation
import Darwin
import ExtensionFoundation
import Foundation
import QuartzCore

@main
struct LivecoreWallpaperExtension: AppExtension {
    var configuration: ConnectionHandler {
        ConnectionHandler { connection in
            let handler = WallpaperXPCHandler()
            connection.exportedInterface = WallpaperXPCInterface.exported()
            connection.remoteObjectInterface = WallpaperXPCInterface.remote()
            connection.exportedObject = handler
            connection.resume()
            return true
        }
    }
}

private enum WallpaperXPCInterface {
    private static let classes = [
        "WallpaperIDXPC", "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC",
        "WallpaperContentTypeSetXPC", "WallpaperUpdateRequestXPC",
        "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC",
        "WallpaperSettingsViewModelsXPC", "WallpaperExtensionChoiceRequestXPC",
        "WallpaperChoiceRequestAdditionResultXPC", "WallpaperCreationRequestXPC",
        "WallpaperMigrationVersionXPC", "WallpaperDebugRequestXPC",
        "WallpaperDebugResponseXPC",
    ]

    static func exported() -> NSXPCInterface {
        _ = dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_NOW)
        let runtime = NSProtocolFromString("WallpaperExtensionXPCProtocol")
        let proto = runtime ?? LivecoreWallpaperExtensionProtocol.self
        let interface = NSXPCInterface(with: proto)
        let allowed = NSSet(array: classes.compactMap(NSClassFromString) + [
            SettingsViewModelsArchive.self, NSString.self, NSNumber.self, NSData.self,
            NSArray.self, NSDictionary.self, NSURL.self, NSError.self,
        ]) as! Set<AnyHashable>
        for (selectorName, index, reply) in [
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
        ] {
            let selector = NSSelectorFromString(selectorName)
            if protocol_getMethodDescription(proto, selector, true, true).name != nil {
                interface.setClasses(allowed, for: selector, argumentIndex: index, ofReply: reply)
            }
        }
        return interface
    }

    static func remote() -> NSXPCInterface? {
        NSProtocolFromString("WallpaperExtensionProxyXPCProtocol").map(NSXPCInterface.init(with:))
    }
}

@objc(WallpaperExtensionXPCProtocol)
protocol LivecoreWallpaperExtensionProtocol {
    func provideSettingsViewModels(withContentTypes: NSObject?, reply: @escaping (WallpaperSettingsViewModelsXPC?, NSError?) -> Void)
    func selectedChoicesDidChange(for: NSObject?, reply: @escaping (NSError?) -> Void)
    func acquire(withId: NSObject?, request: NSObject?, reply: @escaping (WallpaperRemoteContextXPC?, NSError?) -> Void)
    func update(withId: NSObject?, request: NSObject?, reply: @escaping (WallpaperRemoteContextXPC?, NSError?) -> Void)
    func invalidate(withId: NSObject?, reply: @escaping (NSError?) -> Void)
    func snapshot(withId: NSObject?, reply: @escaping (WallpaperSnapshotXPC?, NSError?) -> Void)
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
    @objc(canSkipShuffledContentWithId:reply:) func canSkip(_ id: NSObject?, reply: @escaping (Bool, NSError?) -> Void)
    @objc(skipShuffledContentWithId:reply:) func skip(_ id: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(invokeContextMenuActionWithMenuItemID:groupItemID:reply:) func invokeContextMenuAction(_ menu: NSObject?, groupItemID: NSObject?, reply: @escaping (NSError?) -> Void)
    @objc(handleDebugRequestFor:reply:) func handleDebugRequest(_ request: NSObject?, reply: @escaping (NSObject?, NSError?) -> Void)
    func handleNotification(named: String, reply: @escaping (NSError?) -> Void)
}

final class WallpaperXPCHandler: NSObject, LivecoreWallpaperExtensionProtocol {
    private let renderer = LivecoreRemoteRenderer.shared

    func provideSettingsViewModels(withContentTypes: NSObject?, reply: @escaping (WallpaperSettingsViewModelsXPC?, NSError?) -> Void) {
        reply(SettingsModelBridge.make(), nil)
    }
    func selectedChoicesDidChange(for: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }

    private func item(_ object: NSObject?) -> SharedWallpaperItem {
        guard let object else { return SharedWallpaperLibrary.currentOrFallback() }
        let selector = Selector(("configuration"))
        if object.responds(to: selector), let result = object.perform(selector),
           let data = result.takeUnretainedValue() as? Data,
           let string = String(data: data, encoding: .utf8),
           let value = SharedWallpaperLibrary.item(string) { return value }
        return SharedWallpaperLibrary.currentOrFallback()
    }

    private func key(_ identifier: NSObject?, _ request: NSObject?) -> String {
        String(reflecting: identifier ?? request ?? UUID().uuidString as NSString)
    }

    func acquire(withId identifier: NSObject?, request: NSObject?, reply: @escaping (WallpaperRemoteContextXPC?, NSError?) -> Void) {
        renderer.acquire(key: key(identifier, request), item: item(request ?? identifier), reply: reply)
    }
    func update(withId identifier: NSObject?, request: NSObject?, reply: @escaping (WallpaperRemoteContextXPC?, NSError?) -> Void) {
        renderer.acquire(key: key(identifier, request), item: item(request ?? identifier), reply: reply)
    }
    func invalidate(withId identifier: NSObject?, reply: @escaping (NSError?) -> Void) {
        renderer.invalidate(key: key(identifier, nil)); reply(nil)
    }
    func snapshot(withId identifier: NSObject?, reply: @escaping (WallpaperSnapshotXPC?, NSError?) -> Void) {
        renderer.snapshot(item: item(identifier), reply: reply)
    }
    func migrateSelectedChoice(_ choice: NSObject?, reply: @escaping (NSObject?, NSError?) -> Void) { reply(choice, nil) }
    func migrate(from: NSObject?, to: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }
    func addChoiceRequest(_ request: NSObject?, process: NSObject?, reply: @escaping (NSObject?, NSError?) -> Void) { reply(nil, nil) }
    func removeChoiceRequest(_ request: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }
    func isChoiceDownloaded(_ choice: NSObject?, reply: @escaping (Bool, NSError?) -> Void) { reply(true, nil) }
    func download(_ choice: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }
    func pauseDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }
    func cancelDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }
    func resumeDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }
    func removeDownload(_ choice: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }
    func canSkip(_ id: NSObject?, reply: @escaping (Bool, NSError?) -> Void) { reply(false, nil) }
    func skip(_ id: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }
    func invokeContextMenuAction(_ menu: NSObject?, groupItemID: NSObject?, reply: @escaping (NSError?) -> Void) { reply(nil) }
    func handleDebugRequest(_ request: NSObject?, reply: @escaping (NSObject?, NSError?) -> Void) { reply(nil, nil) }
    func handleNotification(named: String, reply: @escaping (NSError?) -> Void) { reply(nil) }
}

private enum LivecoreExtensionError: Int, Error { case rendererNotReady = 1 }

private final class RenderSession {
    let root = CALayer()
    let player: AVPlayer?
    let context: WallpaperRemoteContextXPC
    var observer: NSObjectProtocol?
    var statusObservation: NSKeyValueObservation?

    init?(item: SharedWallpaperItem) {
        root.frame = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        root.backgroundColor = NSColor.black.cgColor
        if let image = SharedWallpaperLibrary.displayImage(item) {
            root.contents = image
            root.contentsGravity = .resizeAspectFill
        }

        if SharedWallpaperLibrary.playbackEnabled(), let url = SharedWallpaperLibrary.videoURL(item) {
            let playerItem = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: playerItem)
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.automaticallyWaitsToMinimizeStalling = false
            let layer = AVPlayerLayer(player: player)
            layer.frame = root.bounds
            layer.videoGravity = .resizeAspectFill
            layer.opacity = 0
            root.addSublayer(layer)
            self.player = player
            observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak player] _ in
                player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { if $0 { player?.playImmediately(atRate: 1) } }
            }
            statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak player, weak layer] item, _ in
                guard item.status == .readyToPlay else { return }
                player?.preroll(atRate: 1) { ready in
                    DispatchQueue.main.async {
                        if ready {
                            CATransaction.begin(); CATransaction.setDisableActions(true)
                            layer?.opacity = 1; CATransaction.commit()
                            player?.playImmediately(atRate: 1)
                        }
                    }
                }
            }
        } else {
            player = nil
        }
        guard let context = LCCreateRemoteContext(root) else { return nil }
        self.context = context
    }

    deinit {
        player?.pause()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        statusObservation?.invalidate()
        LCReleaseRemoteContext(context)
    }
}

private final class LivecoreRemoteRenderer {
    static let shared = LivecoreRemoteRenderer()
    private var sessions: [String: RenderSession] = [:]

    func acquire(key: String, item: SharedWallpaperItem, reply: @escaping (WallpaperRemoteContextXPC?, NSError?) -> Void) {
        DispatchQueue.main.async {
            if let old = self.sessions.removeValue(forKey: key) { _ = old }
            guard let session = RenderSession(item: item) else {
                reply(nil, LivecoreExtensionError.rendererNotReady as NSError); return
            }
            self.sessions[key] = session
            reply(session.context, nil)
        }
    }

    func invalidate(key: String) { DispatchQueue.main.async { self.sessions.removeValue(forKey: key) } }

    func snapshot(item: SharedWallpaperItem, reply: @escaping (WallpaperSnapshotXPC?, NSError?) -> Void) {
        DispatchQueue.main.async {
            guard let image = SharedWallpaperLibrary.displayImage(item),
                  let snapshot = LCCreateWallpaperSnapshot(image) else {
                reply(nil, LivecoreExtensionError.rendererNotReady as NSError); return
            }
            reply(snapshot, nil)
        }
    }
}

private struct SharedWallpaperItem: Codable {
    let id: UUID
    let fileName: String
    let title: String
    let createdAt: Date
    static let fallback = Self(id: UUID(uuidString: "DEADBEEF-1111-2222-3333-444444444444")!, fileName: "", title: "Livecore", createdAt: .distantPast)
}
private struct SharedPlaybackState: Codable { let enabled: Bool; let updatedAt: Date }

private enum SharedWallpaperLibrary {
    static var root: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("WallpaperLibrary", isDirectory: true) }
    static func current() -> SharedWallpaperItem? {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("current.json")) else { return nil }
        return try? JSONDecoder().decode(SharedWallpaperItem.self, from: data)
    }
    static func currentOrFallback() -> SharedWallpaperItem { current() ?? .fallback }
    static func item(_ uuid: String) -> SharedWallpaperItem? { current() ?? .fallback }
    static func playbackEnabled() -> Bool {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("playback-state.json")),
              let state = try? JSONDecoder().decode(SharedPlaybackState.self, from: data) else { return false }
        return state.enabled
    }
    static func videoURL(_ item: SharedWallpaperItem) -> URL? {
        guard let root, !item.fileName.isEmpty else { return nil }
        let url = root.appendingPathComponent(item.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    static func imageURL(_ item: SharedWallpaperItem) -> URL? {
        guard let root else { return nil }
        if playbackEnabled() {
            let thumbnail = root.appendingPathComponent("\(item.id.uuidString).jpg")
            if FileManager.default.fileExists(atPath: thumbnail.path) { return thumbnail }
        }
        let fallback = root.appendingPathComponent("LivecoreFallback.jpg")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
    static func displayImage(_ item: SharedWallpaperItem) -> CGImage? {
        guard let url = imageURL(item), let image = NSImage(contentsOf: url) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

private enum SettingsModelBridge {
    static func make() -> WallpaperSettingsViewModelsXPC? {
        guard let url = SharedWallpaperLibrary.imageURL(SharedWallpaperLibrary.currentOrFallback()) else { return remap(.init(value: .empty)) }
        let item = SharedWallpaperLibrary.currentOrFallback()
        let descriptor = WallpaperChoiceDescriptor(provider: .init(rawValue: "com.berkegulacar.Livecore.wallpaper-extension"), files: [], configuration: Data(item.id.uuidString.utf8))
        let thumb = Thumbnail.image(url)
        let choice = WallpaperChoice(id: .init(descriptor: descriptor), localizedDescription: item.title, thumbnail: thumb, isDownloaded: true, options: [])
        let settingsItem = SettingsItem(id: .init(id: item.id.uuidString), localizedName: item.title, thumbnail: thumb, choice: choice, contentBadge: SharedWallpaperLibrary.playbackEnabled() ? .video : .none, showInTopLevel: true, sortOrder: 0, disposability: .none)
        let group = SettingsGroup(id: .init(id: "livecore"), items: [settingsItem], localizedName: "Livecore", disposability: .none, sortOrder: 0, sortID: .init(id: "other"), allChoiceID: nil, shouldHideItemLabels: false, contextMenu: nil, thumbnail: nil)
        return remap(.init(value: .init(desktop: .init(groups: [group], refreshPolicy: .default, isModificationDisabled: false), screenSaver: nil)))
    }
    private static func remap(_ archive: SettingsViewModelsArchive) -> WallpaperSettingsViewModelsXPC? {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: archive, requiringSecureCoding: true)
            guard let runtime = NSClassFromString("WallpaperSettingsViewModelsXPC"),
                  let object = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [runtime, NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self, NSURL.self], from: data) as AnyObject? else { return nil }
            return unsafeBitCast(object, to: WallpaperSettingsViewModelsXPC.self)
        } catch { return nil }
    }
}

private struct SettingsViewModels: Codable {
    let desktop: SettingsViewModel?; let screenSaver: SettingsViewModel?
    static let empty = Self(desktop: .init(groups: [], refreshPolicy: .default, isModificationDisabled: false), screenSaver: nil)
}
private struct SettingsViewModel: Codable { let groups: [SettingsGroup]; let refreshPolicy: RefreshPolicy; let isModificationDisabled: Bool }
private enum RefreshPolicy: Codable { case `default` }
private enum Thumbnail: Codable {
    case image(URL)
    private enum K: String, CodingKey { case image }; private enum I: String, CodingKey { case url }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self); let i = try c.nestedContainer(keyedBy: I.self, forKey: .image); self = .image(try i.decode(URL.self, forKey: .url)) }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: K.self); var i = c.nestedContainer(keyedBy: I.self, forKey: .image); if case let .image(url) = self { try i.encode(url, forKey: .url) } }
}
private enum ContentBadge: Codable { case none, video, dynamic }
private enum Disposability: Codable { case none, removable, purgeable }
private struct ChoiceProviderID: Codable { let rawValue: String; init(rawValue: String) { self.rawValue = rawValue }; init(from d: Decoder) throws { rawValue = try d.singleValueContainer().decode(String.self) }; func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(rawValue) } }
private struct ChoiceID: Codable { let descriptor: WallpaperChoiceDescriptor }
private struct ChoiceIDDescriptor: Codable { let id: String }
private struct GroupID: Codable { let id: String }
private struct WallpaperOption: Codable {}
private struct ContextMenu: Codable { let items: [ContextMenuItem] }
private struct ContextMenuItem: Codable { let id: String; let descriptor: ContextMenuItemDescriptor }
private struct ContextMenuItemDescriptor: Codable { let identifier: String; let name: String }
private struct WallpaperChoiceDescriptor: Codable { let provider: ChoiceProviderID; let files: [URL]; let configuration: Data }
private struct WallpaperChoice: Codable { let id: ChoiceID; let localizedDescription: String; let thumbnail: Thumbnail; let isDownloaded: Bool; let options: [WallpaperOption] }
private struct SettingsItem: Codable { let id: ChoiceIDDescriptor; let localizedName: String; let thumbnail: Thumbnail; let choice: WallpaperChoice; let contentBadge: ContentBadge; let showInTopLevel: Bool; let sortOrder: Int; let disposability: Disposability }
private struct SettingsGroup: Codable { let id: GroupID; let items: [SettingsItem]; let localizedName: String; let disposability: Disposability; let sortOrder: Int; let sortID: GroupID?; let allChoiceID: ChoiceID?; let shouldHideItemLabels: Bool?; let contextMenu: ContextMenu?; let thumbnail: URL? }

@objc(LivecoreSettingsViewModelsArchive)
private final class SettingsViewModelsArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }; let value: SettingsViewModels
    init(value: SettingsViewModels) { self.value = value; super.init() }
    required init?(coder: NSCoder) { nil }
    override var classForKeyedArchiver: AnyClass { NSClassFromString("WallpaperSettingsViewModelsXPC") ?? Self.self }
    func encode(with coder: NSCoder) { guard let a = coder as? NSKeyedArchiver else { return }; try? a.encodeEncodable(value, forKey: "WallpaperSettingsViewModels") }
}
