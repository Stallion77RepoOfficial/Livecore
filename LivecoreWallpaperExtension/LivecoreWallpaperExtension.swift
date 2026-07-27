import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import ExtensionFoundation
import Foundation
import QuartzCore

@main
struct LivecoreWallpaperExtension: AppExtension {
    var configuration: ConnectionHandler {
        ConnectionHandler { connection in
            WallpaperXPCInterface.configure(connection)
        }
    }
}

private enum WallpaperXPCInterface {
    private static let classNames = [
        "WallpaperIDXPC", "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC",
        "WallpaperContentTypeSetXPC", "WallpaperCreationRequestXPC",
        "WallpaperUpdateRequestXPC", "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC",
        "WallpaperSettingsViewModelsXPC", "WallpaperExtensionChoiceRequestXPC",
        "WallpaperChoiceRequestAdditionResultXPC", "WallpaperMigrationVersionXPC",
        "WallpaperDebugRequestXPC", "WallpaperDebugResponseXPC", "AuditTokenXPC",
    ]

    static func configure(_ connection: NSXPCConnection) -> Bool {
        _ = dlopen(
            "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit",
            RTLD_NOW
        )
        let exported = NSXPCInterface(with: (any WallpaperExtensionXPCProtocol).self)
        let allowed = NSMutableSet(array: classNames.compactMap(NSClassFromString))
        [
            LivecoreSettingsViewModelsArchive.self, NSString.self, NSNumber.self, NSData.self,
            NSArray.self, NSDictionary.self, NSURL.self, NSError.self,
        ].forEach(allowed.add)
        let classes = allowed as! Set<AnyHashable>

        let selectors: [(Selector, Int, Bool)] = [
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.invalidate(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.isChoiceDownloaded(with:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.isChoiceDownloaded(with:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.download(withChoiceID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.pauseDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.cancelDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.resumeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.removeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.skipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.canSkipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.canSkipShuffledContent(withId:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.handleNotification(withNamed:reply:)), 0, false),
        ]
        for (selector, index, isReply) in selectors {
            exported.setClasses(classes, for: selector, argumentIndex: index, ofReply: isReply)
        }

        let handler = WallpaperXPCHandler()
        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(
            with: (any WallpaperExtensionProxyXPCProtocol).self
        )
        connection.exportedObject = handler
        handler.agentProxy = connection.remoteObjectProxy as? any WallpaperExtensionProxyXPCProtocol
        connection.interruptionHandler = { handler.agentProxy = nil }
        connection.invalidationHandler = { handler.agentProxy = nil }
        connection.resume()
        return true
    }
}

final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    private let renderer = LivecoreRemoteRenderer.shared
    private var assetObserver: NSObjectProtocol?
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)?

    override init() {
        super.init()
        assetObserver = DistributedNotificationCenter.default().addObserver(
            forName: LivecoreNotification.assetsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.renderer.announceReadiness(for: SharedWallpaperLibrary.current()?.id)
            self?.pushSettings()
        }
    }

    deinit {
        if let assetObserver {
            DistributedNotificationCenter.default().removeObserver(assetObserver)
        }
    }

    func acquire(
        withId identifier: Any?,
        request: Any?,
        reply: @escaping @Sendable (Any?, (any Error)?) -> Void
    ) {
        guard let configuration = requestString(named: "configuration", in: request),
              let id = UUID(uuidString: configuration),
              let item = SharedWallpaperLibrary.item(id),
              let surface = requestSurface(identifier, request)
        else {
            reply(nil, LivecoreExtensionError.malformedRequest)
            return
        }
        let mode = requestValue(named: "presentationMode", in: request)
            .map(enumCaseName) ?? "default"
        renderer.acquire(surface: surface, item: item, initialMode: mode, reply: reply)
    }

    func update(
        withId identifier: Any?,
        request: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let surface = requestSurface(identifier, request) else {
            reply(LivecoreExtensionError.malformedRequest)
            return
        }
        let mode = requestValue(named: "presentationMode", in: request)
            .map(enumCaseName) ?? "default"
        let activity = requestValue(named: "activityState", in: request)
            .map(enumCaseName) ?? "active"
        renderer.update(surface: surface, presentationMode: mode, activityState: activity)
        reply(nil)
    }

    func invalidate(
        withId identifier: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        renderer.invalidate(identifier: findUUID(in: identifier))
        reply(nil)
    }

    func snapshot(
        withId identifier: Any?,
        reply: @escaping @Sendable (Any?, (any Error)?) -> Void
    ) {
        let requested = requestString(named: "configuration", in: identifier)
            .flatMap(UUID.init(uuidString:))
            .flatMap(SharedWallpaperLibrary.item)
        guard let item = requested ?? SharedWallpaperLibrary.current(),
              let image = SharedWallpaperLibrary.thumbnail(item),
              let snapshot = LCCreateWallpaperSnapshot(image)
        else {
            reply(nil, LivecoreExtensionError.snapshotUnavailable)
            return
        }
        reply(snapshot, nil)
    }

    func provideSettingsViewModels(
        withContentTypes _: Any?,
        reply: @escaping @Sendable (Any?, (any Error)?) -> Void
    ) { reply(SettingsModelBridge.make(), nil) }

    func selectedChoicesDidChange(
        for _: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) { reply(nil) }

    func addChoiceRequest(
        withChoiceRequest _: Any?,
        onBehalfOfProcess _: Any?,
        reply: @escaping @Sendable (Any?, (any Error)?) -> Void
    ) { reply(nil, nil) }

    func removeChoiceRequest(
        withChoiceRequest _: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) { reply(nil) }

    func migrateSelectedChoice(
        for choice: Any?,
        reply: @escaping @Sendable (Any?, (any Error)?) -> Void
    ) { reply(choice, nil) }

    func migrate(
        from _: Any?,
        to _: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) { reply(nil) }

    // Livecore's videos are always local, so nothing is ever downloaded.
    func isChoiceDownloaded(
        with _: Any?,
        reply: @escaping @Sendable (NSNumber?, (any Error)?) -> Void
    ) { reply(NSNumber(value: true), nil) }

    func download(
        withChoiceID _: Any?,
        reply: ((any Error)?) -> Void
    ) -> Any? {
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func canSkipShuffledContent(
        withId _: Any?,
        reply: @escaping @Sendable (NSNumber?, (any Error)?) -> Void
    ) { reply(NSNumber(value: false), nil) }
    func skipShuffledContent(
        withId _: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) { reply(nil) }
    func invokeContextMenuAction(
        withMenuItemID _: Any?,
        groupItemID _: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) { reply(nil) }
    func handleDebugRequest(
        for _: Any?,
        reply: @escaping @Sendable (Any?, (any Error)?) -> Void
    ) { reply(nil, nil) }
    func handleNotification(
        withNamed _: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        pushSettings()
        reply(nil)
    }

    private func pushSettings() {
        if let models = SettingsModelBridge.make() {
            agentProxy?.updateSettingsViewModels(models) { _ in }
        }
        agentProxy?.invalidateSnapshots { _ in }
    }
}

private enum LivecoreExtensionError: Int, Error {
    case malformedRequest = 1
    case rendererUnavailable = 2
    case snapshotUnavailable = 3
}

/// The surface WallpaperAgent asked about: which wallpaper, on which display,
/// at what size.
private struct RequestSurface: Hashable {
    let identifier: UUID
    let displayID: UInt32
    let size: CGSize
    let scale: CGFloat
    let isPreview: Bool

    var key: SurfaceKey {
        SurfaceKey(identifier: identifier, displayID: displayID, isPreview: isPreview)
    }
}

private struct SurfaceKey: Hashable {
    let identifier: UUID
    let displayID: UInt32
    let isPreview: Bool
}

/// Latched lock-screen state. WallpaperAgent keeps sending presentation-mode
/// and activity updates while the screen stays locked (for example when the
/// user idles with a display-sleep assertion held); relying on those updates
/// alone downgrades the renderer to a frozen still.
private enum ScreenLockState {
    private static let lock = NSLock()
    private static var locked = false

    static var isLocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return locked
    }

    static func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        locked = value
    }
}

