import SwiftUI

struct ContentView: View {
    @EnvironmentObject var watcher: StateWatcher
    @EnvironmentObject var schedule: ScheduleStatus

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
        }
        .padding(20)
        .frame(width: 240)
    }
}
