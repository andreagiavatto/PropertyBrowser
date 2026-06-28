import Foundation

/// Pure, network-free parsing for Homipi pages. Kept offline and `static` so the
/// whole thing is unit-testable against saved fixtures, the same way
/// `HousePricesLink` and `LandCValuationClient`'s decoder are.
///
/// Homipi renders server-side HTML (no embedded JSON page model), so we read the
/// markup directly. The detail page's facts are a uniform list of
/// `<label class="css-label-a"> Label <strong>Value</strong> </label>` rows,
/// which makes a label→value dictionary the backbone of the parse; the
/// sale-history, crime and area tables are plain `<table>`s.
public enum HomipiParser {

    public static let host = "https://www.homipi.co.uk"

    // MARK: - URL building & discovery

    /// Homipi's city-agnostic postcode page, which lists every property in the
    /// postcode with its canonical `/property/{city}/…` link — so we never have
    /// to guess the `{city}` (or neighbourhood) path segments ourselves. The page
    /// is paginated (10 per page); pass `page` to reach later ones.
    public static func postcodePageURL(postcode: String, page: Int = 1) -> URL? {
        guard let slug = HousePricesLink.slug(forPostcode: postcode) else { return nil }
        let base = "\(host)/house-prices/postcode/\(slug)/"
        return URL(string: page > 1 ? "\(base)?page=\(page)" : base)
    }

