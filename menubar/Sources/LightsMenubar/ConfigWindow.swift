import SwiftUI
import AppKit

@MainActor
final class ConfigViewModel: ObservableObject {
    @Published var config: AppConfig
    @Published var entities: [LightEntity] = []
    @Published var selected: Set<String> = []
    @Published var statusMessage: String = ""
    @Published var loading: Bool = false
    @Published var lutron: AppConfig.Lutron
    @Published var lutronDevices: [LutronDevice] = []
    private var importedIdentity: LutronIdentity?
    @Published var pairing = false
    @Published var pairingMessage = ""
    private var pairingTask: Task<Void, Never>?

    init() {
        let cfg = AppConfig.load()
        self.config = cfg
        self.selected = Set(cfg.entities)
        self.lutron = cfg.lutron ?? AppConfig.Lutron()
    }

    private func lutronClient() throws -> LutronClient {
        if let importedIdentity { return LutronClient(host: lutron.host, identity: importedIdentity) }
        return try LutronClient.saved(host: lutron.host)
    }

    func pairWithHub() {
        guard !loading, !pairing else { return }
        pairing = true
        loading = true
        lutronDevices = []
        pairingMessage = "Connecting securely to the hub…"
        let host = lutron.host.trimmingCharacters(in: .whitespacesAndNewlines)
        lutron.host = host
        pairingTask = Task { [self] in
            do {
                let identity = try await LutronClient(host: host, identity: nil).pair { [weak self] stage in
                    Task { @MainActor [weak self] in
                        guard let self, self.pairing else { return }
                        switch stage {
                        case "press_button": self.pairingMessage = "Press the small button on the back of your Lutron hub now. Waiting up to 90 seconds…"
                        case "verifying": self.pairingMessage = "Button received. Verifying the new pairing…"
                        default: self.pairingMessage = "Connecting securely to the hub…"
                        }
                    }
                }
                try Task.checkCancellation()
                let encoded = try JSONEncoder().encode(identity)
                try KeychainStore.set(String(decoding: encoded, as: UTF8.self), account: AppConfig.lutronIdentityAccount)
                self.importedIdentity = identity
                self.pairingMessage = "Paired successfully. Credentials saved in Keychain."
                self.pairing = false
                self.loading = false
                self.pairingTask = nil
                self.loadEntities()
            } catch {
                self.pairingMessage = Task.isCancelled ? "Pairing cancelled." : "Pairing failed: \(error.localizedDescription)"
                self.pairing = false
                self.loading = false
                self.pairingTask = nil
            }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingMessage = "Cancelling pairing…"
    }

    func importPairing() {
        let panel = NSOpenPanel()
        panel.title = "Import Lutron pairing"
        panel.message = "Select the credentials.json file created by the verified Lutron prototype. It will be saved in Keychain when you save settings."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 65536 else { throw LutronError("Pairing file is too large") }
            let identity = try JSONDecoder().decode(LutronIdentity.self, from: data)
            struct Host: Decodable { let host: String? }
            if let host = try JSONDecoder().decode(Host.self, from: data).host { lutron.host = host }
            importedIdentity = identity
            loadEntities()
        } catch { statusMessage = "Import failed: \(error.localizedDescription)" }
    }

    func loadEntities() {
        lutronDevices = []
        loading = true
        statusMessage = "Verifying pairing and discovering switches…"
        Task {
            defer { self.loading = false }
            do {
                let result = try await lutronClient().discover()
                self.lutronDevices = result
                var discovered: [LightEntity] = []
                for device in result {
                    let short = device.name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                    let inferred = "switch.\(short)"
                    let id = self.lutron.zones.first(where: { $0.value == device.zone })?.key ?? inferred
                    discovered.append(LightEntity(entityId: id, friendlyName: device.name))
                    // A visible suggestion only; Save validates all selected mappings.
                    if self.lutron.zones[id] == nil { self.lutron.zones[id] = device.zone }
                }
                let discoveredIDs = Set(discovered.map(\.entityId))
                discovered += self.selected.subtracting(discoveredIDs).map { LightEntity(entityId: $0, friendlyName: $0) }
                self.entities = discovered.sorted { $0.entityId < $1.entityId }
                self.statusMessage = "Verified \(result.count) switches. Review the zone mappings, then Save."
            } catch { self.statusMessage = "Lutron: \(error.localizedDescription)" }
        }
    }

    func save() throws {
        try lutron.validate(entities: Array(selected))
        guard !lutronDevices.isEmpty,
              selected.allSatisfy({ id in lutronDevices.contains { $0.zone == lutron.zones[id] } }) else {
            throw LutronError("Discover switches and verify each selected light's zone before saving")
        }
        if let importedIdentity {
            let data = try JSONEncoder().encode(importedIdentity)
            try KeychainStore.set(String(decoding: data, as: UTF8.self), account: AppConfig.lutronIdentityAccount)
        }
        config.lutron = lutron
        config.entities = Array(selected).sorted()
        try config.save()
        statusMessage = "Saved."
    }
}

struct ConfigWindow: View {
    @StateObject var vm = ConfigViewModel()
    var onSaved: (() -> Void)?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lights Menubar — Configuration").font(.title2).bold()

            LoginItemSettings()

            GroupBox("Lutron hub") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Hub IP address or hostname", text: $vm.lutron.host)
                        .disabled(vm.loading)
                        .onChange(of: vm.lutron.host) { _, _ in vm.lutronDevices = [] }
                    HStack {
                        Button(vm.pairing ? "Pairing…" : "Pair with hub") { vm.pairWithHub() }
                            .disabled(vm.loading || vm.lutron.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if vm.pairing {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { vm.cancelPairing() }
                        }
                        Menu("More") {
                            Button("Import existing pairing…") { vm.importPairing() }
                        }.disabled(vm.loading)
                    }
                    if !vm.pairingMessage.isEmpty {
                        Text(vm.pairingMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Pairing is stored in Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox("Usage history") {
                Text("Switch activity is recorded locally while the app runs. Only complete days recorded outside away mode are used for schedules.")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }

            HStack {
                Button("Discover entities") { vm.loadEntities() }.disabled(vm.loading)
                Text(vm.statusMessage).font(.caption).foregroundStyle(.secondary)
            }

            GroupBox("Lights & switches") {
                List {
                    ForEach(vm.entities.isEmpty ? Array(vm.selected).sorted().map { LightEntity(entityId: $0, friendlyName: $0) } : vm.entities) { entity in
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
                        if vm.selected.contains(entity.entityId) {
                            Picker("Lutron switch", selection: Binding(
                                get: { vm.lutron.zones[entity.entityId] ?? "" },
                                set: { vm.lutron.zones[entity.entityId] = $0 }
                            )) {
                                Text("Select a switch").tag("")
                                ForEach(vm.lutronDevices) { device in
                                    Text(device.name).tag(device.zone)
                                }
                            }
                        }
                    }
                }.frame(height: 200)
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
                }.keyboardShortcut(.defaultAction).disabled(vm.loading)
            }
        }
        .padding(20)
        }
        .frame(width: 560, height: 760)
        .onDisappear { if vm.pairing { vm.cancelPairing() } }
    }
}