private final class LivecoreRemoteRenderer: @unchecked Sendable {
    static let shared = LivecoreRemoteRenderer()

    private var sessions: [SurfaceKey: RenderSession] = [:]
    /// A replaced context remains alive until WallpaperAgent invalidates it.
    private var supersededSessions: [SurfaceKey: [RenderSession]] = [:]
    private var retirementCounts: [UUID: Int] = [:]

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            ScreenLockState.set(true)
            self?.updateAll(presentationMode: "locked", activityState: "active")
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            ScreenLockState.set(false)
            self?.updateAll(presentationMode: "default", activityState: "active")
        }
    }

    func acquire(
        surface: RequestSurface,
        item: LivecoreWallpaperItem,
        initialMode: String,
        reply: @escaping @Sendable (Any?, (any Error)?) -> Void
    ) {
        DispatchQueue.main.async {
            if let session = self.sessions[surface.key],
               session.matches(item: item, isPreview: surface.isPreview) {
                session.update(
                    surface: surface,
                    presentationMode: initialMode,
                    activityState: "active"
                )
                reply(session.context, nil)
                self.postReadinessIfHealthy(session)
                return
            }
            guard let session = RenderSession(surface: surface, item: item) else {
                reply(nil, LivecoreExtensionError.rendererUnavailable)
                return
            }
            if let previous = self.sessions.updateValue(session, forKey: surface.key) {
                self.supersededSessions[surface.key, default: []].append(previous)
            }
            session.update(
                surface: surface,
                presentationMode: initialMode,
                activityState: "active"
            )
            reply(session.context, nil)
            self.postReadinessIfHealthy(session)
        }
    }

    func update(surface: RequestSurface, presentationMode: String, activityState: String) {
        DispatchQueue.main.async {
            if let session = self.sessions[surface.key] {
                session.update(
                    surface: surface,
                    presentationMode: presentationMode,
                    activityState: activityState
                )
                self.postReadinessIfHealthy(session)
                return
            }

            // Update variants may omit directDisplayID or isPreview. Preserve
            // the acquired identity while applying their new geometry.
            let candidates = self.sessions.filter { key, _ in
                key.identifier == surface.identifier
                    && (surface.displayID == 0 || key.displayID == surface.displayID)
            }
            for (key, session) in candidates {
                let adjusted = RequestSurface(
                    identifier: key.identifier,
                    displayID: key.displayID,
                    size: surface.size,
                    scale: surface.scale,
                    isPreview: key.isPreview
                )
                session.update(
                    surface: adjusted,
                    presentationMode: presentationMode,
                    activityState: activityState
                )
                self.postReadinessIfHealthy(session)
            }
        }
    }

    func updateAll(presentationMode: String, activityState: String) {
        DispatchQueue.main.async {
            let allSessions = Array(self.sessions.values)
                + self.supersededSessions.values.flatMap { $0 }
            allSessions.filter { !$0.isPreview }.forEach {
                $0.updatePlayback(
                    presentationMode: presentationMode,
                    activityState: activityState
                )
            }
        }
    }

    func announceReadiness(for itemID: UUID?) {
        DispatchQueue.main.async {
            guard let itemID,
                  let session = self.sessions.values.first(where: {
                      $0.itemID == itemID && !$0.isPreview && $0.isReady
                  })
            else { return }
            self.postReadinessIfHealthy(session)
        }
    }

    func invalidate(identifier: UUID?) {
        DispatchQueue.main.async {
            if let identifier {
                var oldestGeneration: [RenderSession] = []
                let keys = self.supersededSessions.keys.filter {
                    $0.identifier == identifier
                }
                for key in keys {
                    guard var pending = self.supersededSessions[key],
                          !pending.isEmpty
                    else { continue }
                    oldestGeneration.append(pending.removeFirst())
                    if pending.isEmpty {
                        self.supersededSessions.removeValue(forKey: key)
                    } else {
                        self.supersededSessions[key] = pending
                    }
                }
                if !oldestGeneration.isEmpty {
                    self.retire(oldestGeneration)
                    return
                }

                let activeKeys = self.sessions.keys.filter { $0.identifier == identifier }
                let active = activeKeys.compactMap { self.sessions.removeValue(forKey: $0) }
                self.retire(active)
                return
            }

            let superseded = self.supersededSessions.values.flatMap { $0 }
            self.supersededSessions.removeAll()
            let keys = Array(self.sessions.keys)
            let active = keys.compactMap { self.sessions.removeValue(forKey: $0) }
            self.retire(superseded + active)
        }
    }

    private func retire(_ retiring: [RenderSession]) {
        for session in retiring {
            retirementCounts[session.itemID, default: 0] += 1
            session.invalidate { [weak self] in
                self?.finishRetirement(of: session.itemID)
            }
        }
    }

    private func finishRetirement(of itemID: UUID) {
        let remaining = max(0, (retirementCounts[itemID] ?? 1) - 1)
        if remaining == 0 {
            retirementCounts.removeValue(forKey: itemID)
        } else {
            retirementCounts[itemID] = remaining
        }
        guard remaining == 0,
              !sessions.values.contains(where: { $0.itemID == itemID }),
              !supersededSessions.values.joined().contains(where: { $0.itemID == itemID })
        else { return }
        DistributedNotificationCenter.default().postNotificationName(
            LivecoreNotification.rendererRetired,
            object: itemID.uuidString,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func postReadinessIfHealthy(_ session: RenderSession) {
        guard !session.isPreview, session.isReady else { return }
        DistributedNotificationCenter.default().postNotificationName(
            LivecoreNotification.rendererReady,
            object: session.itemID.uuidString,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

private final class RenderSession {
    let context: AnyObject
    let isPreview: Bool

    var itemID: UUID { item.id }
    var isHealthy: Bool { !invalidated && pump.isHealthy }
    var isReady: Bool { isHealthy }

    private var surface: RequestSurface
    private let item: LivecoreWallpaperItem
    private let rootLayer: CALayer
    private let pump: SampleBufferPump
    private var invalidated = false
    private var contextReleased = false
    private var invalidationCompletions: [() -> Void] = []

    init?(surface: RequestSurface, item: LivecoreWallpaperItem) {
        // The live surface paints the previous Desktop picture while unlocked.
        // Settings previews show the video's poster instead.
        guard let playbackPlaceholder = SharedWallpaperLibrary.thumbnail(item),
              let still = surface.isPreview
                ? playbackPlaceholder
                : SharedWallpaperLibrary.desktopStill(item, displayID: surface.displayID)
        else { return nil }

        let root = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.bounds = CGRect(origin: .zero, size: surface.size)
        root.frame = CGRect(origin: .zero, size: surface.size)
        root.contentsScale = surface.scale
        root.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
        guard let pump = SampleBufferPump(
            rootLayer: root,
            videoURL: SharedWallpaperLibrary.videoURL(item),
            stillImage: still,
            playbackPlaceholderImage: playbackPlaceholder
        ), let context = LCCreateRemoteContext(root, surface.displayID) as AnyObject? else {
            return nil
        }

        self.surface = surface
        self.item = item
        self.isPreview = surface.isPreview
        self.context = context
        self.rootLayer = root
        self.pump = pump
    }

    func matches(item: LivecoreWallpaperItem, isPreview: Bool) -> Bool {
        self.item.id == item.id && self.isPreview == isPreview
    }

    func update(surface: RequestSurface, presentationMode: String, activityState: String) {
        guard !invalidated else { return }
        resize(to: surface)
        updatePlayback(presentationMode: presentationMode, activityState: activityState)
    }

    func updatePlayback(presentationMode: String, activityState: String) {
        guard !invalidated else { return }
        if presentationMode == "locked" { ScreenLockState.set(true) }
        let shouldPlay = isPreview
            ? activityState == "active"
            : presentationMode == "locked" || ScreenLockState.isLocked
        if shouldPlay { pump.play() } else { pump.showStill() }
    }

    func invalidate(completion: @escaping () -> Void) {
        invalidationCompletions.append(completion)
        guard !invalidated else { return }
        invalidated = true
        pump.stop { [self] in
            guard !contextReleased else { return }
            contextReleased = true
            LCReleaseRemoteContext(context)
            let completions = invalidationCompletions
            invalidationCompletions.removeAll()
            completions.forEach { $0() }
        }
    }

    private func resize(to updated: RequestSurface) {
        let sizeChanged = abs(surface.size.width - updated.size.width) >= 0.5
            || abs(surface.size.height - updated.size.height) >= 0.5
        let scaleChanged = abs(surface.scale - updated.scale) >= 0.01
        surface = updated
        guard sizeChanged || scaleChanged else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.bounds = CGRect(origin: .zero, size: updated.size)
        rootLayer.frame = CGRect(origin: .zero, size: updated.size)
        rootLayer.contentsScale = updated.scale
        CATransaction.commit()
        pump.resize(to: rootLayer.bounds, scale: updated.scale)
    }
}

private final class SampleBufferPump: @unchecked Sendable {
    private let rootLayer: CALayer
    private var displayLayer: AVSampleBufferDisplayLayer
    private var renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private let asset: AVURLAsset
    private let stillBuffer: CMSampleBuffer
    private let playbackPlaceholderBuffer: CMSampleBuffer
    private let decodeQueue = DispatchQueue(label: "com.livecore.app.video-decoder", qos: .userInitiated)
    private let attemptGroup = DispatchGroup()
    private let stateLock = NSLock()
    private let renderLock = NSLock()
    private var token: UUID?
    private var playbackRequested = false
    private var retryAttempt = 0
    private var playbackGeneration: UInt64 = 0
    private var stopped = false

    var isHealthy: Bool {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        renderLock.lock()
        let rendererFailed = renderer.status == .failed
        renderLock.unlock()
        return !isStopped && !rendererFailed
    }

    init?(
        rootLayer: CALayer,
        videoURL: URL,
        stillImage: CGImage,
        playbackPlaceholderImage: CGImage
    ) {
        let asset = AVURLAsset(url: videoURL)
        guard let stillBuffer = makeStillSampleBuffer(from: stillImage),
              let playbackPlaceholderBuffer = makeStillSampleBuffer(from: playbackPlaceholderImage)
        else { return nil }

        let layer = AVSampleBufferDisplayLayer()
        layer.frame = rootLayer.bounds
        layer.contentsScale = rootLayer.contentsScale
        layer.videoGravity = .resizeAspectFill
        layer.isOpaque = true
        setDisallowsVideoLayerDisplayCompositing(layer)

        var timebase: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        ) == noErr, let timebase else { return nil }
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0)
        layer.controlTimebase = timebase

        self.rootLayer = rootLayer
        self.displayLayer = layer
        self.renderer = layer.sampleBufferRenderer
        self.timebase = timebase
        self.asset = asset
        self.stillBuffer = stillBuffer
        self.playbackPlaceholderBuffer = playbackPlaceholderBuffer

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(layer)
        CATransaction.commit()
        showStill()
    }

    func play() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        if !playbackRequested {
            playbackGeneration &+= 1
            retryAttempt = 0
        }
        playbackRequested = true
        guard token == nil else {
            stateLock.unlock()
            return
        }
        let attempt = UUID()
        let generation = playbackGeneration
        token = attempt
        stateLock.unlock()

        startAttempt(attempt, generation: generation)
    }

    func showStill() {
        cancelPlayback()
        guard !isStopped else { return }
        renderLock.lock()
        CMTimebaseSetRate(timebase, rate: 0)
        renderer.flush()
        markDisplayImmediately(stillBuffer)
        renderer.enqueue(stillBuffer)
        renderLock.unlock()
    }

    func resize(to bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.contentsScale = scale
        CATransaction.commit()
    }

    func stop(completion: @escaping () -> Void) {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            attemptGroup.notify(queue: .main, execute: completion)
            return
        }
        stopped = true
        playbackGeneration &+= 1
        playbackRequested = false
        retryAttempt = 0
        token = nil
        stateLock.unlock()

        renderLock.lock()
        CMTimebaseSetRate(timebase, rate: 0)
        renderer.flush(removingDisplayedImage: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.removeFromSuperlayer()
        CATransaction.commit()
        renderLock.unlock()
        attemptGroup.notify(queue: .main, execute: completion)
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func cancelPlayback() {
        stateLock.lock()
        playbackGeneration &+= 1
        playbackRequested = false
        retryAttempt = 0
        token = nil
        stateLock.unlock()
    }

    private func startAttempt(_ attempt: UUID, generation: UInt64) {
        guard isCurrent(attempt, generation: generation) else { return }
        renderLock.lock()
        renderer.flush()
        markDisplayImmediately(playbackPlaceholderBuffer)
        renderer.enqueue(playbackPlaceholderBuffer)
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 1)
        renderLock.unlock()

        attemptGroup.enter()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let track = try? await self.asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await track.load(.timeRange).duration,
                  self.isCurrent(attempt, generation: generation)
            else {
                self.finishAttempt(attempt, generation: generation, retry: true)
                self.attemptGroup.leave()
                return
            }
            self.decodeQueue.async {
                self.decodeLoop(
                    track: track,
                    trackDuration: duration,
                    token: attempt,
                    generation: generation
                )
                self.attemptGroup.leave()
            }
        }
    }

    private func isCurrent(_ candidate: UUID, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !stopped
            && playbackRequested
            && token == candidate
            && playbackGeneration == generation
    }

    private func isGenerationCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return playbackGeneration == generation && playbackRequested && !stopped
    }

    private func notePlaybackProgress(_ candidate: UUID, generation: UInt64) {
        stateLock.lock()
        if token == candidate, playbackGeneration == generation {
            retryAttempt = 0
        }
        stateLock.unlock()
    }

    private func finishAttempt(
        _ candidate: UUID,
        generation: UInt64,
        retry: Bool,
        rebuildRenderer: Bool = false
    ) {
        stateLock.lock()
        guard token == candidate, playbackGeneration == generation else {
            stateLock.unlock()
            return
        }
        token = nil
        let shouldRetry = retry
            && playbackRequested
            && !stopped
            && retryAttempt < 5
        let delay = min(0.25 * pow(2, Double(retryAttempt)), 4)
        if shouldRetry { retryAttempt += 1 }
        let shouldFallBack = retry && playbackRequested && !stopped && !shouldRetry
        stateLock.unlock()

        if shouldRetry {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.isGenerationCurrent(generation) else { return }
                if rebuildRenderer {
                    self.rebuildDisplayLayerIfFailed()
                }
                self.stateLock.lock()
                guard self.playbackRequested,
                      !self.stopped,
                      self.playbackGeneration == generation,
                      self.token == nil
                else {
                    self.stateLock.unlock()
                    return
                }
                let retryToken = UUID()
                self.token = retryToken
                self.stateLock.unlock()
                self.startAttempt(retryToken, generation: generation)
            }
        } else if shouldFallBack {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isGenerationCurrent(generation) else { return }
                if rebuildRenderer {
                    self.rebuildDisplayLayerIfFailed()
                }
                self.showStill()
            }
        }
    }

    /// A display renderer can remain failed after `flush()`. Replace only its
    /// sublayer; the root layer and CAContext handed to WallpaperAgent stay
    /// alive and keep the same point-space geometry.
    private func rebuildDisplayLayerIfFailed() {
        renderLock.lock()
        guard renderer.status == .failed else {
            renderLock.unlock()
            return
        }

        let replacement = AVSampleBufferDisplayLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replacement.frame = rootLayer.bounds
        replacement.contentsScale = rootLayer.contentsScale
        replacement.videoGravity = .resizeAspectFill
        replacement.isOpaque = true
        replacement.controlTimebase = timebase
        setDisallowsVideoLayerDisplayCompositing(replacement)

        displayLayer.removeFromSuperlayer()
        rootLayer.addSublayer(replacement)
        CATransaction.commit()

        displayLayer = replacement
        renderer = replacement.sampleBufferRenderer
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0)
        renderer.flush()
        markDisplayImmediately(playbackPlaceholderBuffer)
        renderer.enqueue(playbackPlaceholderBuffer)
        renderLock.unlock()
    }

    private func decodeLoop(
        track: AVAssetTrack,
        trackDuration: CMTime,
        token: UUID,
        generation: UInt64
    ) {
        var rendererNeedsRebuild = false
        defer {
            finishAttempt(
                token,
                generation: generation,
                retry: true,
                rebuildRenderer: rendererNeedsRebuild
            )
        }
        var loopOffset = CMTime.zero
        while isCurrent(token, generation: generation) {
            guard let reader = try? AVAssetReader(asset: asset) else { break }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { break }
            reader.add(output)
            guard reader.startReading() else { break }

            var firstPTS: CMTime?
            var lastEnd = loopOffset
            var rendererFailed = false
            while isCurrent(token, generation: generation), reader.status == .reading {
                renderLock.lock()
                if renderer.requiresFlushToResumeDecoding {
                    renderer.flush()
                }
                rendererFailed = renderer.status == .failed
                let ready = renderer.isReadyForMoreMediaData
                renderLock.unlock()
                if rendererFailed {
                    rendererNeedsRebuild = true
                    break
                }
                guard ready else {
                    Thread.sleep(forTimeInterval: 0.004)
                    continue
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    Thread.sleep(forTimeInterval: 0.002)
                    continue
                }
                notePlaybackProgress(token, generation: generation)
                let samplePTS = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstPTS == nil, samplePTS.isNumeric {
                    let sampleDTS = CMSampleBufferGetDecodeTimeStamp(sample)
                    firstPTS = sampleDTS.isNumeric
                        ? CMTimeMinimum(samplePTS, sampleDTS)
                        : samplePTS
                }
                let shift = CMTimeSubtract(loopOffset, firstPTS ?? .zero)
                guard let adjusted = retime(sample, by: shift) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
                let duration = CMSampleBufferGetDuration(adjusted)
                guard pts.isNumeric else { continue }
                if duration.isNumeric {
                    lastEnd = CMTimeMaximum(lastEnd, CMTimeAdd(pts, duration))
                }

                renderLock.lock()
                if isCurrent(token, generation: generation) {
                    renderer.enqueue(adjusted)
                }
                renderLock.unlock()
            }
            if reader.status == .reading {
                reader.cancelReading()
            }
            guard !rendererFailed,
                  isCurrent(token, generation: generation),
                  reader.status != .failed
            else { break }
            if CMTimeCompare(lastEnd, loopOffset) > 0 {
                loopOffset = lastEnd
            } else if CMTimeCompare(trackDuration, .zero) > 0 {
                loopOffset = CMTimeAdd(loopOffset, trackDuration)
            } else {
                break
            }
        }
    }
}

