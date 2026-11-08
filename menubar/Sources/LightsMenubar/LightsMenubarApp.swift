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
    private var recorder: LutronRecorder!
    private var cancellable: AnyCancellable?
    private var configWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        watcher = StateWatcher()
        recorder = LutronRecorder(watcher: watcher)
        recorder.start(config: AppConfig.load())
        scheduleStatus = ScheduleStatus()
        executor = ScheduleExecutor(watcher: watcher, configProvider: { AppConfig.load() })
        switchDaemon = SwitchDaemon()

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 340)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openConfig()
                },
                refreshSchedule: { [weak self] in self?.generateNow() }
            )
                .environmentObject(watcher)
                .environmentObject(scheduleStatus)
                .environmentObject(executor)
                .environmentObject(switchDaemon)
                .environmentObject(HistoryStatus.shared)
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
            // Generate from local history at launch.
            Task { [weak self] in
                guard let self else { return }
                await ScheduleGenerator.runOnce(config: AppConfig.load(), status: self.scheduleStatus)
            }
        }

        switchDaemon.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
        switchDaemon?.stop()
    }

    private func updateIcon(on: Bool) {
        statusItem.button?.image = NSImage(
            systemSymbolName: on ? "house.fill" : "house",
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
            self?.recorder.start(config: AppConfig.load())
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
        win.setContentSize(NSSize(width: 560, height: 760))
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
