import SwiftUI
import AppKit
import Combine

@main
struct LightsMenubarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // CLI shim: `LightsMenubar --resample <start> <end> <data.csv> <entity_map.json> <out.json> [seed]`
        let args = CommandLine.arguments
        if args.count >= 2 && args[1] == "--resample" {
            ResampleCLI.run(args: args)
            exit(0)
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var watcher: StateWatcher!
    private var scheduleStatus: ScheduleStatus!
    private var nightly: NightlyScheduler!
    private var executor: ScheduleExecutor!
    private var switchDaemon: SwitchDaemon!
    private var cancellable: AnyCancellable?
    private var configWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        watcher = StateWatcher()
        scheduleStatus = ScheduleStatus()
        executor = ScheduleExecutor(watcher: watcher, configProvider: { AppConfig.load() })
        switchDaemon = SwitchDaemon()

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 300)
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(watcher)
                .environmentObject(scheduleStatus)
                .environmentObject(executor)
                .environmentObject(switchDaemon)
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            updateIcon(on: watcher.on)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        cancellable = watcher.$on.receive(on: RunLoop.main).sink { [weak self] on in
            self?.updateIcon(on: on)
        }

        nightly = NightlyScheduler(
            configProvider: { AppConfig.load() },
            status: scheduleStatus
        )
        if AppConfig.load().isComplete {
            nightly.start()
            // Also generate once at launch. The Keychain item's ACL is bound to
            // the app's code signature, so any rebuild (or an unstable signing
            // identity) makes the next read prompt for access. Forcing a read
            // now — while the user is present to approve it — keeps that prompt
            // from landing on the unattended 4 AM nightly run and failing.
            Task { [weak self] in
                guard let self else { return }
                await ScheduleGenerator.runOnce(config: AppConfig.load(), status: self.scheduleStatus)
            }
        }

        switchDaemon.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        switchDaemon?.stop()
    }

    private func updateIcon(on: Bool) {
        statusItem.button?.image = NSImage(
            systemSymbolName: on ? "power.circle.fill" : "power.circle",
            accessibilityDescription: "Lights"
        )
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Configure…", action: #selector(openConfig), keyEquivalent: "").configuredTarget(self))
        menu.addItem(NSMenuItem(title: "Generate schedule now", action: #selector(generateNow), keyEquivalent: "").configuredTarget(self))
        menu.addItem(.separator())
        let status = NSMenuItem(title: "Switch: \(daemonStatusText())", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(NSMenuItem(title: "Restart switch daemon", action: #selector(restartDaemon), keyEquivalent: "").configuredTarget(self))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "").configuredTarget(self))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openConfig() {
        if let win = configWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = ConfigWindow(onSaved: { [weak self] in
            self?.nightly.start()
            Task { [weak self] in
                guard let self else { return }
                await ScheduleGenerator.runOnce(config: AppConfig.load(), status: self.scheduleStatus)
            }
        })
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Lights Menubar"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 520, height: 640))
        win.center()
        win.isReleasedWhenClosed = false
        configWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func generateNow() {
        Task { [weak self] in
            guard let self else { return }
            await ScheduleGenerator.runOnce(config: AppConfig.load(), status: self.scheduleStatus)
        }
    }

    @objc private func restartDaemon() {
        switchDaemon.restart()
    }

    private func daemonStatusText() -> String {
        switch switchDaemon.state {
        case .stopped: return "stopped"
        case .running: return "running"
        case .notConfigured: return "not configured"
        case .failed: return "failed"
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension NSMenuItem {
    func configuredTarget(_ t: AnyObject) -> NSMenuItem {
        self.target = t
        return self
    }
}
