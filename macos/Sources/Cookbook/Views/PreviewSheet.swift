import SwiftUI

/// Up to 15 page images per screen, unpacked from a converted `.xtch` file.

struct PreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var screenText = "1"

    var body: some View {
        let session = model.preview
        VStack(alignment: .leading, spacing: 12) {
            Text(session?.title ?? L10n.t("previewTitle"))
                .font(.title2)
            Text(session?.status ?? "")
                .foregroundStyle(.secondary)

            pageGrid(session)

            HStack(spacing: 8) {
                Button {
                    Task { await model.previewPrevious() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help(L10n.t("previousPage"))
                .disabled(!canGoPrevious(session))
                .keyboardShortcut(.leftArrow, modifiers: [])

                HStack(spacing: 6) {
                    TextField("", text: $screenText)
                        .frame(width: 52)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .disabled(screenCount(session) == 0)
                        .onSubmit { jumpToTypedScreen() }
                    Text("/ \(screenCount(session))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Button {
                    Task { await model.previewNext() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help(L10n.t("nextPage"))
                .disabled(!canGoNext(session))
                .keyboardShortcut(.rightArrow, modifiers: [])

                Spacer()
                Button(L10n.t("close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { syncScreenText(session) }
        .onChange(of: session?.currentPage) { _, _ in
            syncScreenText(model.preview)
        }
        .onChange(of: session?.pageCount) { _, _ in
            syncScreenText(model.preview)
        }
    }

    @ViewBuilder
    private func pageGrid(_ session: PreviewSession?) -> some View {
        let start = session?.currentPage ?? 0
        ZStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(Array((session?.images ?? []).enumerated()), id: \.offset) { i, image in
                        VStack(spacing: 4) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 160)
                                .background(Color.white)
                                .border(Color.secondary.opacity(0.4))
                            Text("\(start + i + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.vertical, 4)
                .opacity(session?.loading == true ? 0.4 : 1)
            }
            if session?.loading == true {
                ProgressView()
            }
        }
    }

    private func screenCount(_ session: PreviewSession?) -> Int {
        AppModel.previewScreenCount(pages: session?.pageCount ?? 0)
    }

    private func currentScreen(_ session: PreviewSession?) -> Int {
        guard let session, session.pageCount > 0 else { return 0 }
        return session.currentPage / XtchPreview.pagesPerScreen
    }

    private func canGoPrevious(_ session: PreviewSession?) -> Bool {
        currentScreen(session) > 0
    }

    private func canGoNext(_ session: PreviewSession?) -> Bool {
        let count = screenCount(session)
        return count > 0 && currentScreen(session) + 1 < count
    }

    private func syncScreenText(_ session: PreviewSession?) {
        let count = screenCount(session)
        guard count > 0 else {
            screenText = "1"
            return
        }
        screenText = "\(currentScreen(session) + 1)"
    }

    private func jumpToTypedScreen() {
        let trimmed = screenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(trimmed) {
            Task { await model.previewGoToScreen(n - 1) }
        } else {
            syncScreenText(model.preview)
        }
    }
}
