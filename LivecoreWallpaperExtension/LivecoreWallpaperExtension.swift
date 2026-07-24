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
            forName: NSNotification.Name("com.livecore.app.assets-changed"),
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.pushSettings() }
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
              let item = SharedWallpaperLibrary.item(id)
        else {
            reply(nil, LivecoreExtensionError.missingItem)
            return
        }
        let destination = requestDestination(request)
        let key = SurfaceKey(
            identifier: wallpaperIdentifier(identifier),
            displayID: destination.displayID
        )
        let isPreview = requestValue(named: "isPreview", in: request) as? Bool ?? false
        let mode = requestValue(named: "presentationMode", in: request).map(enumCaseName) ?? "default"
        renderer.acquire(
            key: key,
            item: item,
            size: destination.size,
            scale: destination.scale,
            displayID: destination.displayID,
            isPreview: isPreview,
            initialMode: mode,
            reply: reply
        )
    }

    func update(
        withId identifier: Any?,
        request: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        let destination = requestDestination(request)
        let key = SurfaceKey(
            identifier: wallpaperIdentifier(identifier),
            displayID: destination.displayID
        )
        let mode = requestValue(named: "presentationMode", in: request).map(enumCaseName) ?? "default"
        let activity = requestValue(named: "activityState", in: request).map(enumCaseName) ?? "active"
        renderer.update(key: key, presentationMode: mode, activityState: activity)
        reply(nil)
    }

    func invalidate(
        withId identifier: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        renderer.invalidate(identifier: wallpaperIdentifier(identifier))
        reply(nil)
    }

    func snapshot(
        withId identifier: Any?,
        reply: @escaping @Sendable (Any?, (any Error)?) -> Void
    ) {
        let configuration = requestString(named: "configuration", in: identifier)
        let item = configuration.flatMap(UUID.init(uuidString:)).flatMap(SharedWallpaperLibrary.item)
            ?? SharedWallpaperLibrary.current()
        guard let item, let image = SharedWallpaperLibrary.thumbnail(item),
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
    ) {
        let models = SettingsModelBridge.make()
        if models != nil, let item = SharedWallpaperLibrary.current() {
            SharedWallpaperLibrary.markSettingsReady(item.id)
        }
        reply(models, nil)
    }

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
    case missingItem = 1
    case rendererUnavailable = 2
    case snapshotUnavailable = 3
}

private struct SurfaceKey: Hashable {
    let identifier: String
    let displayID: UInt32
}

private struct RequestDestination {
    let size: CGSize
    let scale: CGFloat
    let displayID: UInt32
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
    private var invalidationTokens: [SurfaceKey: UUID] = [:]
    private let queue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "com.livecore.app").extension-lifecycle", qos: .default)

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            ScreenLockState.set(true)
            self?.updateAll(presentationMode: "locked", activityState: "active")
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            ScreenLockState.set(false)
            self?.updateAll(presentationMode: "default", activityState: "active")
        }
    }

    func acquire(
        key: SurfaceKey,
        item: SharedWallpaperItem,
        size: CGSize,
        scale: CGFloat,
        displayID: UInt32,
        isPreview: Bool,
        initialMode: String,
        reply: @escaping @Sendable (Any?, (any Error)?) -> Void
    ) {
        queue.async {
            self.invalidationTokens.removeValue(forKey: key)
            if let session = self.sessions[key],
               session.item.id == item.id,
               session.isPreview == isPreview,
               session.matches(size: size, scale: scale) {
                session.update(presentationMode: initialMode, activityState: "active")
                SharedWallpaperLibrary.markRendererReady(item.id)
                reply(session.context, nil)
                return
            }
            guard let session = RenderSession(
                item: item,
                size: size,
                scale: scale,
                displayID: displayID,
                isPreview: isPreview
            ) else {
                reply(nil, LivecoreExtensionError.rendererUnavailable)
                return
            }
            let old = self.sessions.updateValue(session, forKey: key)
            old?.invalidate()
            session.update(presentationMode: initialMode, activityState: "active")
            SharedWallpaperLibrary.markRendererReady(item.id)
            reply(session.context, nil)
        }
    }

    func update(key: SurfaceKey, presentationMode: String, activityState: String) {
        queue.async {
            if let session = self.sessions[key] {
                session.update(presentationMode: presentationMode, activityState: activityState)
            } else {
                self.sessions.values
                    .filter { $0.displayID == key.displayID && !$0.isPreview }
                    .forEach { $0.update(presentationMode: presentationMode, activityState: activityState) }
            }
        }
    }

    func updateAll(presentationMode: String, activityState: String) {
        queue.async {
            self.sessions.values.filter { !$0.isPreview }.forEach {
                $0.update(presentationMode: presentationMode, activityState: activityState)
            }
        }
    }

    func invalidate(identifier: String) {
        queue.async {
            let keys = self.sessions.keys.filter { $0.identifier == identifier }
            for key in keys {
                let token = UUID()
                self.invalidationTokens[key] = token
                self.queue.asyncAfter(deadline: .now() + 1) {
                    guard self.invalidationTokens[key] == token else { return }
                    self.invalidationTokens.removeValue(forKey: key)
                    self.sessions.removeValue(forKey: key)?.invalidate()
                }
            }
        }
    }
}

