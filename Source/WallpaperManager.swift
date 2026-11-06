import AppKit
import ColorSync
import Combine
import ServiceManagement
import UniformTypeIdentifiers

struct ScreenRow: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let isBuiltIn: Bool
}

enum WallpaperFit: String, Codable, CaseIterable {
    case fill, fit
}

struct WallpaperState {
    var title = "Обои macOS"
    var subtitle = "Выберите видео или изображение."
    var thumbnail: NSImage?
    var hasAudio = false
    var soundEnabled = false
    var volume = 0.3
    var isUsingDefault = true
    var hasWallpaper = false
    var resetTitle = "Вернуть обои macOS"
    var isEnabled = true
    var isLoading = false
    var error: String?
    var fit: WallpaperFit = .fill
}

private struct WallpaperFile: Codable, Equatable {
    let url: URL
    let bookmark: Data?

    init(url: URL) {
        self.url = url
        bookmark = try? url.bookmarkData(options: [.minimalBookmark])
    }

    var resolvedURL: URL {
        guard let bookmark else { return url }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                         bookmarkDataIsStale: &stale)) ?? url
    }
}

private struct ScreenSettings: Codable {
    var file: WallpaperFile?
    var soundEnabled = false
    var volume = 0.3
    var isEnabled = true
    var fit: WallpaperFit = .fill
}

@MainActor
final class WallpaperManager: ObservableObject {
    @Published private(set) var screens: [ScreenRow] = []
    @Published var selectedID: String? {
        didSet { publishSelection() }
    }
    @Published private(set) var state = WallpaperState()
    @Published private(set) var isPaused = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchError: String?

    private struct LoadedWallpaper {
        let id = UUID()
        let media: PreparedWallpaper
        let file: WallpaperFile?
        let title: String
    }

    private struct Renderer {
        let wallpaper: DisplayWallpaper
        let sourceID: UUID
    }

