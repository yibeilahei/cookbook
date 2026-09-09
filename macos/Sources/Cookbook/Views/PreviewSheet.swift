import AppKit
import SwiftUI

/// Full-screen grid of XTCH pages. No scrolling; extra pages are paginated.

struct PreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var screenText = "1"

    private static let pageAspect: CGFloat = 528 / 792
    private static let captionHeight: CGFloat = 18
    private static let gap: CGFloat = 8
    private static let minPageWidth: CGFloat = 90

    var body: some View {
        let session = model.preview
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.previewPrevious() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(L10n.t("previousPage"))
                .disabled(!canGoPrevious(session))
                .keyboardShortcut(.leftArrow, modifiers: [])

                HStack(spacing: 6) {
                    TextField("", text: $screenText)
                        .frame(width: 56)
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
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(L10n.t("nextPage"))
                .disabled(!canGoNext(session))
                .keyboardShortcut(.rightArrow, modifiers: [])

                Text(session?.title ?? L10n.t("previewTitle"))
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.leading, 8)
                Text(session?.status ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)
                Button(L10n.t("close")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            pageGrid(session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
        }
        .frame(minWidth: Self.contentSize.width, minHeight: Self.contentSize.height)
        .background(PreviewWindowSizer())
        .onAppear { syncScreenText(session) }
        .onChange(of: session?.currentPage) { _, _ in
            syncScreenText(model.preview)
        }
        .onChange(of: session?.pageCount) { _, _ in
            syncScreenText(model.preview)
        }
        .onChange(of: session?.pagesPerScreen) { _, _ in
            syncScreenText(model.preview)
        }
    }

    @ViewBuilder
    private func pageGrid(_ session: PreviewSession?) -> some View {
        GeometryReader { geo in
            let layout = Self.fit(in: geo.size)
            let start = session?.currentPage ?? 0
            let images = session?.images ?? []
            ZStack {
                VStack(spacing: Self.gap) {
                    ForEach(0..<layout.rows, id: \.self) { row in
                        HStack(spacing: Self.gap) {
                            ForEach(0..<layout.cols, id: \.self) { col in
                                let i = row * layout.cols + col
                                if i < images.count {
                                    pageCell(
                                        images[i],
                                        number: start + i + 1,
                                        width: layout.pageWidth,
                                        height: layout.pageHeight)
                                } else {
                                    Color.clear.frame(
                                        width: layout.pageWidth,
                                        height: layout.pageHeight + Self.captionHeight)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(session?.loading == true ? 0.4 : 1)
                if session?.loading == true {
                    ProgressView()
                }
            }
            .onAppear {
                Task { await model.previewSetPageCapacity(layout.count) }
            }
            .onChange(of: layout.count) { _, count in
                Task { await model.previewSetPageCapacity(count) }
            }
        }
    }

    private func pageCell(_ image: NSImage, number: Int, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 2) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: width, height: height)
                .background(Color.white)
                .border(Color.secondary.opacity(0.35))
            Text("\(number)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(height: Self.captionHeight - 2)
        }
    }

    private struct Layout: Equatable {
        var cols: Int
        var rows: Int
        var pageWidth: CGFloat
        var pageHeight: CGFloat
        var count: Int { cols * rows }
    }

    /// Pack as many 528×792 pages as will fit, then grow them to fill the cell.
    private static func fit(in size: CGSize) -> Layout {
        let w = max(1, size.width)
        let h = max(1, size.height)
        let aspect = Self.pageAspect
        let caption = Self.captionHeight
        let gap = Self.gap
        var best = Layout(cols: 1, rows: 1, pageWidth: Self.minPageWidth, pageHeight: Self.minPageWidth / aspect)
        var bestCount = 0
        var bestArea: CGFloat = 0
        let maxCols = max(1, Int(w / Self.minPageWidth))
        for cols in 1...maxCols {
            let cellW = (w - gap * CGFloat(max(cols - 1, 0))) / CGFloat(cols)
            guard cellW >= Self.minPageWidth else { continue }
            let heightIfWidth = cellW / aspect + caption
            var rows = max(1, Int((h + gap) / (heightIfWidth + gap)))
            while rows > 1 {
                let rowBudget = (h - gap * CGFloat(rows - 1)) / CGFloat(rows)
                if rowBudget - caption >= Self.minPageWidth / aspect { break }
                rows -= 1
            }
            let rowBudget = (h - gap * CGFloat(max(rows - 1, 0))) / CGFloat(rows)
            let maxPageH = max(1, rowBudget - caption)
            let pageW = min(cellW, maxPageH * aspect)
            let pageH = pageW / aspect
            let count = cols * rows
            let area = pageW * pageH
            if count > bestCount || (count == bestCount && area > bestArea) {
                bestCount = count
                bestArea = area
                best = Layout(cols: cols, rows: rows, pageWidth: pageW, pageHeight: pageH)
            }
        }
        return best
    }

    /// SwiftUI content size: screen minus a titlebar so the window still fits
    /// in `visibleFrame` with the pager bar on-screen.
    private static var contentSize: CGSize {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let titlebar: CGFloat = 28
        return CGSize(
            width: max(1000, visible.width),
            height: max(700, visible.height - titlebar))
    }

    private func screenCount(_ session: PreviewSession?) -> Int {
        AppModel.previewScreenCount(
            pages: session?.pageCount ?? 0,
            stride: session?.pagesPerScreen ?? 1)
    }

    private func currentScreen(_ session: PreviewSession?) -> Int {
        guard let session, session.pageCount > 0, session.pagesPerScreen > 0 else { return 0 }
        return session.currentPage / session.pagesPerScreen
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

/// Size the sheet to the screen's visible frame. The pager lives in the
/// SwiftUI stack (not below the content view), so the titlebar cannot clip it.
private struct PreviewWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(view, tries: 0) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(view, tries: 0) }
    }

    private static func apply(_ view: NSView, tries: Int) {
        guard let window = view.window else {
            if tries < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    Self.apply(view, tries: tries + 1)
                }
            }
            return
        }
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let title = max(28, window.frame.height - window.contentLayoutRect.height)
        window.setContentSize(NSSize(
            width: visible.width,
            height: max(700, visible.height - title)))
        var placed = window.frame
        placed.origin.x = visible.minX
        placed.origin.y = visible.minY
        if placed.maxY > visible.maxY {
            placed.origin.y = visible.maxY - placed.height
        }
        if placed.maxX > visible.maxX {
            placed.origin.x = visible.maxX - placed.width
        }
        window.setFrame(placed, display: true)
    }
}