private final class RenderSession {
    let item: SharedWallpaperItem
    let context: AnyObject
    let displayID: UInt32
    let isPreview: Bool
    let renderSize: CGSize
    let renderScale: CGFloat

    private let pump: SampleBufferPump
    private var invalidated = false

    init?(
        item: SharedWallpaperItem,
        size: CGSize,
        scale: CGFloat,
        displayID: UInt32,
        isPreview: Bool
    ) {
        guard let videoURL = SharedWallpaperLibrary.videoURL(item),
              let fallback = isPreview
                ? SharedWallpaperLibrary.thumbnail(item)
                : SharedWallpaperLibrary.desktopImage(item, displayID: displayID)
        else { return nil }

        let renderSize = size.width > 0 && size.height > 0
            ? size
            : CGSize(width: 2560, height: 1440)
        let renderScale = scale > 0 ? scale : 2
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        root.contentsScale = renderScale
        root.backgroundColor = NSColor.clear.cgColor
        guard let pump = SampleBufferPump(rootLayer: root, videoURL: videoURL, stillImage: fallback),
              let context = LCCreateRemoteContext(root, displayID) as AnyObject?
        else { return nil }

        self.item = item
        self.context = context
        self.displayID = displayID
        self.isPreview = isPreview
        self.renderSize = renderSize
        self.renderScale = renderScale
        self.pump = pump
    }

    func matches(size: CGSize, scale: CGFloat) -> Bool {
        let candidateSize = size.width > 0 && size.height > 0
            ? size
            : CGSize(width: 2560, height: 1440)
        let candidateScale = scale > 0 ? scale : 2
        return abs(renderSize.width - candidateSize.width) < 0.5
            && abs(renderSize.height - candidateSize.height) < 0.5
            && abs(renderScale - candidateScale) < 0.01
    }

    func update(presentationMode: String, activityState: String) {
        guard !invalidated else { return }
        if presentationMode == "locked" { ScreenLockState.set(true) }
        // While the screen is locked, keep playing even if WallpaperAgent
        // reports an idle activity state or reverts the presentation mode;
        // otherwise the wallpaper degrades to a still after a few minutes.
        let shouldPlay = SharedWallpaperLibrary.playbackEnabled()
            && (isPreview
                ? activityState == "active"
                : presentationMode == "locked" || ScreenLockState.isLocked)
        if shouldPlay { pump.play() } else { pump.showStill() }
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        pump.stop()
        LCReleaseRemoteContext(context)
    }

    deinit { invalidate() }
}