private func retime(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
    var count = 0
    guard CMSampleBufferGetSampleTimingInfoArray(
        sample,
        entryCount: 0,
        arrayToFill: nil,
        entriesNeededOut: &count
    ) == noErr, count > 0 else { return nil }
    var timings = [CMSampleTimingInfo](
        repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
        count: count
    )
    guard CMSampleBufferGetSampleTimingInfoArray(
        sample,
        entryCount: count,
        arrayToFill: &timings,
        entriesNeededOut: &count
    ) == noErr else { return nil }
    for index in timings.indices {
        if timings[index].presentationTimeStamp.isValid {
            timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, offset)
        }
        if timings[index].decodeTimeStamp.isValid {
            timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, offset)
        }
    }
    var result: CMSampleBuffer?
    guard CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault,
        sampleBuffer: sample,
        sampleTimingEntryCount: count,
        sampleTimingArray: &timings,
        sampleBufferOut: &result
    ) == noErr else { return nil }
    return result
}

private func makeStillSampleBuffer(from image: CGImage) -> CMSampleBuffer? {
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(
        kCFAllocatorDefault,
        image.width,
        image.height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    ) == kCVReturnSuccess, let pixelBuffer else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &format
    ) == noErr, let format else { return nil }
    var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &sample
    ) == noErr else { return nil }
    return sample
}

