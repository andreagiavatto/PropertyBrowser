import Foundation

/// The shape returned by PaTMa's `prospector/be/load_info/` endpoint. The body
/// is a single `html` field containing a pre-rendered panel; the historic
/// prices live in a `<table>` inside it (there is no structured JSON).
public struct PATMAResponse: Decodable, Sendable {
    public let html: String
}

/// One row of PaTMa's "Price History" table, e.g.
/// `6 Jun 2026 — £600,000 → £575,000` or `16 Apr 2026 — First seen → £600,000`.
public struct PriceHistoryEntry: Identifiable, Equatable, Sendable {
    /// The date PaTMa recorded the change.
    public let date: Date
    /// Previous price, or `nil` when this row is the first sighting.
    public let fromAmount: Int?
    /// Price after the change.
    public let toAmount: Int?
    /// True when the "from" cell was "First seen" rather than a price.
    public let isFirstSeen: Bool
    /// Non-numeric "from" cell text (e.g. "Unavailable"), when there's no price
    /// and it isn't a first sighting. `nil` when `fromAmount` carries the value.
    public let fromLabel: String?
    /// Non-numeric "to" cell text (e.g. "Unavailable (Under offer)"), when there's
    /// no price. `nil` when `toAmount` carries the value.
    public let toLabel: String?

    public var id: String { "\(date.timeIntervalSince1970)-\(toAmount ?? 0)-\(toLabel ?? "")" }

    public init(date: Date, fromAmount: Int?, toAmount: Int?, isFirstSeen: Bool,
                fromLabel: String? = nil, toLabel: String? = nil) {
        self.date = date
        self.fromAmount = fromAmount
        self.toAmount = toAmount
        self.isFirstSeen = isFirstSeen
        self.fromLabel = fromLabel
        self.toLabel = toLabel
    }

    /// Signed change for this row (negative = reduction), `nil` for first sighting.
    public var delta: Int? {
        guard let from = fromAmount, let to = toAmount else { return nil }
        return to - from
    }
}

/// Parses PaTMa's rendered price-history panel.
public enum PATMAPriceHistoryParser {

    /// Decode the JSON envelope, then parse the embedded HTML table.
    public static func parse(responseData data: Data) throws -> [PriceHistoryEntry] {
        let response = try JSONDecoder().decode(PATMAResponse.self, from: data)
        return parse(html: response.html)
    }

    /// Extract price-history rows from PaTMa's panel HTML.
    ///
    /// Only rows whose first cell is a valid `d MMM yyyy` date are kept, which
    /// naturally excludes the gated Rent/Yield/ROI/Invest table (its header row
    /// starts with "Rent", and its body row is a single colspan link).
    public static func parse(html: String) -> [PriceHistoryEntry] {
        rows(in: html).compactMap { cells -> PriceHistoryEntry? in
            guard cells.count == 4, let date = Self.date(from: cells[0]) else { return nil }
            let fromText = cells[1]
            let toText = cells[3]
            let isFirstSeen = fromText.range(of: "first seen", options: .caseInsensitive) != nil
            let fromAmount = isFirstSeen ? nil : amount(from: fromText)
            let toAmount = amount(from: toText)
            return PriceHistoryEntry(
                date: date,
                fromAmount: fromAmount,
                toAmount: toAmount,
                isFirstSeen: isFirstSeen,
                // Preserve non-numeric states (e.g. "Unavailable", "Unavailable
                // (Under offer)") that carry no digits, so the UI can show them
                // instead of a blank cell.
                fromLabel: (isFirstSeen || fromAmount != nil) ? nil : label(from: fromText),
                toLabel: toAmount != nil ? nil : label(from: toText)
            )
        }
    }

    // MARK: - HTML helpers

    /// Returns each `<tr>`'s trimmed, decoded `<td>` contents.
    private static func rows(in html: String) -> [[String]] {
        matches(of: #"<tr[^>]*>([\s\S]*?)</tr>"#, in: html).map { rowHTML in
            matches(of: #"<td[^>]*>([\s\S]*?)</td>"#, in: rowHTML).map(decodeCell)
        }
    }

    /// Strip tags, decode the few entities PaTMa emits, collapse whitespace.
    private static func decodeCell(_ raw: String) -> String {
        var s = raw.replacingOccurrences(
            of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&pound;": "£", "&amp;": "&", "&nbsp;": " ",
                        "&rarr;": "→", "&#8594;": "→", "&gt;": ">", "&lt;": "<"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First capture group of every match of `pattern` in `text`.
    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Parse "6 Jun 2026" → Date (UK locale, day-first short month).
    private static func date(from text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.dateFormat = "d MMM yyyy"
        return f.date(from: text)
    }

    /// Pull an integer amount out of "£600,000"; `nil` if there are no digits.
    private static func amount(from text: String) -> Int? {
        let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Non-empty, decoded cell text (e.g. "Unavailable") for non-numeric states;
    /// `nil` for blank cells or bare arrows.
    private static func label(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " →>-"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
