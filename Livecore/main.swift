import Foundation
import AppKit
import AVFoundation
import CoreGraphics

enum VideoScaleType: String {
    case fill
    case fit
    case stretch
    case center

    var gravity: AVLayerVideoGravity {
        switch self {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .stretch: return .resize
        case .center: return .resizeAspect
        }
    }
}

struct Arguments {
    var videoPath: String?
    var scaleType: VideoScaleType = .fill

    static func parse() -> Arguments {
        var result = Arguments()
        let args = CommandLine.arguments
        var i = 1

        while i < args.count {
            switch args[i] {
            case "--video":
                if i + 1 < args.count {
                    result.videoPath = args[i + 1]
                    i += 1
                }
            case "--type":
                if i + 1 < args.count, let type = VideoScaleType(rawValue: args[i + 1]) {
                    result.scaleType = type
                    i += 1
                }
            default:
                break
            }
            i += 1
        }
        return result
    }
}

final class LaunchAgentManager {
    private let label = "com.livecore.wallpaper"
    private var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    func installIfNeeded(videoPath: String, scaleType: VideoScaleType) {
        let fm = FileManager.default
        let dir = plistURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: plistURL.path) { return }

        let execPath = CommandLine.arguments[0]

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                execPath,
                "--video", videoPath,
                "--type", scaleType.rawValue
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive"
        ]

        let data = try! PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        try? data.write(to: plistURL)
    }
}

final class WallpaperEngine: NSObject {
    private var players: [AVPlayer] = []
    private var windows: [NSWindow] = []

    func start(videoPath: String, scaleType: VideoScaleType) {
        guard FileManager.default.fileExists(atPath: videoPath) else { exit(1) }
        let url = URL(fileURLWithPath: videoPath)

        for screen in NSScreen.screens {
            setupScreen(screen, videoURL: url, scaleType: scaleType)
        }

        RunLoop.main.run()
    }

    private func setupScreen(_ screen: NSScreen, videoURL: URL, scaleType: VideoScaleType) {
        let frame = screen.frame

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let level = Int(CGWindowLevelForKey(.desktopWindow))
        window.level = NSWindow.Level(rawValue: level)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = true

        let asset = AVURLAsset(url: videoURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        player.isMuted = true

        let layer = AVPlayerLayer(player: player)
        layer.frame = CGRect(origin: .zero, size: frame.size)
        layer.videoGravity = scaleType.gravity

        window.contentView?.wantsLayer = true
        window.contentView?.layer?.addSublayer(layer)
        window.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            item.seek(to: .zero, completionHandler: nil)
            player.play()
        }

        player.play()
        windows.append(window)
        players.append(player)
    }
}

let args = Arguments.parse()

guard let videoPath = args.videoPath else {
    print("Usage: livecore --video <path> [--type <fill|fit|stretch|center>]")
    exit(1)
}

let agent = LaunchAgentManager()
agent.installIfNeeded(videoPath: videoPath, scaleType: args.scaleType)

let engine = WallpaperEngine()
engine.start(videoPath: videoPath, scaleType: args.scaleType)
