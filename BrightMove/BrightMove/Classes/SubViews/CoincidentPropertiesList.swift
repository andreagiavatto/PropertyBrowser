import SwiftUI

/// Shown in a popover when several properties share the exact same map
/// coordinate. Zooming can't separate stacked pins, so this lets the user pick
/// one from a scrollable list. Each row mirrors the callout card's peek, with a
/// pin toggle and a tap-through to the full detail view.
struct CoincidentPropertiesList: View {
    let properties: [PropertyAnnotation]
    let onSelect: (Int) -> Void
    let onTogglePin: (Int) -> Void

    /// Local copy so pin toggles reflect immediately while the popover is open.
    @State private var pinnedIDs: Set<Int>

    init(properties: [PropertyAnnotation],
         pinnedIDs: Set<Int>,
         onSelect: @escaping (Int) -> Void,
         onTogglePin: @escaping (Int) -> Void) {
        self.properties = properties
        self.onSelect = onSelect
        self.onTogglePin = onTogglePin
        _pinnedIDs = State(initialValue: pinnedIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(properties.count) properties here")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(properties, id: \.propertyID) { property in
                        row(for: property)
                        if property.propertyID != properties.last?.propertyID {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 280)
    }

    private func row(for property: PropertyAnnotation) -> some View {
        let isPinned = pinnedIDs.contains(property.propertyID)
        return Button {
            onSelect(property.propertyID)
        } label: {
            HStack(spacing: 10) {
                thumbnail(for: property)

                VStack(alignment: .leading, spacing: 2) {
                    Text(property.fullPrice ?? property.shortPrice)
                        .font(.subheadline.weight(.semibold))
                    if let beds = property.beds {
                        Text(specLine(beds: beds, baths: property.baths, subtype: property.subtype))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let address = property.address {
                        Text(address)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    onTogglePin(property.propertyID)
                    if isPinned {
                        pinnedIDs.remove(property.propertyID)
                    } else {
                        pinnedIDs.insert(property.propertyID)
                    }
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(isPinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin" : "Pin to watchlist")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnail(for property: PropertyAnnotation) -> some View {
        if let urlString = property.thumbnailURLString, let url = URL(string: urlString) {
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
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            placeholder.frame(width: 56, height: 56)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6)
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
