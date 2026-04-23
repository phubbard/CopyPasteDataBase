#if os(iOS)
import SwiftUI
import GRDB
import CpdbShared

/// List of Macs the iOS app knows about, pulled from the local
/// `devices` table (populated during CloudKit pull as each Mac's
/// entries arrive). Tap a row to send a paste-ActionRequest
/// targeting that Mac.
///
/// Own iOS device is filtered out — we can't paste onto
/// ourselves via this mechanism (iOS has no NSPasteboard-equivalent
/// remote-driven sink).
struct DevicePickerSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    /// The entry we're pushing. Passed by caller from detail view.
    let entry: Entry

    @State private var devices: [Device] = []
    @State private var inFlightDeviceID: String? = nil
    @State private var lastResult: Result?

    enum Result {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(devices, id: \.id) { device in
                        Button {
                            Task { await send(to: device) }
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                        .foregroundStyle(.primary)
                                    Text(device.identifier)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                if inFlightDeviceID == device.identifier {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(inFlightDeviceID != nil)
                    }
                } footer: {
                    Text("The selected Mac will copy this entry to its clipboard. Press ⌘V on that Mac to paste.")
                }

                if let r = lastResult {
                    Section {
                        switch r {
                        case .success(let name):
                            Label("Sent to \(name)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let err):
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Push to Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await loadDevices()
        }
    }

    private func loadDevices() async {
        guard let store = container.store else { return }
        do {
            let rows: [Device] = try await store.dbQueue.read { db in
                try Device
                    .filter(Column("kind") == "mac")
                    .order(Column("name"))
                    .fetchAll(db)
            }
            devices = rows
        } catch {
            devices = []
        }
    }

    private func send(to device: Device) async {
        inFlightDeviceID = device.identifier
        defer { inFlightDeviceID = nil }
        do {
            try await container.sendPasteRequest(
                entryContentHash: entry.contentHash,
                targetDeviceIdentifier: device.identifier
            )
            lastResult = .success(device.name)
            // Brief dwell so the user sees the success row, then
            // dismiss automatically.
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        } catch {
            lastResult = .failure("\(error)")
        }
    }
}
#endif