    /// The highest `?page=N` linked on a postcode page — i.e. how many pages of
    /// properties the postcode has. 1 when unpaginated.
    public static func lastPageNumber(inPostcodeHTML html: String) -> Int {
        let nums = captures(#"[?&]page=([0-9]+)"#, in: html, group: 1).compactMap { Int($0) }
        return max(nums.max() ?? 1, 1)
    }

    /// The slug Homipi uses for a property's URL path, derived from a resolved
    /// single-line address. "15, Felmersham Close" → "15-felmersham-close";
    /// "Flat 7, Ascot Court, Clapham Park Road" → "flat-7-ascot-court-clapham-park-road".
    public static func propertySlug(fromAddress address: String?) -> String? {
        guard let raw = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // Apostrophes are elided (Homipi: "John's" → "johns"); every other
        // non-alphanumeric (commas, periods, spaces) becomes a separator that
        // collapses into single hyphens.
        var out = ""
        let space: Unicode.Scalar = " "
        for s in raw.lowercased().unicodeScalars {
            if s == "'" || s == "\u{2019}" { continue }
            out.unicodeScalars.append(CharacterSet.alphanumerics.contains(s) ? s : space)
        }
        let slug = out.split(separator: " ").joined(separator: "-")
        return slug.isEmpty ? nil : slug
    }

    /// Find the canonical detail URL for `slug` among the property links on a
    /// postcode page. Matches on the last path component so the `{city}` segment
    /// (embedded by Homipi) carries through untouched.
    public static func discoverDetailURL(inPostcodeHTML html: String,
                                         matchingSlug slug: String) -> URL? {
        let target = slug.lowercased()
        let pattern = #"href=\"(?:https://www\.homipi\.co\.uk)?(/property/[^\"]+?)/?\""#
        for path in captures(pattern, in: html, group: 1) {
            let last = path.split(separator: "/").last.map(String.init)?.lowercased()
            if slugMatches(last, target: target) {
                return URL(string: path.hasPrefix("http") ? path : host + path + "/")
            }
        }
        return nil
    }

    /// Whether a Homipi URL's last path component identifies the same property as
    /// our resolved-address `target` slug.
    ///
    /// Homipi's slug is a bare `{paon}-{street}` (e.g. `10-churchfield-avenue`),
    /// while a resolved address routinely carries extra tokens Homipi omits, on
    /// *both* sides: a sub-building (SAON) in front — "Ground Floor Flat, 10
    /// Churchfield Avenue, North Finchley" → `ground-floor-flat-10-churchfield-avenue-north-finchley`
    /// — and a postcode/locality behind. We therefore match when the page slug's
    /// tokens occur as a *contiguous run* anywhere within the resolved slug's
    /// tokens. Comparing whole hyphen-separated tokens (not substrings) keeps
    /// `10` from matching `110` and `flat-1` from matching `flat-10`.
    private static func slugMatches(_ urlLast: String?, target: String) -> Bool {
        guard let urlLast, !urlLast.isEmpty else { return false }
        if urlLast == target { return true }
        let needle = urlLast.split(separator: "-").map(String.init)
        let hay = target.split(separator: "-").map(String.init)
        guard !needle.isEmpty, needle.count <= hay.count else { return false }
        for start in 0...(hay.count - needle.count) where Array(hay[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }

    // MARK: - Detail page

    /// Parse a property detail page into a `HomipiReport`. Tolerant by design:
    /// any field Homipi omits (rendered "-") or that fails to parse simply stays
    /// nil rather than failing the whole report.
    public static func parseDetail(html: String, url: URL) -> HomipiReport {
        let rows = labelRows(in: html)
        var attrs: [String: String] = [:]
        var valueChangeInner: String?
        for row in rows {
            if attrs[row.label] == nil { attrs[row.label] = row.value }
            if row.label.lowercased().hasPrefix("value change") { valueChangeInner = row.inner }
        }
        func text(_ key: String) -> String? { clean(attrs[key]) }

        return HomipiReport(
            detailURL: url,
            estimate: money(attrs["Homipi Price Estimate"]),
            priceLower: moneyBounds(attrs["Price Range"]).lower,
            priceUpper: moneyBounds(attrs["Price Range"]).upper,
            confidence: text("Estimate Confidence"),
            valueChange: parseValueChange(text: attrs["Value Change"], inner: valueChangeInner),
            lastSoldPrice: money(attrs["Last Sold Price"]),
            lastSoldDate: text("Last Sold Date"),
            propertyType: text("Type"),
            tenure: text("Tenure"),
            floorAreaSqM: intValue(attrs["Floor Area (Sq. Meters)"]),
            epcCurrent: text("Current EPC Rating/Efficiency"),
            epcPotential: text("Potential EPC Rating/Efficiency"),
            councilTaxRate: text("Council Tax Rate"),
            councilTaxBand: text("Council Tax Band"),
            buildEra: buildEra(attrs["New Build"]),
            newBuild: newBuild(attrs["New Build"]),
            floodRisk: text("Flood Risk"),
            localAuthority: text("Local Authority"),
            saleHistory: parseSaleHistory(html: html),
            crime: parseCrime(html: html),
            areaStats: parseAreaStats(html: html)
        )
    }

    // MARK: - Postcode listing (estimate without a detail fetch)

    /// Parse the postcode-page listing block for `slug` straight into a
    /// `HomipiReport`, with no detail-page fetch. Each listing carries its
    /// valuation inline — either a headline `Homipi Price Estimate` (+ value
    /// change) or, for properties Homipi only brackets, a `Price Range` (+
    /// `Estimate Confidence`) — alongside the last-sold facts and a
    /// beds/type/tenure summary.
    ///
    /// The postcode page *also* renders the postcode-level reported-crime and
    /// Census area-statistics blocks (outside any single listing), so we fold
    /// those in from the full page HTML here too — the detail-view section wants
    /// them and they cost no extra fetch. The remaining detail-only fields (sale
    /// history, EPC, floor area, council tax, flood risk, …) aren't on the
    /// postcode page and simply stay nil/empty. Returns nil if no listing
    /// matches the slug.
    public static func parseListing(inPostcodeHTML html: String,
                                    matchingSlug slug: String) -> HomipiReport? {
        guard let block = listingBlock(inPostcodeHTML: html, matchingSlug: slug) else { return nil }

        var attrs: [String: String] = [:]
        var valueChangeInner: String?
        for row in labelRows(in: block.body) {
            if attrs[row.label] == nil { attrs[row.label] = row.value }
            if row.label.lowercased().hasPrefix("value change") { valueChangeInner = row.inner }
        }
        let stats = statistic2Items(in: block.body)

        return HomipiReport(
            detailURL: block.url,
            estimate: money(attrs["Homipi Price Estimate"]),
            priceLower: moneyBounds(attrs["Price Range"]).lower,
            priceUpper: moneyBounds(attrs["Price Range"]).upper,
            confidence: clean(attrs["Estimate Confidence"]),
            valueChange: parseValueChange(text: attrs["Value Change"], inner: valueChangeInner),
            lastSoldPrice: money(attrs["Last Sold Price"]),
            lastSoldDate: clean(attrs["Last Sold Date"]),
            propertyType: stats.type,
            tenure: stats.tenure,
            // Page-level area facts, read from the full postcode HTML (present on
            // every paginated page, so the matched page always carries them).
            crime: parseCrime(html: html),
            areaStats: parseAreaStats(html: html)
        )
    }

    /// The (`detailURL`, inner-HTML) of the listing whose property link ends in
    /// `slug`. A listing's facts live between its own anchor and the next
    /// listing's (or the end of the list), so that span is the block we parse.
    /// The detail URL is kept only as a deep link for the user — never fetched.
    private static func listingBlock(inPostcodeHTML html: String,
                                     matchingSlug slug: String) -> (url: URL, body: String)? {
        let target = slug.lowercased()
        let pattern = #"<a\s+href=\"((?:https://www\.homipi\.co\.uk)?/property/[^\"]+?)/?\"[^>]*title=\"View Property Details"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for (i, m) in matches.enumerated() {
            let path = ns.substring(with: m.range(at: 1))
            let last = path.split(separator: "/").last.map(String.init)?.lowercased()
            guard slugMatches(last, target: target) else { continue }
            let start = m.range.location
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: end - start))
            guard let url = URL(string: path.hasPrefix("http") ? path : host + path + "/")
            else { return nil }
            return (url, body)
        }
        return nil
    }

