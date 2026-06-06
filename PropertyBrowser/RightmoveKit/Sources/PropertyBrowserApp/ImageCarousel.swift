import SwiftUI

/// Paged photo carousel: one large image filling the column width with
/// prev/next arrows + a counter, a thumbnail strip to jump around, and
/// tap-to-open a full-screen zoomable lightbox.
struct ImageCarousel: View {
    let urls: [URL]

    @State private var index = 0
    @State private var showLightbox = false

    var body: some View {
        if urls.isEmpty {
            placeholder
        } else {
            VStack(spacing: 8) {
                mainImage
                if urls.count > 1 { thumbnails }
            }
            .sheet(isPresented: $showLightbox) {
                ZoomableImageViewer(urls: urls, startIndex: index, title: "Photo")
            }
        }
    }

    // MARK: - Main image

    private var mainImage: some View {
        ZStack {
            AsyncImage(url: urls[safe: index]) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Color.gray.opacity(0.12)
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                default:
                    Color.gray.opacity(0.08).overlay { ProgressView() }
                }
            }
            .frame(height: 360)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { showLightbox = true }

            if urls.count > 1 {
                HStack {
                    arrow("chevron.left")  { step(-1) }
                    Spacer()
                    arrow("chevron.right") { step(1) }
                }
                .padding(.horizontal, 10)
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("\(index + 1) / \(urls.count)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
            }
        }
        .frame(height: 360)
    }

    private func arrow(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.headline)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Thumbnails

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                        AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) }
                            placeholder: { Color.gray.opacity(0.1) }
                            .frame(width: 72, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(i == index ? Color.accentColor : .clear, lineWidth: 2)
                            }
                            .id(i)
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { index = i } }
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: index) { _, newValue in
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10).fill(.gray.opacity(0.15))
            .frame(height: 360)
            .overlay { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
    }

    // MARK: - Paging

    private func step(_ direction: Int) {
        guard !urls.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            index = (index + direction + urls.count) % urls.count
        }
    }
}

// MARK: - Safe indexing

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - FlowLayout

/// A simple flow layout that wraps subviews onto new rows when they
/// exceed the available width. Used for the wrapping facts row.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                widest = max(widest, x - hSpacing)
                y += rowHeight + vSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - hSpacing)
        let width = maxWidth.isFinite ? maxWidth : widest
        return CGSize(width: max(0, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > bounds.minX && (x - bounds.minX) + size.width > bounds.width {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
