import SwiftUI

/// Full-window zoomable / pannable image viewer that can page between
/// multiple images. Used both as the photo lightbox and the floorplan
/// zoom viewer.
///
/// Interaction:
/// - Pinch (trackpad) or the zoom slider / +- buttons to zoom (1x…6x)
/// - Drag to pan when zoomed in
/// - Double-click to reset zoom & position
/// - On-screen arrows or the ← → keys to page; Esc closes
struct ZoomableImageViewer: View {
    let urls: [URL]
    let title: String?

    @State private var index: Int
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(urls: [URL], startIndex: Int = 0, title: String? = nil) {
        // Upgrade Rightmove media URLs to full resolution for the zoom viewer;
        // thumbnails and the inline carousel keep their lighter sized variants.
        self.urls = urls.map(\.rightmoveFullResolution)
        self.title = title
        let safe = urls.isEmpty ? 0 : max(0, min(startIndex, urls.count - 1))
        _index = State(initialValue: safe)
    }

    private var current: URL? { urls.indices.contains(index) ? urls[index] : nil }

    /// Live zoom factor, combining the committed scale with an in-progress pinch.
    private var liveScale: CGFloat { min(max(scale * pinch, 1), 6) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            imageArea
            Divider()
            controls
        }
        .frame(minWidth: 1280, minHeight: 1024)
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow)  { page(-1); return .handled }
        .onKeyPress(.rightArrow) { page(1);  return .handled }
        .onKeyPress(.escape)     { dismiss(); return .handled }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Group {
                Text(title ?? "Photo")
                    .font(.title)
                    .fontWeight(.semibold)
                if urls.count > 1 {
                    Text("\(index + 1) / \(urls.count)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .fontWeight(.semibold)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .resizable()
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .keyboardShortcut(.cancelAction)
        }
        .padding(8)
        .padding(.horizontal)
    }

    // MARK: - Image area

    private var imageArea: some View {
        GeometryReader { _ in
            ZStack {
                Color.black.opacity(0.04)

                if let url = current {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .scaleEffect(liveScale)
                                .offset(x: offset.width + dragTranslation.width,
                                        y: offset.height + dragTranslation.height)
                                .gesture(magnification)
                                .simultaneousGesture(panning)
                                .onTapGesture(count: 2) { resetZoom() }
                        case .failure:
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        default:
                            ProgressView()
                        }
                    }
                }

                if urls.count > 1 {
                    HStack {
                        pageButton(systemImage: "chevron.left")  { page(-1) }
                        Spacer()
                        pageButton(systemImage: "chevron.right") { page(1) }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .clipped()
        }
    }

    private func pageButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button { setScale(scale - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.plain)
            Slider(value: Binding(get: { scale }, set: { setScale($0) }), in: 1...6, step: 0.1)
                .frame(maxWidth: 220)
            Button { setScale(scale + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.plain)
            Text("\(Int((scale * 100).rounded()))%")
                .foregroundStyle(.secondary)
            Spacer()
            Button { resetZoom() } label: {
                Text("Reset")
                    .fontWeight(.semibold)
            }
            .frame(height: 44)
            .disabled(scale == 1 && offset == .zero)
        }
        .padding(8)
        .padding(.horizontal)
        .font(.title)
    }

    // MARK: - Gestures

    private var magnification: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                scale = min(max(scale * value, 1), 6)
                if scale == 1 { offset = .zero }
            }
    }

    private var panning: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                // Only pan when zoomed in.
                state = scale > 1 ? value.translation : .zero
            }
            .onEnded { value in
                guard scale > 1 else { return }
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    // MARK: - Mutators

    private func setScale(_ newValue: CGFloat) {
        scale = min(max(newValue, 1), 6)
        if scale == 1 { offset = .zero }
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            scale = 1
            offset = .zero
        }
    }

    private func page(_ direction: Int) {
        guard urls.count > 1 else { return }
        index = (index + direction + urls.count) % urls.count
        scale = 1
        offset = .zero
    }
}

// MARK: - Full-resolution Rightmove media URLs

extension URL {
    /// Rightmove media URLs embed a sized variant before the extension, e.g.
    /// `…82311642cc59e20b8c9d6f24e4ecc65a_max_656x437.jpeg`. Removing the
    /// `_max_<W>x<H>` segment requests the original full-size image
    /// (`…82311642cc59e20b8c9d6f24e4ecc65a.jpeg`). Returns the URL unchanged when
    /// it doesn't contain that pattern.
    var rightmoveFullResolution: URL {
        let s = absoluteString
        guard let range = s.range(of: "_max_[0-9]+x[0-9]+", options: .regularExpression) else {
            return self
        }
        let stripped = s.replacingCharacters(in: range, with: "")
        return URL(string: stripped) ?? self
    }
}
