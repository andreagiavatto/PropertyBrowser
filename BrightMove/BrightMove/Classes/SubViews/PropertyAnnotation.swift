import AppKit
import MapKit
import SwiftUI
import RightmoveKit

/// A single mappable property. Carries just enough to render the price capsule
/// and the callout card without holding the whole `SearchProperty` struct.
final class PropertyAnnotation: NSObject, MKAnnotation {
    let propertyID: Int
    let coordinate: CLLocationCoordinate2D
    let shortPrice: String
    let fullPrice: String?
    let beds: Int?
    let baths: Int?
    let address: String?
    let subtype: String?
    let thumbnailURLString: String?
    var isPinned: Bool
    /// True once the user has opened this property's detail view — greys the pill.
    var isViewed: Bool

    /// Used by MapKit for the (suppressed) default callout title + accessibility.
    var title: String? { address }
    var subtitle: String? { fullPrice }

    init(
        propertyID: Int,
        coordinate: CLLocationCoordinate2D,
        shortPrice: String,
        fullPrice: String?,
        beds: Int?,
        baths: Int?,
        address: String?,
        subtype: String?,
        thumbnailURLString: String?,
        isPinned: Bool,
        isViewed: Bool
    ) {
        self.propertyID = propertyID
        self.coordinate = coordinate
        self.shortPrice = shortPrice
        self.fullPrice = fullPrice
        self.beds = beds
        self.baths = baths
        self.address = address
        self.subtype = subtype
        self.thumbnailURLString = thumbnailURLString
        self.isPinned = isPinned
        self.isViewed = isViewed
    }

    /// Build from a search result, or nil when it has no usable coordinate.
    convenience init?(search p: SearchProperty, isPinned: Bool, isViewed: Bool) {
        guard let id = p.propertyID,
              let lat = p.location?.lat,
              let lng = p.location?.lng else { return nil }
        self.init(
            propertyID: id,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            shortPrice: PriceShort.format(amount: p.price?.amount?.int,
                                          fallback: p.price?.primaryDisplay),
            fullPrice: p.price?.primaryDisplay,
            beds: p.bedrooms?.int,
            baths: p.bathrooms?.int,
            address: p.displayAddress,
            subtype: p.propertySubType,
            thumbnailURLString: p.propertyImages?.images?.first?.srcUrl,
            isPinned: isPinned,
            isViewed: isViewed
        )
    }
}

/// Compact money formatting for map capsules: 450000 → "£450k",
/// 1_250_000 → "£1.25m", small/odd values fall back to the raw display string.
enum PriceShort {
    static func format(amount: Int?, fallback: String?) -> String {
        guard let amount, amount > 0 else { return fallback ?? "—" }
        switch amount {
        case 1_000_000...:
            let m = Double(amount) / 1_000_000
            // One or two decimals, trimmed (1.0m → "1m", 1.25m → "1.25m").
            let s = String(format: "%.2f", m)
                .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
            return "£\(s)m"
        case 1_000...:
            let k = Int((Double(amount) / 1_000).rounded())
            return "£\(k)k"
        default:
            return "£\(amount)"
        }
    }
}

// MARK: - Annotation views

/// Rounded price capsule for a single property. Pinned properties get the
/// accent treatment so they stand out among search results.
final class PriceCapsuleAnnotationView: MKAnnotationView {
    static let reuseID = "PriceCapsule"

    private var hosting: NSHostingView<PriceCapsule>?

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = "property"
        canShowCallout = true
        collisionMode = .circle
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        guard let p = annotation as? PropertyAnnotation else { return }
        hosting?.removeFromSuperview()
        let view = NSHostingView(rootView: PriceCapsule(text: p.shortPrice, pinned: p.isPinned, viewed: p.isViewed))
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        addSubview(view)
        hosting = view
        frame = view.frame
        // Anchor the bottom-centre of the capsule at the coordinate.
        centerOffset = CGPoint(x: 0, y: -view.frame.height / 2)
        displayPriority = p.isPinned ? .required : .defaultHigh
    }
}

private struct PriceCapsule: View {
    let text: String
    let pinned: Bool
    let viewed: Bool

    /// Precedence: pinned (orange) beats viewed (grey) beats unviewed (accent).
    /// The grey signals "already looked at", so unviewed listings stand out.
    private var fill: Color {
        if pinned { return .orange }
        if viewed { return Color(nsColor: .systemGray) }
        return .accentColor
    }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

/// Count bubble for a cluster of properties.
final class PropertyClusterAnnotationView: MKAnnotationView {
    static let reuseID = "PropertyCluster"

    private var hosting: NSHostingView<ClusterBubble>?

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        canShowCallout = false
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        hosting?.removeFromSuperview()
        let count = cluster.memberAnnotations.count
        let view = NSHostingView(rootView: ClusterBubble(count: count))
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        addSubview(view)
        hosting = view
        frame = view.frame
        centerOffset = .zero
        displayPriority = .required
    }
}

private struct ClusterBubble: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(minWidth: 30, minHeight: 30)
            .padding(4)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