private func markDisplayImmediately(_ sample: CMSampleBuffer) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sample,
        createIfNecessary: true
    ) else { return }
    for index in 0..<CFArrayGetCount(attachments) {
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, index),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

private func setDisallowsVideoLayerDisplayCompositing(_ layer: CALayer) {
    let selector = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: selector),
          let implementation = class_getMethodImplementation(type(of: layer), selector)
    else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(implementation, to: Setter.self)(layer, selector, true)
}

/// The app's library, seen from inside the extension's sandbox container.
private enum SharedWallpaperLibrary {
    /// Inside the sandbox this is the container's Documents folder, which is
    /// where the app writes the library.
    ///
    /// Resolve it through `FileManager`, never by appending to
    /// `NSHomeDirectory()`: the container is provisioned as the extension
    /// launches, and the two do not agree on the first launch after install.
    private static let reader = LivecoreLibraryReader(
        root: FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(LivecoreLibraryFile.directoryName, isDirectory: true)
    )

    static func current() -> LivecoreWallpaperItem? { reader.currentItem() }

    static func item(_ id: UUID) -> LivecoreWallpaperItem? { reader.item(id) }

    static func videoURL(_ item: LivecoreWallpaperItem) -> URL { reader.videoURL(for: item) }

    static func thumbnailURL(_ item: LivecoreWallpaperItem) -> URL { reader.thumbnailURL(for: item) }

