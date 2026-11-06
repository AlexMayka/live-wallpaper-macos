import AppKit
import AVFoundation
import ImageIO

private enum WallpaperMediaError: LocalizedError {
    case unreadable
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "Не удалось открыть файл. Проверьте, доступен ли он, и выберите его снова."
        case .unsupported:
            "Не удалось прочитать изображение или видео. Попробуйте другой файл, например PNG, JPEG, MP4 или MOV."
        }
    }
}

@MainActor
struct PreparedWallpaper {
    fileprivate enum Content {
        case video(AVURLAsset, poster: CGImage?)
        case photo(CGImage)
    }

    fileprivate let content: Content
    let thumbnail: NSImage?
    let hasAudio: Bool

    static func load(_ url: URL) async throws -> PreparedWallpaper {
        let photo = try await Task.detached(priority: .userInitiated) {
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
                throw WallpaperMediaError.unreadable
            }
            return decodePhoto(url)
        }.value
        try Task.checkCancellation()

        if let photo {
            return PreparedWallpaper(
                content: .photo(photo.fullSize),
                thumbnail: NSImage(cgImage: photo.thumbnail, size: .zero),
                hasAudio: false
            )
        }

        let asset = AVURLAsset(url: url)
        do {
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard playable, duration.isNumeric, duration.seconds > 0, !videoTracks.isEmpty else {
                throw WallpaperMediaError.unsupported
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1024, height: 1024)
            let poster = (try? await generator.image(at: .zero))?.image
            try Task.checkCancellation()
            return PreparedWallpaper(
                content: .video(asset, poster: poster),
                thumbnail: poster.map { NSImage(cgImage: $0, size: .zero) },
                hasAudio: !audioTracks.isEmpty
            )
        } catch {
            try Task.checkCancellation()
            throw WallpaperMediaError.unsupported
        }
    }

    private nonisolated static func decodePhoto(_ url: URL) -> (fullSize: CGImage, thumbnail: CGImage)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 5120
        ]
        guard let fullSize = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        var thumbnailOptions = options
        thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = 1024
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        return (fullSize, thumbnail ?? fullSize)
    }
}

@MainActor
final class DisplayWallpaper {
    private let window: NSWindow
    private let canvas = CALayer()
    private let poster = CALayer()
    private let player: AVQueuePlayer?
    private let loop: AVPlayerLooper?
    private let videoLayer: AVPlayerLayer?
    init(screen: NSScreen, media: PreparedWallpaper) {
        switch media.content {
        case .video(let asset, let image):
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            player = queue
            loop = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: asset))
            videoLayer = AVPlayerLayer(player: queue)
            poster.contents = image
        case .photo(let image):
            player = nil
            loop = nil
            videoLayer = nil
            poster.contents = image
        }

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.backgroundColor = NSColor.black.cgColor
        canvas.masksToBounds = true
        canvas.addSublayer(poster)
        if let videoLayer {
            canvas.addSublayer(videoLayer)
        }
        view.layer = canvas
        view.wantsLayer = true

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        setAppearance(.fill)
        updateScreen(screen)
        window.orderFrontRegardless()
    }

    func updateScreen(_ screen: NSScreen) {
        window.setFrame(screen.frame, display: false)
        window.title = "Живые обои — \(screen.localizedName)"

        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds
        poster.frame = bounds
        videoLayer?.frame = bounds
        CATransaction.commit()
    }

    func setAppearance(_ fit: WallpaperFit) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        poster.contentsGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
        videoLayer?.videoGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
        CATransaction.commit()
    }

    func setAudio(enabled: Bool, volume: Double) {
        let level = volume.isFinite ? min(max(volume, 0), 1) : 0
        player?.volume = Float(level)
        player?.isMuted = !enabled
    }

    func setPlaying(_ playing: Bool) {
        if playing {
            player?.play()
        } else {
            player?.pause()
        }
    }

    func close() {
        player?.pause()
        loop?.disableLooping()
        player?.removeAllItems()
        videoLayer?.player = nil
        window.close()
    }
}
