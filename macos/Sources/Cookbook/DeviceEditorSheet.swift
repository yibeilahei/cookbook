import SwiftUI

struct DeviceEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [DeviceDraft] = []
    @State private var defaultKey = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(L10n.t("editDevicesHeading")) (\(model.isXtch ? L10n.t("modeLabelXtch") : L10n.t("modeLabelPdf")))")
                .font(.title2)
            Table(of: DeviceDraft.self) {
                TableColumn(L10n.t("colKey")) { row in
                    rowBinding(row) { TextField("", text: $0.key) }
                }
                TableColumn(L10n.t("colLabel")) { row in
                    rowBinding(row) { TextField("", text: $0.label) }
                }
                TableColumn(L10n.t("colWidth")) { row in
                    rowBinding(row) { TextField("", value: $0.width, format: .number) }
                }
                .width(60)
                TableColumn(L10n.t("colHeight")) { row in
                    rowBinding(row) { TextField("", value: $0.height, format: .number) }
                }
                .width(60)
                TableColumn(L10n.t("colSupersample")) { row in
                    rowBinding(row) { TextField("", value: $0.supersample, format: .number) }
                        .disabled(!model.isXtch)
                }
                .width(80)
                TableColumn(L10n.t("colOrientation")) { row in
                    rowBinding(row) { binding in
                        Picker("", selection: binding.orientation) {
                            Text(L10n.t("orientationPortrait")).tag("portrait")
                            Text(L10n.t("orientationLandscape")).tag("landscape")
                        }
                        .labelsHidden()
                    }
                }
                TableColumn(L10n.t("colDefault")) { row in
                    Button {
                        defaultKey = row.key
                    } label: {
                        Image(systemName: defaultKey == row.key ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("colDefault"))
                }
                .width(60)
                TableColumn("") { row in
                    Button(L10n.t("delete"), role: .destructive) {
                        rows.removeAll { $0.id == row.id }
                    }
                    .buttonStyle(.borderless)
                }
                .width(70)
            } rows: {
                ForEach(rows) { row in
                    TableRow(row)
                }
            }
            HStack {
                Button(L10n.t("addDeviceRow")) {
                    rows.append(DeviceDraft(
                        key: "device\(rows.count + 1)",
                        label: "",
                        width: 480,
                        height: 800,
                        supersample: 3,
                        orientation: "portrait"
                    ))
                }
                Spacer()
                if !error.isEmpty {
                    Text(error).foregroundStyle(.red)
                }
                Button(L10n.t("cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 360)
        .onAppear { load() }
    }

    private func load() {
        rows = model.devices.map {
            DeviceDraft(
                key: $0.key,
                label: $0.label,
                width: $0.width,
                height: $0.height,
                supersample: $0.supersample,
                orientation: $0.orientation
            )
        }
        defaultKey = model.selectedDevice
    }

    private func save() {
        error = ""
        Task {
            do {
                try await model.saveDevices(rows, defaultKey: defaultKey)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func rowBinding<V: View>(_ row: DeviceDraft, @ViewBuilder field: (Binding<DeviceDraft>) -> V) -> V {
        let binding = Binding(
            get: { rows.first(where: { $0.id == row.id }) ?? row },
            set: { updated in
                if let idx = rows.firstIndex(where: { $0.id == updated.id }) {
                    rows[idx] = updated
                }
            }
        )
        return field(binding)
    }
}
