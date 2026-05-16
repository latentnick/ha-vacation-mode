import SwiftUI
import AppKit

@MainActor
final class ConfigViewModel: ObservableObject {
    @Published var config: AppConfig
    @Published var haToken: String
    @Published var influxPassword: String
    @Published var entities: [HAEntity] = []
    @Published var selected: Set<String> = []
    @Published var statusMessage: String = ""
    @Published var loading: Bool = false

    init() {
        let cfg = AppConfig.load()
        self.config = cfg
        self.haToken = KeychainStore.get(account: AppConfig.haTokenAccount) ?? ""
        self.influxPassword = KeychainStore.get(account: AppConfig.influxPasswordAccount) ?? ""
        self.selected = Set(cfg.entities)
    }

    func loadEntities() {
        guard let url = URL(string: config.ha.url), !haToken.isEmpty else {
            statusMessage = "Set HA URL and token first"
            return
        }
        loading = true
        statusMessage = "Loading entities…"
        let client = HAClient(baseURL: url, token: haToken)
        Task {
            do {
                let result = try await client.fetchEntities()
                self.entities = result
                self.statusMessage = "Found \(result.count) lights/switches"
            } catch {
                self.statusMessage = "Error: \(error.localizedDescription)"
            }
            self.loading = false
        }
    }

    func save() throws {
        try KeychainStore.set(haToken, account: AppConfig.haTokenAccount)
        try KeychainStore.set(influxPassword, account: AppConfig.influxPasswordAccount)
        config.entities = entities.map(\.entityId).filter { selected.contains($0) }
        if config.entities.isEmpty {
            // Allow saving previously-selected entities even without a fresh fetch.
            config.entities = Array(selected).sorted()
        }
        try config.save()
        statusMessage = "Saved."
    }
}

struct ConfigWindow: View {
    @StateObject var vm = ConfigViewModel()
    var onSaved: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lights Menubar — Configuration").font(.title2).bold()

            GroupBox("Home Assistant") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("URL")
                        TextField("http://homeassistant.local:8123", text: $vm.config.ha.url)
                    }
                    GridRow {
                        Text("Token")
                        SecureField("Long-lived access token", text: $vm.haToken)
                    }
                }.padding(8)
            }

            GroupBox("InfluxDB") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Host"); TextField("homeassistant.local", text: $vm.config.influx.host)
                    }
                    GridRow {
                        Text("Port"); TextField("8086", value: $vm.config.influx.port, format: .number.grouping(.never))
                    }
                    GridRow {
                        Text("Database"); TextField("homeassistant", text: $vm.config.influx.database)
                    }
                    GridRow {
                        Text("User"); TextField("homeassistant", text: $vm.config.influx.user)
                    }
                    GridRow {
                        Text("Password"); SecureField("", text: $vm.influxPassword)
                    }
                }.padding(8)
            }

            HStack {
                Button("Discover entities") { vm.loadEntities() }.disabled(vm.loading)
                Text(vm.statusMessage).font(.caption).foregroundStyle(.secondary)
            }

            GroupBox("Lights & switches") {
                List {
                    ForEach(vm.entities.isEmpty ? Array(vm.selected).sorted().map { HAEntity(entityId: $0, friendlyName: $0) } : vm.entities) { entity in
                        Toggle(isOn: Binding(
                            get: { vm.selected.contains(entity.entityId) },
                            set: { isOn in
                                if isOn { vm.selected.insert(entity.entityId) }
                                else { vm.selected.remove(entity.entityId) }
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text(entity.friendlyName)
                                Text(entity.entityId).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(minHeight: 160)
            }

            HStack {
                Stepper("Vacation window: \(vm.config.schedule.vacationDays) days",
                        value: $vm.config.schedule.vacationDays, in: 1...30)
                Spacer()
                Button("Save") {
                    do {
                        try vm.save()
                        onSaved?()
                    } catch {
                        vm.statusMessage = "Save error: \(error)"
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 640)
    }
}
