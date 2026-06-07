import SwiftUI

/// Compact card shown in a map pin's callout: a peek at the property with a pin
/// toggle and a button through to the full detail view. Sized for a callout, so
/// it's deliberately smaller than the grid `PropertyCard`.
struct MapCalloutCard: View {
    let annotation: PropertyAnnotation
    let isPinned: Bool
    let onViewDetails: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail

            HStack(alignment: .firstTextBaseline) {
                Text(annotation.fullPrice ?? annotation.shortPrice)
                    .font(.headline)
                Spacer()
                Button {
                    onTogglePin()
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(isPinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin" : "Pin to watchlist")
            }

            if let beds = annotation.beds {
                Text(specLine(beds: beds, baths: annotation.baths, subtype: annotation.subtype))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let address = annotation.address {
                Text(address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Button("View details", action: onViewDetails)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .frame(width: 240)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let urlString = annotation.thumbnailURLString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                default:
                    placeholder.overlay { ProgressView().controlSize(.small) }
                }
            }
            .frame(width: 220, height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
    }

    private func specLine(beds: Int, baths: Int?, subtype: String?) -> String {
        var parts: [String] = ["\(beds) bed"]
        if let baths { parts.append("\(baths) bath") }
        if let subtype, !subtype.isEmpty { parts.append(subtype) }
        return parts.joined(separator: " · ")
    }
}