private final class SampleBufferPump: @unchecked Sendable {
    private let displayLayer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private let asset: AVURLAsset
    private let stillBuffer: CMSampleBuffer
    private let decodeQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "com.livecore.app").video-decoder", qos: .default)
    private let stateLock = NSLock()
    private let renderLock = NSLock()
    private var token: UUID?
    private var reader: AVAssetReader?
    private var playbackRequested = false
    private var retryAttempt = 0
    private var playbackGeneration: UInt64 = 0

    init?(rootLayer: CALayer, videoURL: URL, stillImage: CGImage) {
        let asset = AVURLAsset(url: videoURL)
        guard let stillBuffer = makeStillSampleBuffer(from: stillImage) else { return nil }

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

        self.displayLayer = layer
        self.renderer = layer.sampleBufferRenderer
        self.timebase = timebase
        self.asset = asset
        self.stillBuffer = stillBuffer

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(layer)
        CATransaction.commit()
        showStill()
    }

    func play() {
        stateLock.lock()
        if !playbackRequested { playbackGeneration &+= 1 }
        playbackRequested = true
        if token != nil {
            stateLock.unlock()
            return
        }
        let newToken = UUID()
        let generation = playbackGeneration
        token = newToken
        stateLock.unlock()

        startAttempt(newToken, generation: generation)
    }

    private func startAttempt(_ attemptToken: UUID, generation: UInt64) {
        renderLock.lock()
        guard isCurrent(attemptToken, generation: generation) else {
            renderLock.unlock()
            return
        }
        renderer.flush()
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 1)
        renderLock.unlock()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let track = try? await self.asset.loadTracks(withMediaType: .video).first,
                  self.isCurrent(attemptToken, generation: generation) else {
                self.finishAttempt(attemptToken, generation: generation, retry: true)
                return
            }
            let trackDuration = (try? await track.load(.timeRange))?.duration ?? .invalid
            self.decodeQueue.async { [weak self] in
                self?.decodeLoop(
                    track: track,
                    trackDuration: trackDuration,
                    token: attemptToken,
                    generation: generation
                )
            }
        }
    }

    func showStill() {
        cancelDecode()
        renderLock.lock()
        CMTimebaseSetRate(timebase, rate: 0)
        renderer.flush()
        markDisplayImmediately(stillBuffer)
        renderer.enqueue(stillBuffer)
        CATransaction.flush()
        renderLock.unlock()
    }

    func stop() {
        cancelDecode()
        renderLock.lock()
        CMTimebaseSetRate(timebase, rate: 0)
        renderer.flush(removingDisplayedImage: true)
        displayLayer.removeFromSuperlayer()
        renderLock.unlock()
    }

    private func cancelDecode() {
        stateLock.lock()
        playbackGeneration &+= 1
        playbackRequested = false
        retryAttempt = 0
        token = nil
        let activeReader = reader
        reader = nil
        stateLock.unlock()
        activeReader?.cancelReading()
    }

    private func isCurrent(_ candidate: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return token == candidate
    }

    private func isCurrent(_ candidate: UUID, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return token == candidate && playbackGeneration == generation && playbackRequested
    }

    private func notePlaybackProgress(_ candidate: UUID) {
        stateLock.lock()
        if token == candidate { retryAttempt = 0 }
        stateLock.unlock()
    }

    private func finishAttempt(_ candidate: UUID, generation: UInt64, retry: Bool) {
        stateLock.lock()
        guard token == candidate, playbackGeneration == generation else {
            stateLock.unlock()
            return
        }
        token = nil
        reader = nil
        let shouldRetry = retry && playbackRequested
        let delay = min(0.25 * pow(2, Double(retryAttempt)), 4)
        if shouldRetry { retryAttempt = min(retryAttempt + 1, 5) }
        stateLock.unlock()

        guard shouldRetry else { return }
        decodeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard self.playbackRequested,
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
    }

    private func decodeLoop(
        track: AVAssetTrack,
        trackDuration: CMTime,
        token: UUID,
        generation: UInt64
    ) {
        defer { finishAttempt(token, generation: generation, retry: true) }
        var loopOffset = CMTime.zero
        while isCurrent(token) {
            guard let reader = try? AVAssetReader(asset: asset) else { break }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { break }
            reader.add(output)
            guard reader.startReading() else { break }
            stateLock.lock()
            self.reader = reader
            stateLock.unlock()

            var firstPTS: CMTime?
            var lastEnd = loopOffset
            while isCurrent(token), reader.status == .reading {
                // The system renderer can silently enter a failed state (for
                // example across display power transitions); enqueue then
                // becomes a no-op and the wallpaper freezes. A failed status
                // aborts the attempt so the retry path restarts playback.
                // requiresFlushToResumeDecoding also fires on benign decoder
                // discontinuities (such as the loop boundary); recover with an
                // in-place flush instead of aborting, otherwise the loop never
                // restarts and the wallpaper stays frozen on the last frame.
                if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                    renderLock.lock()
                    renderer.flush()
                    renderLock.unlock()
                    if renderer.status == .failed {
                        reader.cancelReading()
                        return
                    }
                    continue
                }
                guard renderer.isReadyForMoreMediaData else {
                    Thread.sleep(forTimeInterval: 0.004)
                    continue
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    Thread.sleep(forTimeInterval: 0.002)
                    continue
                }
                notePlaybackProgress(token)
                let samplePTS = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstPTS == nil, samplePTS.isNumeric {
                    // Base the loop shift on the earliest timestamp of the
                    // pass. The first decode timestamp is usually earlier than
                    // the presentation timestamp; shifting by PTS alone sends
                    // the decode timeline backwards at the loop boundary,
                    // which trips the decoder's discontinuity handling.
                    let sampleDTS = CMSampleBufferGetDecodeTimeStamp(sample)
                    firstPTS = sampleDTS.isNumeric
                        ? CMTimeMinimum(samplePTS, sampleDTS)
                        : samplePTS
                }
                let shift = CMTimeSubtract(loopOffset, firstPTS ?? .zero)
                let adjusted = retime(sample, by: shift) ?? sample
                let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
                let duration = CMSampleBufferGetDuration(adjusted).isNumeric
                    ? CMSampleBufferGetDuration(adjusted)
                    : CMTime(value: 1, timescale: 30)
                // A sample with a non-numeric timestamp (the trailing sample of
                // a pass can carry one) must neither advance lastEnd nor reach
                // the renderer: CMTimeMaximum propagates invalid times, and one
                // poisoned loopOffset turns every following pass into a no-op,
                // freezing the wallpaper on the last decoded frame.
                guard pts.isNumeric else { continue }
                let end = CMTimeAdd(pts, duration)
                if end.isNumeric { lastEnd = CMTimeMaximum(lastEnd, end) }

                renderLock.lock()
                if isCurrent(token) { renderer.enqueue(adjusted) }
                renderLock.unlock()
            }
            reader.cancelReading()
            if !isCurrent(token) { break }
            if lastEnd.isNumeric, CMTimeCompare(lastEnd, loopOffset) > 0 {
                loopOffset = lastEnd
            } else if trackDuration.isNumeric, CMTimeCompare(trackDuration, .zero) > 0 {
                loopOffset = CMTimeAdd(loopOffset, trackDuration)
            } else {
                // No trustworthy way to advance the timeline; restart playback
                // from scratch via the retry path instead of spinning.
                break
            }
            if reader.status == .failed || reader.status == .cancelled { break }
        }
    }

    deinit { stop() }
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

