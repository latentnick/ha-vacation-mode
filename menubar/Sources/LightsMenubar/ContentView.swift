import SwiftUI

struct ContentView: View {
    @EnvironmentObject var watcher: StateWatcher
    @EnvironmentObject var schedule: ScheduleStatus
    @EnvironmentObject var executor: ScheduleExecutor
    @EnvironmentObject var switchDaemon: SwitchDaemon
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsDetails = false

    var openSettings: () -> Void
    var refreshSchedule: () -> Void

    private var armed: Bool { watcher.awayState == .on }
    private var dark: Bool { colorScheme == .dark }
    private var surface: Color { dark ? Color(red: 0.13, green: 0.14, blue: 0.12) : Color(red: 0.98, green: 0.97, blue: 0.95) }
    private var amber: Color { dark ? Color(red: 0.91, green: 0.73, blue: 0.46) : Color(red: 0.60, green: 0.38, blue: 0.12) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lights").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            hero

            if armed {
                if let next = executor.nextEvent {
                    nextEvent(next)
                } else {
                    Text(schedule.isRunning ? "Preparing your schedule…" : "No upcoming lighting changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 20)
                }
            }

            if let issue = issue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }

            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    showsDetails.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)
                            .accessibilityHidden(true)
                        Text("System details")
                        Spacer()
                    }
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")

                if showsDetails {
                    details.padding(.bottom, 13)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)

            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(issue != nil ? amber : (ready ? Color.green.opacity(0.7) : Color.secondary))
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(healthText)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(schedule.isRunning ? "Refreshing…" : "Refresh schedule", action: refreshSchedule)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(schedule.isRunning)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 360)
        .background(surface)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            Image(systemName: "house")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(armed ? amber : Color.secondary)
                .frame(width: 72, height: 72)
                .background(armed ? amber.opacity(0.16) : Color.primary.opacity(0.06), in: Circle())
                .shadow(color: armed ? amber.opacity(0.15) : .clear, radius: 20)
                .accessibilityHidden(true)
                .padding(.bottom, 18)
            Text("A LITTLE LIFE AT HOME")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 28, weight: .medium))
                .tracking(-1)
                .padding(.top, 8)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .background {
            if armed {
                RadialGradient(colors: [amber.opacity(0.10), .clear], center: .init(x: 0.5, y: 0.35), startRadius: 0, endRadius: 150)
            }
        }
    }

    private var title: String {
        switch watcher.awayState {
        case .on: "Away mode is on"
        case .off: "Home, sweet home"
        case .unknown: "Getting settled…"
        }
    }

    private var subtitle: String {
        switch watcher.awayState {
        case .off: "Away mode is off."
        case .unknown: "Waiting for the away-mode state."
        case .on:
            if executor.lastError != nil { "Your lighting schedule needs attention." }
            else if executor.isActive { "Your lighting schedule is running." }
            else { "Your lighting schedule is starting…" }
        }
    }

    private func nextEvent(_ event: ScheduledEvent) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("UP NEXT").tracking(1)
                Spacer()
                Text(event.time, style: .relative)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(roomName(event.entity_id)).font(.system(size: 14, weight: .medium))
                    Text(event.action == "turn_on" ? "Lights turn on" : "Lights turn off")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(event.time, style: .time)
                    .font(.system(size: 20, weight: .regular))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .padding(16)
        .background(Color.primary.opacity(dark ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 13))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Schedule")
                Spacer()
                if schedule.isRunning { Text("Generating…") }
                else if let generated = schedule.lastGenerated {
                    Text("Updated \(generated, style: .relative) ago")
                } else { Text("Not generated yet") }
            }
            detail("Executor", value: executor.isActive ? "Active" : "Inactive")
            detail("HomeKit bridge", value: bridgeStatus)
            HStack {
                Text("State received")
                Spacer()
                if let updated = watcher.lastUpdated {
                    Text("\(updated, style: .relative) ago")
                } else { Text("Waiting…") }
            }
            if let pin = switchDaemon.pin {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pair in Apple Home")
                    Text(pin).monospaced().textSelection(.enabled)
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    private func detail(_ label: String, value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value) }
    }

    private var bridgeStatus: String {
        switch switchDaemon.state {
        case .running: "Running"
        case .stopped: "Stopped"
        case .notConfigured: "Not configured"
        case .failed: "Failed"
        }
    }

    private var issue: String? {
        if let error = executor.lastError, armed { return "Lighting: \(error)" }
        if let error = schedule.lastError { return "Schedule: \(error)" }
        switch switchDaemon.state {
        case .failed(let message), .notConfigured(let message): return "HomeKit: \(message)"
        case .stopped: return "HomeKit bridge is stopped."
        case .running: return nil
        }
    }

    private var ready: Bool {
        watcher.awayState != .unknown && schedule.lastGenerated != nil && issue == nil
    }

    private var healthText: String {
        if issue != nil { return "Needs attention" }
        if schedule.isRunning { return "Updating schedule" }
        if watcher.awayState == .unknown { return "Waiting for state" }
        return ready ? "All systems ready" : "Waiting for schedule"
    }

    private func roomName(_ entityID: String) -> String {
        let name = entityID.split(separator: ".", maxSplits: 1).last.map(String.init) ?? entityID
        return name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