    /// The bedroom/type/tenure `<li>`s of a listing's first `statistic2` list,
    /// classified into the `HomipiReport` facts the postcode page exposes. The
    /// set and order vary per listing (e.g. "2 Beds, Flat" vs. "Flat,
    /// Leasehold"), so each item is classified by content: bedroom counts are
    /// dropped (no field for them), the tenure keywords map to `tenure`, and the
    /// first remaining item is the property type.
    private static func statistic2Items(in block: String) -> (type: String?, tenure: String?) {
        guard let ul = first(#"<ul class=\"statistic2\">(.*?)</ul>"#, in: block, dotAll: true)
        else { return (nil, nil) }
        var type: String?
        var tenure: String?
        for raw in captures(#"<li>(.*?)</li>"#, in: ul, group: 1, dotAll: true) {
            let item = stripTags(raw)
            let lower = item.lowercased()
            if item.isEmpty || lower.contains("bed") { continue }
            if lower == "leasehold" || lower == "freehold" { tenure = item }
            else if type == nil { type = item }
        }
        return (type, tenure)
    }

    // MARK: Attribute rows

    private struct LabelRow { let label: String; let value: String; let inner: String }

    /// Every `<label class="css-label-a"> … <strong>value</strong> </label>` on
    /// the page, split into its label text, its stripped value, and the raw
    /// inner HTML of the `<strong>` (kept so the value-change colour/arrow can be
    /// read for the up/down direction).
    private static func labelRows(in html: String) -> [LabelRow] {
        // Most rows are `<label class="css-label-a">`, but a few carry a leading
        // `for="…"` attribute (e.g. Council Tax Rate), so match the class
        // anywhere in the tag. Homipi also pairs `css-label-a` with extra classes
        // (e.g. `class="css-label-a dotted-bottom-border"`), so match it as one
        // token among a space-separated list rather than the whole attribute —
        // otherwise every row silently fails to parse.
        let pattern = #"<label[^>]*class=\"(?:[^\"]*\s)?css-label-a(?:\s[^\"]*)?\"[^>]*>(.*?)</label>"#
        var out: [LabelRow] = []
        for inner in captures(pattern, in: html, group: 1, dotAll: true) {
            guard let strongInner = first(#"<strong>(.*?)</strong>"#, in: inner, dotAll: true)
            else { continue }
            // Label = everything before the <strong>, tags stripped.
            let head = inner.range(of: "<strong", options: .caseInsensitive)
                .map { String(inner[inner.startIndex..<$0.lowerBound]) } ?? inner
            let label = stripTags(head)
            guard !label.isEmpty else { continue }
            out.append(LabelRow(label: label, value: stripTags(strongInner), inner: strongInner))
        }
        return out
    }

    private static func parseValueChange(text: String?, inner: String?) -> HomipiValueChange? {
        guard let cleaned = clean(text) else { return nil }
        let pct = first(#"([0-9.]+%)"#, in: cleaned) ?? ""
        let amount = money(cleaned)
        let innerLower = (inner ?? "").lowercased()
        let isIncrease = !(innerLower.contains("color:red") || innerLower.contains("icon-down"))
        return HomipiValueChange(amount: amount, percent: pct,
                                 isIncrease: isIncrease, text: cleaned)
    }

    // MARK: Tables

    /// Land-Registry sale history: 6 columns — index, price, date, tenure, new
    /// build, value change.
    public static func parseSaleHistory(html: String) -> [HomipiSale] {
        guard let body = tbody(afterMarker: "Sale Price", in: html) else { return [] }
        var out: [HomipiSale] = []
        for cells in rows(inTbody: body) where cells.count >= 6 {
            out.append(HomipiSale(
                index: Int(cells[0]) ?? out.count + 1,
                price: money(cells[1]),
                date: cells[2],
                tenure: cells[3],
                newBuild: cells[4],
                valueChange: cells[5]))
        }
        return out
    }

    /// Reported-crime breakdown plus the headline total and radius from the
    /// section's intro sentence.
    public static func parseCrime(html: String) -> HomipiCrime? {
        guard let total = first(#"Total\s+([0-9]+)\s+crime incidents"#, in: html).flatMap({ Int($0) })
        else { return nil }
        let radiusRaw = first(#"Reported within\s+(.*?)<"#, in: html) ?? "the area"
        let radius = stripTags(radiusRaw)
        var byType: [HomipiCrime.Row] = []
        if let body = tbody(afterMarker: "Crime Type", in: html) {
            for cells in rows(inTbody: body) where cells.count >= 2 {
                if let n = Int(cells[1]) { byType.append(.init(type: cells[0], count: n)) }
            }
        }
        return HomipiCrime(total: total, radiusText: radius, byType: byType)
    }

    /// Census-2011 area statistics: 5 columns — area, population, males,
    /// females, household accommodations.
    public static func parseAreaStats(html: String) -> [HomipiAreaStat] {
        guard let body = tbody(afterMarker: "Census 2011", in: html) else { return [] }
        var out: [HomipiAreaStat] = []
        for cells in rows(inTbody: body) where cells.count >= 5 {
            out.append(HomipiAreaStat(area: cells[0], population: cells[1],
                                      males: cells[2], females: cells[3],
                                      households: cells[4]))
        }
        return out
    }

    /// The first `<tbody>…</tbody>` that appears after `marker` in the document.
    private static func tbody(afterMarker marker: String, in html: String) -> String? {
        guard let m = html.range(of: marker) else { return nil }
        guard let open = html.range(of: "<tbody>", range: m.upperBound..<html.endIndex),
              let close = html.range(of: "</tbody>", range: open.upperBound..<html.endIndex)
        else { return nil }
        return String(html[open.upperBound..<close.lowerBound])
    }

    /// Each `<tr>`'s cells (`<td>`/`<th>`), tags stripped, within a tbody.
    private static func rows(inTbody body: String) -> [[String]] {
        captures(#"<tr[^>]*>(.*?)</tr>"#, in: body, group: 1, dotAll: true).map { row in
            captures(#"<t[dh][^>]*>(.*?)</t[dh]>"#, in: row, group: 1, dotAll: true)
                .map(stripTags)
        }
    }

    // MARK: - Field helpers

    /// nil for empty / "-" placeholders, otherwise the trimmed text.
    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty, t != "-" else { return nil }
        return t
    }

    /// First pound figure in a string: "£345,000" / "£345,000 - £384,000" → 345000.
    private static func money(_ s: String?) -> Int? {
        guard let s, let digits = first(#"£\s*([0-9,]+)"#, in: s) else { return nil }
        return Int(digits.replacingOccurrences(of: ",", with: ""))
    }

    /// Lower/upper pound figures of a "£a - £b" range.
    private static func moneyBounds(_ s: String?) -> (lower: Int?, upper: Int?) {
        guard let s else { return (nil, nil) }
        let nums = captures(#"£\s*([0-9,]+)"#, in: s, group: 1)
            .compactMap { Int($0.replacingOccurrences(of: ",", with: "")) }
        if nums.count >= 2 { return (nums.first, nums.last) }
        return (nums.first, nums.first)
    }

    /// First integer in a string: "52" / "52.00 sq. m" → 52.
    private static func intValue(_ s: String?) -> Int? {
        guard let s, let digits = first(#"([0-9]+)"#, in: s) else { return nil }
        return Int(digits)
    }

    /// Build era from the "New Build" line, e.g. "No (Built btw 1967-1975)" →
    /// "1967-1975".
    private static func buildEra(_ s: String?) -> String? {
        guard let s else { return nil }
        return first(#"([0-9]{4}\s*-\s*[0-9]{4}|[0-9]{4})"#, in: s)
    }

    private static func newBuild(_ s: String?) -> Bool? {
        guard let t = clean(s)?.lowercased() else { return nil }
        if t.hasPrefix("yes") { return true }
        if t.hasPrefix("no") { return false }
        return nil
    }

    // MARK: - Tag & regex utilities

    /// Strip tags and decode the handful of entities Homipi emits, collapsing
    /// whitespace to single spaces.
    static func stripTags(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ",
                                       options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&pound;": "£",
                        "&#163;": "£", "&apos;": "'", "&#39;": "'",
                        "&quot;": "\"", "&lt;": "<", "&gt;": ">"]
        for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
        return t.replacingOccurrences(of: #"\s+"#, with: " ",
                                      options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All captures of `group` for `pattern` over `text`.
    private static func captures(_ pattern: String, in text: String,
                                 group: Int = 1, dotAll: Bool = false) -> [String] {
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let r = $0.range(at: group)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    /// First capture of `group` for `pattern`, if any.
    private static func first(_ pattern: String, in text: String,
                              group: Int = 1, dotAll: Bool = false) -> String? {
        captures(pattern, in: text, group: group, dotAll: dotAll).first
    }
}
