import AppKit
import Combine
import CoreServices
import SwiftUI

@MainActor
final class LiveWallpaperApp: NSObject, NSApplicationDelegate {
    private let manager = WallpaperManager()
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let playbackItem = NSMenuItem()
    private var pauseSubscription: AnyCancellable?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
            == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupNotifications()
        manager.start()
        if !launchedAtLogin {
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        manager.refreshLaunchAtLogin()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 570),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Живые обои"
            window.contentMinSize = NSSize(width: 720, height: 500)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: SettingsView(manager: manager))
            if !window.setFrameUsingName("WallpaperSettings") {
                window.center()
            }
            window.setFrameAutosaveName("WallpaperSettings")
            settingsWindow = window
        }

        manager.refreshLaunchAtLogin()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                    accessibilityDescription: "Живые обои")
        item.button?.toolTip = "Живые обои"

        let menu = NSMenu()
        menu.addItem(settingsMenuItem())
        playbackItem.target = self
        playbackItem.action = #selector(togglePlayback)
        menu.addItem(playbackItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem())
        item.menu = menu
        statusItem = item

        pauseSubscription = manager.$isPaused.sink { [weak self] paused in
            self?.playbackItem.title = paused ? "Продолжить на всех" : "Пауза на всех"
        }

        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Живые обои")
        applicationMenu.addItem(settingsMenuItem())
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(quitMenuItem())
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
    }

    private func settingsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Настройки обоев…", action: #selector(showSettings), keyEquivalent: ",")
        item.target = self
        return item
    }

    private func quitMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Выключить живые обои",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.target = NSApp
        return item
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionDidResign),
                              name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionDidBecomeActive),
                              name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    @objc private func togglePlayback() { manager.togglePaused() }
    @objc private func screensChanged() { manager.refreshScreens() }
    @objc private func screensDidSleep() { manager.setScreensAwake(false) }
    @objc private func screensDidWake() { manager.setScreensAwake(true) }
    @objc private func sessionDidResign() { manager.setSessionActive(false) }
    @objc private func sessionDidBecomeActive() { manager.setSessionActive(true) }
}

@main
struct EntryPoint {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = LiveWallpaperApp()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