private struct SharedWallpaperItem: Codable {
    let id: UUID
    let fileName: String
    let title: String
    let createdAt: Date
    let desktopImageFileNames: [String: String]?
}

private struct SharedPlaybackState: Codable {
    let enabled: Bool
    let updatedAt: Date
}

private struct SharedRendererReadyState: Codable {
    let itemID: UUID
    let updatedAt: Date
    let runtimeBuild: String
}

private struct SharedSettingsReadyState: Codable {
    let itemID: UUID
    let updatedAt: Date
    let runtimeBuild: String
}

private enum SharedWallpaperLibrary {
    private static var runtimeBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version):\(LCLoadedCodeBuildIdentifier())"
    }

    static var root: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WallpaperLibrary", isDirectory: true)
    }

    static func current() -> SharedWallpaperItem? {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("current.json"))
        else { return nil }
        return try? JSONDecoder().decode(SharedWallpaperItem.self, from: data)
    }

    static func item(_ id: UUID) -> SharedWallpaperItem? {
        guard let root else { return nil }
        if let data = try? Data(contentsOf: root.appendingPathComponent("\(id.uuidString).json")),
           let item = try? JSONDecoder().decode(SharedWallpaperItem.self, from: data) {
            return item
        }
        let current = current()
        return current?.id == id ? current : nil
    }

    static func playbackEnabled() -> Bool {
        guard let root,
              let data = try? Data(contentsOf: root.appendingPathComponent("playback-state.json")),
              let state = try? JSONDecoder().decode(SharedPlaybackState.self, from: data)
        else { return false }
        return state.enabled
    }

    static func videoURL(_ item: SharedWallpaperItem) -> URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(item.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func thumbnailURL(_ item: SharedWallpaperItem) -> URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent("\(item.id.uuidString).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func thumbnail(_ item: SharedWallpaperItem) -> CGImage? {
        thumbnailURL(item).flatMap(image)
    }

    static func desktopImage(_ item: SharedWallpaperItem, displayID: UInt32) -> CGImage? {
        guard let root, let files = item.desktopImageFileNames else { return nil }
        let name = files[String(displayID)] ?? files["default"]
        return name.flatMap { image(root.appendingPathComponent($0)) }
    }

    static func markRendererReady(_ id: UUID) {
        guard let root else { return }
        let state = SharedRendererReadyState(
            itemID: id,
            updatedAt: Date(),
            runtimeBuild: runtimeBuild
        )
        try? JSONEncoder().encode(state).write(
            to: root.appendingPathComponent("renderer-ready.json"),
            options: .atomic
        )
    }

    static func markSettingsReady(_ id: UUID) {
        guard let root else { return }
        let state = SharedSettingsReadyState(
            itemID: id,
            updatedAt: Date(),
            runtimeBuild: runtimeBuild
        )
        try? JSONEncoder().encode(state).write(
            to: root.appendingPathComponent("settings-ready.json"),
            options: .atomic
        )
    }

    private static func image(_ url: URL) -> CGImage? {
        NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

private enum SettingsModelBridge {
    static func make() -> AnyObject? {
        guard let item = SharedWallpaperLibrary.current(),
              let videoURL = SharedWallpaperLibrary.videoURL(item),
              let thumbnailURL = SharedWallpaperLibrary.thumbnailURL(item)
        else { return remap(SettingsViewModels(desktop: emptyModel, screenSaver: nil)) }

        let provider = ChoiceProviderID(rawValue: Bundle.main.bundleIdentifier ?? "")
        let descriptor = ChoiceIDDescriptor(
            provider: provider,
            identifier: item.id.uuidString,
            files: [videoURL],
            configuration: Data(item.id.uuidString.utf8)
        )
        let choiceID = ChoiceID(id: item.id.uuidString, descriptor: descriptor)
        let thumbnail = Thumbnail.image(url: thumbnailURL)
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
        } catch { return nil }
        guard let runtime = NSClassFromString("WallpaperSettingsViewModelsXPC"),
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive)
        else { return nil }
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

private func requestDestination(_ request: Any?) -> RequestDestination {
    let size = requestValue(named: "size", in: request) as? CGSize
        ?? CGSize(width: 2560, height: 1440)
    let scale = requestValue(named: "scaleFactor", in: request) as? CGFloat ?? 2
    let displayID = requestValue(named: "directDisplayID", in: request) as? UInt32 ?? 0
    return RequestDestination(size: size, scale: scale, displayID: displayID)
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

private func enumCaseName(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .enum, let label = mirror.children.first?.label { return label }
    let description = String(describing: value)
    return description.split(separator: ".").last.map(String.init) ?? description
}

private func wallpaperIdentifier(_ value: Any?) -> String {
    if let uuid = findUUID(in: value) { return uuid.uuidString }
    return String(describing: value ?? "unknown")
}

private func findUUID(in value: Any?, depth: Int = 0) -> UUID? {
    guard let value, depth < 8 else { return nil }
    if let uuid = value as? UUID { return uuid }
    if let string = value as? String, let uuid = UUID(uuidString: string) { return uuid }
    let description = String(describing: value)
    let expression = try? NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    )
    if let match = expression?.firstMatch(
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