    static func thumbnail(_ item: LivecoreWallpaperItem) -> CGImage? {
        image(reader.thumbnailURL(for: item))
    }

    static func desktopStill(_ item: LivecoreWallpaperItem, displayID: UInt32) -> CGImage? {
        reader.desktopImageURL(for: item, displayID: String(displayID)).flatMap(image)
    }

    private static func image(_ url: URL) -> CGImage? {
        NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

private enum SettingsModelBridge {
    static func make() -> AnyObject? {
        // Without an identifier there is no provider to describe.
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        // An empty model is the honest answer when the app has published
        // nothing: the Wallpaper pane then shows no Livecore entry.
        guard let item = SharedWallpaperLibrary.current() else {
            return remap(SettingsViewModels(desktop: emptyModel, screenSaver: nil))
        }

        let provider = ChoiceProviderID(rawValue: bundleID)
        let descriptor = ChoiceIDDescriptor(
            provider: provider,
            identifier: item.id.uuidString,
            files: [SharedWallpaperLibrary.videoURL(item)],
            configuration: Data(item.id.uuidString.utf8)
        )
        let choiceID = ChoiceID(id: item.id.uuidString, descriptor: descriptor)
        let thumbnail = Thumbnail.image(url: SharedWallpaperLibrary.thumbnailURL(item))
        let choice = ChoiceDescriptor(
            id: choiceID,
            provider: provider,
            identifier: item.id.uuidString,
            name: item.title,
            localizedDescription: "Livecore video wallpaper",
            thumbnail: thumbnail,
            isDownloaded: true,
            options: []
        )
        let settingsItem = SettingsItem(
            id: choiceID,
            localizedName: item.title,
            thumbnail: thumbnail,
            choice: choice,
            contentBadge: .video,
            showInTopLevel: true,
            sortOrder: 0,
            disposability: .none
        )
        let group = SettingsGroup(
            id: GroupID(id: "livecore"),
            items: [settingsItem],
            localizedName: "Livecore",
            disposability: .none,
            sortOrder: -100,
            sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
            allChoiceID: nil,
            shouldHideItemLabels: false,
            contextMenu: nil,
            thumbnail: nil
        )
        let model = SettingsViewModel(
            groups: [group],
            refreshPolicy: .default,
            isModificationDisabled: false
        )
        return remap(SettingsViewModels(desktop: model, screenSaver: nil))
    }

    private static var emptyModel: SettingsViewModel {
        SettingsViewModel(groups: [], refreshPolicy: .default, isModificationDisabled: false)
    }

    private static func remap(_ models: SettingsViewModels) -> AnyObject? {
        let archive: Data
        do {
            archive = try NSKeyedArchiver.archivedData(
                withRootObject: LivecoreSettingsViewModelsArchive(value: models),
                requiringSecureCoding: false
            )
        } catch {
            return nil
        }
        guard let runtime = NSClassFromString("WallpaperSettingsViewModelsXPC"),
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive)
        else {
            return nil
        }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(runtime, forClassName: "LivecoreSettingsViewModelsArchive")
        let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as AnyObject?
        unarchiver.finishDecoding()
        return result
    }
}

private struct SettingsViewModels: Codable {
    let desktop: SettingsViewModel?
    let screenSaver: SettingsViewModel?
}

private struct SettingsViewModel: Codable {
    let groups: [SettingsGroup]
    let refreshPolicy: RefreshPolicy
    let isModificationDisabled: Bool
}

private struct SettingsGroup: Codable {
    let id: GroupID
    let items: [SettingsItem]
    let localizedName: String
    let disposability: Disposability
    let sortOrder: Int
    let sortID: GroupSortID?
    let allChoiceID: ChoiceID?
    let shouldHideItemLabels: Bool?
    let contextMenu: ContextMenu?
    let thumbnail: Data?
}

private struct GroupID: Codable { let id: String }
private struct GroupSortID: Codable { let id: String }

private struct ChoiceID: Codable {
    let id: String
    let descriptor: ChoiceIDDescriptor
}

private struct ChoiceIDDescriptor: Codable {
    let provider: ChoiceProviderID
    let identifier: String
    let files: [URL]
    let configuration: Data
}

private struct SettingsItem: Codable {
    let id: ChoiceID
    let localizedName: String
    let thumbnail: Thumbnail
    let choice: ChoiceDescriptor
    let contentBadge: ContentBadge
    let showInTopLevel: Bool
    let sortOrder: Int
    let disposability: Disposability
}

private struct ChoiceDescriptor: Codable {
    let id: ChoiceID
    let provider: ChoiceProviderID
    let identifier: String
    let name: String?
    let localizedDescription: String
    let thumbnail: Thumbnail
    let isDownloaded: Bool
    let options: [WallpaperOption]
}

private struct WallpaperOption: Codable {}
private struct ContextMenu: Codable { let items: [ContextMenuItem] }
private struct ContextMenuItem: Codable { let identifier: String; let name: String }

private struct ChoiceProviderID: Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private enum Thumbnail: Codable {
    case image(url: URL)
    private enum CodingKeys: String, CodingKey { case image }
    private enum ImageKeys: String, CodingKey { case url }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
        self = .image(url: try nested.decode(URL.self, forKey: .url))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var nested = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
        if case .image(let url) = self { try nested.encode(url, forKey: .url) }
    }
}

