import SwiftUI

/// Page images unpacked from a converted `.xtch` file.

struct PreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let session = model.preview
        VStack(alignment: .leading, spacing: 12) {
            Text(session?.title ?? L10n.t("previewTitle"))
                .font(.title2)
            Text(session?.status ?? "")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(Array((session?.images ?? []).enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 160)
                            .background(Color.white)
                            .border(Color.secondary.opacity(0.4))
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button(L10n.t("close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }
}
