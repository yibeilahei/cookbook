import SwiftUI

/// Per-mode language, fonts, and page-compression settings.

struct SettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Text("\(L10n.t("settingsHeading")) (\(model.isXtch ? L10n.t("modeXtch") : L10n.t("modePdf")))")
                    .font(.headline)
            }
            Section {
                Picker(L10n.t("language"), selection: Binding(
                    get: { model.language },
                    set: { model.languageChanged($0) }
                )) {
                    ForEach(BookLanguage.all, id: \.self) { lang in
                        Text(L10n.t(BookLanguage.optKey(lang))).tag(lang)
                    }
                }
                Text(L10n.t("languageHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.isXtch {
                Section {
                    Toggle(L10n.t("compressLabel"), isOn: $model.pageCompression)
                        .onChange(of: model.pageCompression) { _, _ in
                            Task { await model.saveSettings() }
                        }
                    Text(L10n.t("compressHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.t("fontsHeading")) {
                Text(L10n.t("fontsHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                fontPicker(L10n.t("fontSerif"), selection: $model.fontSerif)
                fontPicker(L10n.t("fontSans"), selection: $model.fontSans)
                fontPicker(L10n.t("fontMono"), selection: $model.fontMono)
                TextField(L10n.t("fontSize"), value: $model.fontSize, format: .number)
                    .onSubmit { Task { await model.saveSettings() } }
                Text(L10n.t("fontSizeHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.settingsError.isEmpty {
                Text(model.settingsError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            if !model.settingsStatus.isEmpty {
                Text(model.settingsStatus)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.fontSerif) { _, _ in Task { await model.saveSettings() } }
        .onChange(of: model.fontSans) { _, _ in Task { await model.saveSettings() } }
        .onChange(of: model.fontMono) { _, _ in Task { await model.saveSettings() } }
        .onChange(of: model.fontSize) { _, _ in Task { await model.saveSettings() } }
    }

    private func fontPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            if !selection.wrappedValue.isEmpty,
               !model.systemFonts.contains(where: { $0.family == selection.wrappedValue }) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
            ForEach(model.systemFonts) { font in
                Text(font.display).tag(font.family)
            }
        }
    }
}