private enum RefreshPolicy: Codable {
    case `default`
    private enum CodingKeys: String, CodingKey { case `default` }
    init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: CodingKeys.self)
        self = .default
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .default)
    }
}

private enum Disposability: Codable {
    case none, removable, purgeable
    private enum CodingKeys: String, CodingKey { case none, removable, purgeable }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.removable) { self = .removable }
        else if container.contains(.purgeable) { self = .purgeable }
        else { self = .none }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .none)
        case .removable: _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .removable)
        case .purgeable: _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .purgeable)
        }
    }
}

private enum ContentBadge: Codable {
    case none, video, dynamic
    private enum CodingKeys: String, CodingKey { case none, video, dynamic }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.video) { self = .video }
        else if container.contains(.dynamic) { self = .dynamic }
        else { self = .none }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .none)
        case .video: _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .video)
        case .dynamic: _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .dynamic)
        }
    }
}

private enum EmptyCodingKeys: CodingKey {}

@objc(LivecoreSettingsViewModelsArchive)
private final class LivecoreSettingsViewModelsArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let value: SettingsViewModels
    init(value: SettingsViewModels) { self.value = value; super.init() }
    required init?(coder _: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else { return }
        try? archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
    }
}

/// Reads the surface WallpaperAgent is asking about out of its private request
/// types. Anything missing means the request is not one Livecore can serve.
private func requestSurface(_ identifier: Any?, _ request: Any?) -> RequestSurface? {
    guard let identifier = findUUID(in: identifier),
          let size = requestValue(named: "size", in: request) as? CGSize,
          let scale = requestValue(named: "scaleFactor", in: request).flatMap(numericCGFloat),
          size.width > 0, size.height > 0, scale > 0
    else { return nil }
    let displayID = requestValue(named: "directDisplayID", in: request)
        .flatMap(numericUInt32) ?? 0
    let isPreview = requestValue(named: "isPreview", in: request)
        .flatMap(booleanValue) ?? false
    return RequestSurface(
        identifier: identifier,
        displayID: displayID,
        size: size,
        scale: scale,
        isPreview: isPreview
    )
}