    private static let settingsKey = "DisplayWallpaperSettings.v2"
    private let defaults: UserDefaults
    private var settings: [String: ScreenSettings]
    private var attached: [String: NSScreen] = [:]
    private var renderers: [String: Renderer] = [:]
    private var loaded: [String: LoadedWallpaper] = [:]
    private var bundled: LoadedWallpaper?
    private var bundledLoading = false
    private var loading: [String: Task<Void, Never>] = [:]
    private var errors: [String: String] = [:]
    private var bundledError: String?
    private var screensAwake = true
    private var sessionActive = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode([String: ScreenSettings].self, from: $0) } ?? [:]
    }

    func start() {
        let bundledURL = Bundle.main.url(forResource: "DefaultWallpaper", withExtension: "mp4")
            ?? Bundle.main.url(forResource: "DefaultWallpaper", withExtension: "mov")
            ?? Bundle.main.url(forResource: "Домик", withExtension: "mp4")
        bundledLoading = bundledURL != nil
        refreshLaunchAtLogin()
        refreshScreens()
        if let bundledURL {
            Task { [weak self] in await self?.prepareBundledWallpaper(bundledURL) }
        }
    }

    func refreshScreens() {
        var current: [String: NSScreen] = [:]
        var rows: [ScreenRow] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = number.uint32Value
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
            let baseID = uuid.map { CFUUIDCreateString(kCFAllocatorDefault, $0) as String } ?? "display-\(displayID)"
            let id = current[baseID] == nil ? baseID : "\(baseID)-\(displayID)"
            current[id] = screen
            let builtIn = CGDisplayIsBuiltin(displayID) != 0
            let size = "\(CGDisplayPixelsWide(displayID)) × \(CGDisplayPixelsHigh(displayID))"
            rows.append(ScreenRow(id: id, name: builtIn ? "Встроенный дисплей" : screen.localizedName,
                                  detail: size, isBuiltIn: builtIn))
        }

        for id in attached.keys where current[id] == nil {
            renderers.removeValue(forKey: id)?.wallpaper.close()
            loaded.removeValue(forKey: id)
        }
        attached = current
        screens = rows
        for row in rows {
            if let screen = current[row.id] {
                renderers[row.id]?.wallpaper.updateScreen(screen)
            }
            if let file = settings[row.id]?.file, loaded[row.id] == nil, loading[row.id] == nil {
                load(file, on: row.id, replacing: false)
            }
            refreshRenderer(row.id)
        }
        if selectedID.flatMap({ current[$0] }) == nil {
            selectedID = rows.first?.id
        }
        publishSelection()
    }

    func chooseFile() {
        guard let id = selectedID else { return }
        let panel = NSOpenPanel()
        panel.title = "Выбрать обои"
        panel.message = "Выберите видео или изображение для выбранного дисплея."
        panel.prompt = "Выбрать"
        panel.allowedContentTypes = [.movie, .image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] result in
            guard result == .OK, let url = panel?.url else { return }
            self?.load(WallpaperFile(url: url), on: id, replacing: true)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func useDefault() {
        guard let id = selectedID else { return }
        loading.removeValue(forKey: id)?.cancel()
        errors.removeValue(forKey: id)
        loaded.removeValue(forKey: id)
        update(id) { $0.file = nil }
    }

    func applyToAllDisplays() {
        guard let selectedID, loading[selectedID] == nil,
              let source = effectiveWallpaper(selectedID),
              source.file == settings[selectedID]?.file else { return }
        for id in attached.keys where id != selectedID {
            loading.removeValue(forKey: id)?.cancel()
            errors.removeValue(forKey: id)
            loaded[id] = source.file == nil ? nil : source
            settings[id, default: ScreenSettings()].file = source.file
            refreshRenderer(id)
        }
        persist()
        publishSelection()
    }

    func setSoundEnabled(_ value: Bool) {
        guard let id = selectedID else { return }
        update(id) { $0.soundEnabled = value }
    }

    func setVolume(_ value: Double) {
        guard let id = selectedID, value.isFinite else { return }
        update(id) { $0.volume = min(1, max(0, value)) }
    }

    func setFit(_ fit: WallpaperFit) {
        guard let id = selectedID else { return }
        update(id) { $0.fit = fit }
    }

    func setEnabled(_ value: Bool) {
        guard let id = selectedID else { return }
        update(id) { $0.isEnabled = value }
    }

    func togglePaused() {
        isPaused.toggle()
        updatePlayback()
    }

    func setScreensAwake(_ awake: Bool) {
        screensAwake = awake
        updatePlayback()
    }

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        updatePlayback()
    }

    func setLaunchAtLogin(_ value: Bool) {
        let service = SMAppService.mainApp
        var failed = false
        do {
            if value {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            failed = true
        }
        refreshLaunchAtLogin()
        if failed, launchError == nil, launchAtLogin != value {
            launchError = "macOS не удалось изменить автозапуск. Проверьте «Объекты входа» в системных настройках."
        }
    }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        launchError = status == .requiresApproval
            ? "Разрешите автозапуск в системных настройках macOS, в разделе «Объекты входа»."
            : nil
    }

    private func prepareBundledWallpaper(_ url: URL) async {
        do {
            let media = try await PreparedWallpaper.load(url)
            let title = url.deletingPathExtension().lastPathComponent == "Домик" ? "Домик" : "Встроенное видео"
            bundled = LoadedWallpaper(media: media, file: nil, title: title)
            for id in attached.keys { refreshRenderer(id) }
        } catch {
            bundledError = "Не удалось открыть встроенное видео. Выберите свой файл."
        }
        bundledLoading = false
        publishSelection()
    }

    private func load(_ file: WallpaperFile, on id: String, replacing: Bool) {
        loading[id]?.cancel()
        errors.removeValue(forKey: id)
        loading[id] = Task { [weak self] in
            guard let self else { return }
            let url = file.resolvedURL
            do {
                let media = try await PreparedWallpaper.load(url)
                guard !Task.isCancelled else { return }
                loading.removeValue(forKey: id)
                let savedFile = url == file.url ? file : WallpaperFile(url: url)
                if attached[id] != nil {
                    loaded[id] = LoadedWallpaper(media: media, file: savedFile, title: url.lastPathComponent)
                }
                update(id) { $0.file = savedFile }
            } catch {
                guard !Task.isCancelled else { return }
                loading.removeValue(forKey: id)
                if replacing {
                    errors[id] = error.localizedDescription
                } else {
                    errors[id] = "Не удалось открыть «\(file.url.lastPathComponent)». Выберите файл заново."
                }
                publishSelection()
            }
        }
        publishSelection()
    }

    private func update(_ id: String, _ change: (inout ScreenSettings) -> Void) {
        change(&settings[id, default: ScreenSettings()])
        persist()
        refreshRenderer(id)
        publishSelection()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    private func effectiveWallpaper(_ id: String) -> LoadedWallpaper? {
        loaded[id] ?? bundled
    }

    private func refreshRenderer(_ id: String) {
        let config = settings[id] ?? ScreenSettings()
        guard config.isEnabled, let screen = attached[id], let source = effectiveWallpaper(id) else {
            renderers.removeValue(forKey: id)?.wallpaper.close()
            return
        }
        let wallpaper: DisplayWallpaper
        if let renderer = renderers[id], renderer.sourceID == source.id {
            wallpaper = renderer.wallpaper
        } else {
            renderers.removeValue(forKey: id)?.wallpaper.close()
            wallpaper = DisplayWallpaper(screen: screen, media: source.media)
            renderers[id] = Renderer(wallpaper: wallpaper, sourceID: source.id)
        }
        wallpaper.setAppearance(config.fit)
        // A missing custom file may fall back to the bundled video. Keep that fallback silent.
        wallpaper.setAudio(enabled: config.soundEnabled && config.file == source.file, volume: config.volume)
        wallpaper.setPlaying(shouldPlay)
    }

    private var shouldPlay: Bool { !isPaused && screensAwake && sessionActive }

    private func updatePlayback() {
        for renderer in renderers.values {
            renderer.wallpaper.setPlaying(shouldPlay)
        }
    }

    private func publishSelection() {
        guard let id = selectedID else {
            state = WallpaperState()
            return
        }
        let config = settings[id] ?? ScreenSettings()
        let source = effectiveWallpaper(id)
        let unavailable = config.file != nil && loaded[id] == nil
        let subtitle: String
        if unavailable {
            subtitle = loading[id] == nil ? "Выбранный файл недоступен." : "Открываем выбранный файл…"
        } else if let source {
            subtitle = source.file == nil ? "Обои по умолчанию" : "Ваш файл"
        } else {
            subtitle = "Выберите видео или изображение."
        }
        state = WallpaperState(
            title: source?.title ?? "Обои macOS",
            subtitle: subtitle,
            thumbnail: source?.media.thumbnail,
            hasAudio: (source?.media.hasAudio ?? false) && !unavailable,
            soundEnabled: config.soundEnabled,
            volume: config.volume,
            isUsingDefault: config.file == nil,
            hasWallpaper: source != nil,
            resetTitle: bundled == nil ? "Вернуть обои macOS" : "Вернуть встроенные обои",
            isEnabled: config.isEnabled,
            isLoading: loading[id] != nil || (source == nil && bundledLoading),
            error: errors[id] ?? (source == nil ? bundledError : nil),
            fit: config.fit
        )
    }
}
