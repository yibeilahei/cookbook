import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let hint = model.calibreHint {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(hint)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    Button(L10n.t("recheck")) {
                        Task { await model.checkCalibre() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.yellow.opacity(0.15))
            }
            HSplitView {
                ConvertPane()
                    .frame(minWidth: 380)
                SettingsPane()
                    .frame(minWidth: 300)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(L10n.t("device"), selection: $model.mode) {
                    Text(L10n.t("modeXtch")).tag(ConvertMode.xtch)
                    Text(L10n.t("modePdf")).tag(ConvertMode.pdf)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
        }
        .navigationTitle("Cookbook")
        .sheet(isPresented: $model.showDeviceEditor) {
            DeviceEditorSheet()
        }
        .sheet(item: $model.preview) { _ in
            PreviewSheet()
        }
    }
}
