import SwiftUI
import UniformTypeIdentifiers

struct ConvertPane: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("device"))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: $model.selectedDevice) {
                    ForEach(model.devices) { device in
                        Text(device.menuTitle).tag(device.key)
                    }
                }
                .labelsHidden()
                Button(L10n.t("editDevices")) {
                    model.showDeviceEditor = true
                }
            }

            dropWell

            fileList

            HStack {
                Text(L10n.t("outputFolder"))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                TextField("", text: Binding(
                    get: { model.outputDir ?? "" },
                    set: { _ in }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
                .help(L10n.t("outputPlaceholder"))
                Button(L10n.t("browse")) { model.pickOutputDir() }
                Button(L10n.t("useDefault")) { model.clearOutputDir() }
                    .disabled(model.outputDir == nil)
            }

            if model.showBatch {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(model.batchPercent), total: 100)
                    Text(L10n.t("batchProgress", [
                        "completed": "\(model.batchCompleted)",
                        "total": "\(model.batchTotal)",
                        "percent": "\(model.batchPercent)",
                        "eta": model.batchEta,
                    ]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(L10n.t("convert")) {
                    Task { await model.convert() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.converting)
                if model.converting {
                    Button(L10n.t("cancel")) {
                        Task { await model.cancel() }
                    }
                }
                Text(model.convertStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dropWell: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L10n.t("dropzoneText"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.t("addFiles")) { model.pickInputs() }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            Task { await loadDropped(providers) }
            return true
        }
    }

    private var fileList: some View {
        List(selection: Binding(
            get: { model.selectedFile },
            set: { newValue in
                if let newValue {
                    Task { await model.selectFile(newValue) }
                } else {
                    model.clearFileSelection()
                }
            }
        )) {
            ForEach(model.files) { file in
                FileRow(file: file)
                    .tag(file.path)
                    .contextMenu {
                        Button(L10n.t("previewBtn")) {
                            Task { await model.openPreview(file.path) }
                        }
                        Button(L10n.t("delete"), role: .destructive) {
                            model.removeFile(file.path)
                        }
                    }
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 160)
    }

    private func loadDropped(_ providers: [NSItemProvider]) async {
        var paths: [String] = []
        for provider in providers {
            if let url = await Self.readFileURL(provider) {
                paths.append(url.path)
            }
        }
        await model.addPaths(paths)
    }

    private static func readFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: InputFile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(file.name)
                    .lineLimit(1)
                    .help(file.path)
                Spacer()
                if let stage = file.stage {
                    let key = "stage" + stage.prefix(1).uppercased() + stage.dropFirst()
                    let label = L10n.t(String(key))
                    Text(label == key ? stage : label)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(stageColor(stage).opacity(0.2), in: Capsule())
                        .help(file.message ?? "")
                }
                Button(L10n.t("previewBtn")) {
                    Task { await model.openPreview(file.path) }
                }
                .buttonStyle(.borderless)
                Button {
                    model.removeFile(file.path)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.t("delete"))
            }
            ProgressView(value: (file.percent ?? 0) / 100)
                .progressViewStyle(.linear)
        }
        .padding(.vertical, 2)
    }

    private func stageColor(_ stage: String) -> Color {
        switch stage {
        case "done": return .green
        case "error": return .red
        case "cancelled": return .orange
        case "convert", "pack": return .blue
        default: return .secondary
        }
    }
}
