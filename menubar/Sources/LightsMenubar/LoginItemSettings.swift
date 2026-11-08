import AppKit
import ServiceManagement
import SwiftUI

struct LoginItemSettings: View {
    @State private var status = SMAppService.mainApp.status
    @State private var errorMessage: String?

    var body: some View {
        GroupBox("Startup") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch at login", isOn: Binding(
                    get: { status == .enabled },
                    set: setEnabled
                ))
                Text("Automatically open Lights Menubar when you log in to your Mac. Changes apply immediately.")
                    .font(.caption).foregroundStyle(.secondary)

                if status == .requiresApproval {
                    Text("Allow Lights Menubar in Login Items to enable launch at login.")
                        .font(.caption)
                    Button("Open Login Items…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if status == .notFound {
                    Text("Launch the installed LightsMenubar.app from Applications to configure launch at login.")
                        .font(.caption)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshStatus()
        }
    }

    private func refreshStatus() {
        status = SMAppService.mainApp.status
    }

    private func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        defer { refreshStatus() }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else if service.status != .enabled {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            errorMessage = "Couldn’t change launch at login: \(error.localizedDescription)"
        }
    }
}
