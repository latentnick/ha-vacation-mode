import SwiftUI

struct ContentView: View {
    @EnvironmentObject var watcher: StateWatcher
    @EnvironmentObject var schedule: ScheduleStatus
    @EnvironmentObject var executor: ScheduleExecutor
    @EnvironmentObject var switchDaemon: SwitchDaemon

    var body: some View {
        VStack(spacing: 12) {
            Text(watcher.on ? "ON" : "OFF")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(watcher.on ? Color.green : Color.secondary)

            if let updated = watcher.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for state…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if schedule.isRunning {
                Text("Generating schedule…").font(.caption).foregroundStyle(.secondary)
            } else if let err = schedule.lastError {
                Text("Schedule error: \(err)").font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if let gen = schedule.lastGenerated {
                Text("Schedule generated \(gen, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No schedule generated yet").font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            if executor.isActive {
                Text("Executor: active").font(.caption).foregroundStyle(.green)
                if let next = executor.nextEvent {
                    Text("Next: \(next.action) \(shortName(next.entity_id)) at \(next.time, style: .time)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text("Executor: inactive").font(.caption).foregroundStyle(.secondary)
            }
            if let err = executor.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            Divider()

            daemonRow
        }
        .padding(20)
        .frame(width: 340)
    }

    @ViewBuilder
    private var daemonRow: some View {
        switch switchDaemon.state {
        case .running:
            Text("Switch daemon: running").font(.caption).foregroundStyle(.green)
            if let pin = switchDaemon.pin {
                Text("Pair in Home app with PIN \(pin)").font(.caption).foregroundStyle(.secondary)
            }
        case .stopped:
            Text("Switch daemon: stopped").font(.caption).foregroundStyle(.secondary)
        case .notConfigured(let msg):
            Text("Switch daemon: \(msg)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .failed(let msg):
            Text("Switch daemon: \(msg)").font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func shortName(_ entityId: String) -> String {
        entityId.split(separator: ".", maxSplits: 1).last.map(String.init) ?? entityId
    }
}
