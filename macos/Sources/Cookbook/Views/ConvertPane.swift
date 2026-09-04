import SwiftUI
import UniformTypeIdentifiers

/// Device picker, drop zone, file list. Convert / Cancel / Preview live on each row.

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

            if !model.convertStatus.isEmpty {
                Text(model.convertStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                        if model.isConverting(file.path) {
                            Button(L10n.t("cancel")) {
                                Task { await model.cancel() }
                            }
                        } else {
                            Button(L10n.t("convert")) {
                                Task { await model.convert(paths: [file.path]) }
                            }
                        }
                        if model.isXtch && file.canPreviewXtch {
                            Button(L10n.t("previewBtn")) {
                                Task { await model.openPreview(file) }
                            }
                        }
                        if !file.log.isEmpty {
                            Button(L10n.t(model.expandedLogs.contains(file.path) ? "hideLog" : "showLog")) {
                                model.toggleLog(file.path)
                            }
                        }
                        if !model.isConverting(file.path) {
                            Button(L10n.t("delete"), role: .destructive) {
                                model.removeFile(file.path)
                            }
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

    private var logExpanded: Bool { model.expandedLogs.contains(file.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !file.log.isEmpty {
                    Button {
                        model.toggleLog(file.path)
                    } label: {
                        Image(systemName: logExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t(logExpanded ? "hideLog" : "showLog"))
                }
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
                if model.isConverting(file.path) {
                    Button(L10n.t("cancel")) {
                        Task { await model.cancel() }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button(L10n.t("convert")) {
                        Task { await model.convert(paths: [file.path]) }
                    }
                    .buttonStyle(.borderless)
                }
                if model.isXtch && file.canPreviewXtch {
                    Button(L10n.t("previewBtn")) {
                        Task { await model.openPreview(file) }
                    }
                    .buttonStyle(.borderless)
                }
                if !model.isConverting(file.path) {
                    Button {
                        model.removeFile(file.path)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t("delete"))
                }
            }
            ProgressView(value: (file.percent ?? 0) / 100)
                .progressViewStyle(.linear)
            if !file.log.isEmpty {
                logSection
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var logSection: some View {
        if logExpanded {
            ScrollView {
                ScrollViewReader { proxy in
                    Text(file.log.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("log-end")
                        .onAppear {
                            proxy.scrollTo("log-end", anchor: .bottom)
                        }
                        .onChange(of: file.log.count) {
                            proxy.scrollTo("log-end", anchor: .bottom)
                        }
                }
            }
            .frame(maxHeight: 180)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25))
            }
        } else if let last = file.log.last {
            Text(last)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.toggleLog(file.path) }
                .help(L10n.t("showLog"))
        }
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
