import SwiftUI

struct ContentView: View {
    @EnvironmentObject var watcher: StateWatcher

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
        }
        .padding(24)
        .frame(width: 220)
    }
}