private func numericCGFloat(_ value: Any) -> CGFloat? {
    if let value = value as? CGFloat { return value }
    if let value = value as? NSNumber { return CGFloat(value.doubleValue) }
    return nil
}

private func numericUInt32(_ value: Any) -> UInt32? {
    if let value = value as? UInt32 { return value }
    if let value = value as? NSNumber {
        let number = value.int64Value
        guard number >= 0, number <= Int64(UInt32.max) else { return nil }
        return UInt32(number)
    }
    return nil
}

private func booleanValue(_ value: Any) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
}

private func requestString(named name: String, in value: Any?) -> String? {
    guard let raw = requestValue(named: name, in: value) else { return nil }
    if let data = raw as? Data { return String(data: data, encoding: .utf8) }
    return raw as? String
}

private func requestValue(named name: String, in value: Any?, depth: Int = 0) -> Any? {
    guard let value, depth < 8 else { return nil }
    let mirror = Mirror(reflecting: value)
    for child in mirror.children {
        if child.label == name { return child.value }
    }
    for child in mirror.children {
        if let result = requestValue(named: name, in: child.value, depth: depth + 1) { return result }
    }
    return nil
}

/// Case name of one of WallpaperExtensionKit's private enums, which arrive as
/// opaque values because their types cannot be imported.
private func enumCaseName(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .enum, let label = mirror.children.first?.label { return label }
    let description = String(describing: value)
    return description.split(separator: ".").last.map(String.init) ?? description
}

private let uuidPattern = try! NSRegularExpression(
    pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)

/// Digs a wallpaper identifier out of WallpaperExtensionKit's private types,
/// which arrive as opaque values with no importable declaration.
private func findUUID(in value: Any?, depth: Int = 0) -> UUID? {
    guard let value, depth < 8 else { return nil }
    if let uuid = value as? UUID { return uuid }
    if let string = value as? String, let uuid = UUID(uuidString: string) { return uuid }
    let description = String(describing: value)
    if let match = uuidPattern.firstMatch(
        in: description,
        range: NSRange(description.startIndex..., in: description)
    ), let range = Range(match.range, in: description), let uuid = UUID(uuidString: String(description[range])) {
        return uuid
    }
    for child in Mirror(reflecting: value).children {
        if let uuid = findUUID(in: child.value, depth: depth + 1) { return uuid }
    }
    return nil
}
