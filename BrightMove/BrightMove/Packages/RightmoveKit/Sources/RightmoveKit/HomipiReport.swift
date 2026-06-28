import Foundation

/// A property's public profile on Homipi (homipi.co.uk): the site's own price
/// estimate plus the area/risk facts it aggregates from open data once the full
/// address is known. Decoupled from the page's HTML shape — `HomipiParser`
/// produces this, and both the valuation provider and the detail-view section
/// read from it.
///
/// Every field is optional: Homipi renders a "-" for anything it can't supply,
/// and a parse miss should degrade to "not shown" rather than fail the whole
/// report. Money values are whole pounds.
public struct HomipiReport: Equatable, Sendable {
    /// Stable source label, shared with the valuation row.
    public static let source = "Homipi"

    /// The detail page this was parsed from (the canonical `/property/{city}/…`
    /// URL discovered via the postcode page).
    public let detailURL: URL

    // MARK: Valuation block
    /// Homipi's headline price estimate.
    public let estimate: Int?
    /// Lower/upper bound of Homipi's price range.
    public let priceLower: Int?
    public let priceUpper: Int?
    /// Confidence label, e.g. "High" / "Moderate".
    public let confidence: String?
    /// Change vs. the last sold price.
    public let valueChange: HomipiValueChange?
    public let lastSoldPrice: Int?
    public let lastSoldDate: String?

    // MARK: Property facts
    public let propertyType: String?
    public let tenure: String?
    public let floorAreaSqM: Int?
    /// EPC as Homipi renders it, e.g. "D / 63" (rating / efficiency).
    public let epcCurrent: String?
    public let epcPotential: String?
    public let councilTaxRate: String?
    public let councilTaxBand: String?
    /// Build era pulled from the "New Build" line, e.g. "1967-1975".
    public let buildEra: String?
    public let newBuild: Bool?
    public let floodRisk: String?
    public let localAuthority: String?

    // MARK: Area & history
    public let saleHistory: [HomipiSale]
    public let crime: HomipiCrime?
    public let areaStats: [HomipiAreaStat]

    public init(
        detailURL: URL,
        estimate: Int? = nil, priceLower: Int? = nil, priceUpper: Int? = nil,
        confidence: String? = nil, valueChange: HomipiValueChange? = nil,
        lastSoldPrice: Int? = nil, lastSoldDate: String? = nil,
        propertyType: String? = nil, tenure: String? = nil, floorAreaSqM: Int? = nil,
        epcCurrent: String? = nil, epcPotential: String? = nil,
        councilTaxRate: String? = nil, councilTaxBand: String? = nil,
        buildEra: String? = nil, newBuild: Bool? = nil,
        floodRisk: String? = nil, localAuthority: String? = nil,
        saleHistory: [HomipiSale] = [], crime: HomipiCrime? = nil,
        areaStats: [HomipiAreaStat] = []
    ) {
        self.detailURL = detailURL
        self.estimate = estimate
        self.priceLower = priceLower
        self.priceUpper = priceUpper
        self.confidence = confidence
        self.valueChange = valueChange
        self.lastSoldPrice = lastSoldPrice
        self.lastSoldDate = lastSoldDate
        self.propertyType = propertyType
        self.tenure = tenure
        self.floorAreaSqM = floorAreaSqM
        self.epcCurrent = epcCurrent
        self.epcPotential = epcPotential
        self.councilTaxRate = councilTaxRate
        self.councilTaxBand = councilTaxBand
        self.buildEra = buildEra
        self.newBuild = newBuild
        self.floodRisk = floodRisk
        self.localAuthority = localAuthority
        self.saleHistory = saleHistory
        self.crime = crime
        self.areaStats = areaStats
    }

    /// The estimate as a `MoneyRange` for the valuation provider. Prefers
    /// Homipi's headline estimate (filling any missing bound from it — Homipi's
    /// range is sometimes one-sided, e.g. mid == upper). When a listing gives
    /// only a price range and no point estimate, falls back to the range's
    /// midpoint so the valuation row still has a figure. Nil if Homipi gave
    /// neither.
    public var valueRange: MoneyRange? {
        if let mid = estimate {
            return MoneyRange(lower: priceLower ?? mid, mid: mid, upper: priceUpper ?? mid)
        }
        if let lower = priceLower, let upper = priceUpper {
            return MoneyRange(lower: lower, mid: (lower + upper) / 2, upper: upper)
        }
        return nil
    }
}

/// Homipi's "Value Change" figure: the delta from the last sold price to the
/// current estimate, with the direction it colour-codes (green up / red down).
public struct HomipiValueChange: Equatable, Sendable {
    public let amount: Int?
    public let percent: String
    public let isIncrease: Bool
    /// The line as Homipi shows it, e.g. "£39,000 - 11.3%".
    public let text: String

    public init(amount: Int?, percent: String, isIncrease: Bool, text: String) {
        self.amount = amount
        self.percent = percent
        self.isIncrease = isIncrease
        self.text = text
    }
}

/// One row of Homipi's Land-Registry-backed sale-history table.
public struct HomipiSale: Equatable, Sendable, Identifiable {
    public let index: Int
    public let price: Int?
    public let date: String
    public let tenure: String
    public let newBuild: String
    /// Period-over-period change as Homipi prints it, e.g. "91.7%" or "n/a".
    public let valueChange: String

    public var id: Int { index }

    public init(index: Int, price: Int?, date: String, tenure: String,
                newBuild: String, valueChange: String) {
        self.index = index
        self.price = price
        self.date = date
        self.tenure = tenure
        self.newBuild = newBuild
        self.valueChange = valueChange
    }
}

/// Reported-crime summary: a total within a stated radius over the last month,
/// broken down by offence type.
public struct HomipiCrime: Equatable, Sendable {
    public let total: Int
    /// Radius as printed, e.g. "1 mile".
    public let radiusText: String
    public let byType: [Row]

    public struct Row: Equatable, Sendable, Identifiable {
        public let type: String
        public let count: Int
        public var id: String { type }
        public init(type: String, count: Int) { self.type = type; self.count = count }
    }

    public init(total: Int, radiusText: String, byType: [Row]) {
        self.total = total
        self.radiusText = radiusText
        self.byType = byType
    }
}

/// One row of Homipi's Census-2011 area-statistics table (district + area).
public struct HomipiAreaStat: Equatable, Sendable, Identifiable {
    /// e.g. "District: SW4" or "Area: SW".
    public let area: String
    public let population: String
    public let males: String
    public let females: String
    public let households: String

    public var id: String { area }

    public init(area: String, population: String, males: String,
                females: String, households: String) {
        self.area = area
        self.population = population
        self.males = males
        self.females = females
        self.households = households
    }
}

/// Why a Homipi lookup couldn't produce a report. Mirrors `ValuationError`'s
/// split so the valuation provider can map cleanly and the section can degrade
/// quietly.
public enum HomipiError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not enough to form a URL slug (no address number/street, or no postcode).
    case insufficientInput
    /// The postcode page loaded but had no property matching the address slug.
    case notFound
    /// A Cloudflare / bot challenge stood in for the page.
    case challenged(String)
    /// Network or HTTP failure.
    case network(String)
    /// The page loaded but couldn't be parsed into anything usable.
    case parse

    public var description: String {
        switch self {
        case .insufficientInput: return "Not enough address detail for Homipi."
        case .notFound:          return "No Homipi record for this address."
        case .challenged(let m): return "Homipi was unavailable (\(m))."
        case .network(let m):    return m
        case .parse:             return "Couldn't read the Homipi page."
        }
    }
}
