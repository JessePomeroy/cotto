import AppKit
import Combine
import Darwin
import SottoCore
import ServiceManagement
import SwiftUI

@main
@MainActor
enum SottoApp {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        // Development uses a separate identity and privacy grants.
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.davis.sotto.dev")
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing {
            existing.activate(options: [.activateAllWindows])
            return
        }
        app.setActivationPolicy(.accessory)
        let delegate = SottoAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class SottoAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controller: SottoController!
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var popover: NSPopover!
    private var menuContent: NSHostingController<SottoMenuView>!
    private var hud: DictationPanel!
    private var activitySubscription: AnyCancellable?
    private var configuration: ConfigurationStore?
    private var startupTask: Task<Void, Never>?
    private var reopenRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = ProcessInfo.processInfo.environment["SOTTO_CLIENT_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Sotto Dev", isDirectory: true)
        let configuration = ConfigurationStore(
            file: ConfigurationFile(url: root.appendingPathComponent("config.json"))
        )
        self.configuration = configuration
        startupTask = Task {
            // Load the file before installing a hotkey or using any preference.
            await configuration.start()
            guard !Task.isCancelled else { return }
            finishLaunching(configuration: configuration)
            startupTask = nil
        }
    }

    private func finishLaunching(configuration: ConfigurationStore) {
        controller = SottoController(configuration: configuration)
        hud = DictationPanel(controller: controller)
        controller.onShowWindow = { [weak self] in self?.showWindow() }
        controller.onHUDVisibility = { [weak self] visible in
            if visible { self?.hud.present() }
            else { self?.hud.orderOut(nil) }
        }
        configureApplicationMenu()
        configureStatusItem()
        let defaults = UserDefaults.standard
        if reopenRequested || configuration.errorMessage != nil || !defaults.bool(forKey: "hasLaunched") || !controller.allPermissionsGranted {
            showWindow()
        }
        defaults.set(true, forKey: "hasLaunched")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        configuration?.stopWatching()
        controller?.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        configuration?.stopWatching()
        controller?.shutdown()
        guard startupTask != nil || (configuration?.pendingWriteCount ?? 0) > 0 else { return .terminateNow }
        startupTask?.cancel()
        Task {
            await startupTask?.value
            configuration?.stopWatching()
            await configuration?.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === mainWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func showWindow() {
        guard controller != nil else { reopenRequested = true; return }
        popover?.performClose(nil)
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.title = "Sotto Dev"
            // Let native chrome obscure scrolling form content under the title.
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .automatic
            window.backgroundColor = NSColor(SottoPalette.canvas)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 820, height: 620)
            window.contentViewController = NSHostingController(rootView: SottoWindowView(controller: controller))
            window.delegate = self
            if !window.setFrameUsingName("SottoDevMainWindow") { window.center() }
            window.setFrameAutosaveName("SottoDevMainWindow")
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        controller.refreshPermissions()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            controller.refreshPermissions()
            // Settle SwiftUI's height before AppKit chooses the on-screen frame.
            // Late hosting-view resizing can otherwise grow the popover upwards.
            let fitted = menuContent.sizeThatFits(in: NSSize(
                width: SottoMenuView.width, height: .greatestFiniteMagnitude
            ))
            let size = NSSize(width: ceil(fitted.width), height: ceil(fitted.height))
            menuContent.preferredContentSize = size
            menuContent.view.setFrameSize(size)
            popover.contentSize = size
            menuContent.view.layoutSubtreeIfNeeded()
            let bottomEdge: NSRectEdge = button.isFlipped ? .maxY : .minY
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: bottomEdge)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func configureStatusItem() {
        // Keep the slot present while swapping artwork; a status transition
        // must never depend on the new image's intrinsic width.
        statusItem = NSStatusBar.system.statusItem(withLength: 62)
        if let button = statusItem.button {
            SottoBrand.updateStatusButton(button, activity: controller.activity, shortcut: controller.shortcut)
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover = NSPopover()
        popover.behavior = .transient
        menuContent = NSHostingController(rootView: SottoMenuView(
            controller: controller, openWindow: { [weak self] in self?.showWindow() },
            quit: { NSApp.terminate(nil) }
        ))
        // This compact menu has bounded status/preview slots. Keep its frame
        // stable while open, and remeasure current content on the next opening.
        menuContent.sizingOptions = []
        popover.contentViewController = menuContent
        activitySubscription = controller.$activity.combineLatest(controller.$shortcut)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] activity, shortcut in
            guard let button = self?.statusItem.button else { return }
            SottoBrand.updateStatusButton(button, activity: activity, shortcut: shortcut)
        }
    }

    private func configureApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let show = NSMenuItem(title: "Open Sotto Dev", action: #selector(showWindow), keyEquivalent: ",")
        show.target = self
        appMenu.addItem(show)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Sotto Dev", action: #selector(self.quit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
        ] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

private final class DictationPanel: NSPanel {
    init(controller: SottoController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: DictationHUD.width + 36, height: DictationHUD.height + DictationHUD.noticeHeight + 36),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        // Join other apps' Stage Manager sets and full-screen spaces without
        // activating Sotto or taking keyboard focus from the insertion target.
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = NSHostingView(rootView: DictationHUD(controller: controller).padding(18))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            // The extra transparent footprint sits below the capsule, keeping
            // its original resting position whether a limit notice is shown.
            setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 20 - DictationHUD.noticeHeight))
        }
        orderFrontRegardless()
    }
}
