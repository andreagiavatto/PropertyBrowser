import SwiftUI
import RightmoveKit
import PropertyStore

/// The data a `PropertyCard` needs to render. Conformed by both a live search
/// result (`SearchProperty`) and a saved watchlist entry (`PinnedProperty`), so
/// the same card renders identically in the search grid and the watchlist grid.
protocol PropertyCardData {
    var priceText: String? { get }
    var addressText: String? { get }
    var bedroomsCount: Int? { get }
    var bathroomsCount: Int? { get }
    var subtypeText: String? { get }
    var cardState: ListingState { get }
    var isReducedListing: Bool { get }
    var addedOrReducedText: String? { get }
    var thumbnailURLString: String? { get }
    var isFeaturedListing: Bool { get }
}

extension SearchProperty: PropertyCardData {
    var priceText: String? { price?.primaryDisplay }
    var addressText: String? { displayAddress }
    var bedroomsCount: Int? { bedrooms?.int }
    var bathroomsCount: Int? { bathrooms?.int }
    var subtypeText: String? { propertySubType }
    var cardState: ListingState { listingState }
    var isReducedListing: Bool { listingUpdate?.listingUpdateReason == "price_reduced" }
    var addedOrReducedText: String? { addedOrReduced }
    var thumbnailURLString: String? { propertyImages?.images?.first?.srcUrl }
    var isFeaturedListing: Bool { isFeatured }
}

extension PinnedProperty: PropertyCardData {
    var priceText: String? { currentPriceDisplay }
    var addressText: String? { displayAddress }
    var bedroomsCount: Int? { bedrooms }
    var bathroomsCount: Int? { bathrooms }
    var subtypeText: String? { propertySubType }
    var cardState: ListingState { currentState }
    var isReducedListing: Bool { isPriceReduced }
    var addedOrReducedText: String? { addedOrReduced }
    // `thumbnailURLString` is already a stored property on PinnedProperty.
    var isFeaturedListing: Bool { false }
}

/// A card-style property tile: hero photo on top, rich details below.
/// Designed to tile in an adaptive `LazyVGrid`.
struct PropertyCard<Data: PropertyCardData>: View {
    let data: Data
    let isPinned: Bool
    let onTogglePin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            photo
            details
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Photo + overlays

    private var photo: some View {
        thumbnail
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipped()
            .overlay(alignment: .topTrailing) { pinButton }
            .overlay(alignment: .bottomLeading) {
                if data.cardState != .available {
                    StatusBadge(state: data.cardState)
                        .padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if data.isFeaturedListing {
                    featuredBadge
                        .padding(8)
                }
            }
    }

    private var featuredBadge: some View {
        Label("Featured", systemImage: "star.fill")
            .font(.system(size: 15, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange, in: Capsule())
            .help("Promoted listing — also appears in its normal position below")
    }

    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isPinned ? Color.purple : .primary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .help(isPinned ? "Unpin" : "Pin to watchlist")
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(data.priceText ?? "Price on application")
                .font(.title2.weight(.semibold))

            Text(Format.oneLine(data.addressText))
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            facts

            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var facts: some View {
        HStack(spacing: 14) {
            if let beds = data.bedroomsCount, beds > 0 {
                Label("\(beds)", systemImage: "bed.double")
            }
            if let baths = data.bathroomsCount, baths > 0 {
                Label("\(baths)", systemImage: "shower")
            }
            if let type = data.subtypeText, !type.isEmpty {
                Label(type, systemImage: "house")
                    .lineLimit(1)
            }
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder private var footer: some View {
        let isReduced = data.isReducedListing
        let added = data.addedOrReducedText
        if isReduced || (added?.isEmpty == false) {
            HStack(spacing: 6) {
                if isReduced {
                    Label("Reduced", systemImage: "arrow.down.right")
                        .foregroundStyle(.green)
                        .fontWeight(.semibold)
                }
                Spacer(minLength: 0)
                if let added, !added.isEmpty {
                    Text(added)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.body)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let urlString = data.thumbnailURLString,
           let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Color.gray.opacity(0.12)
                    ProgressView()
                }
            }
        } else {
            ZStack {
                Color.gray.opacity(0.12)
                Image(systemName: "house")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
