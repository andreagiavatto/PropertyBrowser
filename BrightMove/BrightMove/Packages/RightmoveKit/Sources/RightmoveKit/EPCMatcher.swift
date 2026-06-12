import Foundation

/// Pure, network-free address matching: parse the street from a Rightmove
/// `displayAddress`, filter EPC certificates to that street, and rank the
/// houses on it against the listing's floor area, type, and room count.
///
/// Everything here operates on primitives so it unit-tests without the app
/// layer (`FloorArea`, `CLGeocoder`, SwiftData all live above this).

// MARK: - Street name parsing

public enum StreetName {

    /// Unit/sub-dwelling prefixes that are never a street on their own.
    private static let unitWords = [
        "flat", "apartment", "apt", "unit", "room", "studio", "maisonette", "penthouse",
    ]

    /// Pull the street out of a Rightmove `displayAddress`.
    ///
    /// Examples:
    /// - "Acre Lane, London"            → "Acre Lane"
    /// - "Flat 2, Acre Lane, London"    → "Acre Lane"
    /// - "12 Acre Lane, London SW2"     → "Acre Lane"
    /// - "Flat 2 Acre Lane, London"     → "Acre Lane"
    /// - "Brixton Hill, London SW2"     → "Brixton Hill"
    public static func parse(from displayAddress: String?) -> String? {
        guard let raw = displayAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let segments = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }

        // Skip leading segments that are *only* a unit token ("Flat 2", "3").
        for segment in segments {
            if isPureUnitToken(segment) { continue }
            let cleaned = stripLeadingUnitAndNumber(from: segment)
            let stripped = stripTrailingPostcode(from: cleaned)
            let final = stripped.trimmingCharacters(in: .whitespaces)
            if !final.isEmpty { return final }
        }
        return nil
    }

    /// True for a segment that is purely a unit designator or bare number,
    /// e.g. "Flat 2", "Apartment 5B", "3", "12A".
    private static func isPureUnitToken(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        if lower.range(of: #"^\d+[a-z]?$"#, options: .regularExpression) != nil { return true }
        let unitAlt = unitWords.joined(separator: "|")
        let pattern = "^(\(unitAlt))\\s*\\d*[a-z]?$"
        return lower.range(of: pattern, options: [.regularExpression]) != nil
    }

    /// Strip a leading inline unit prefix and/or house number from a street
    /// segment: "Flat 2 Acre Lane" → "Acre Lane", "12 Acre Lane" → "Acre Lane".
    private static func stripLeadingUnitAndNumber(from segment: String) -> String {
        var s = segment
        let unitAlt = unitWords.joined(separator: "|")
        // Leading "<unit> <num> " prefix.
        if let r = s.range(of: "^(\(unitAlt))\\s+\\d+[a-z]?\\s+",
                           options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        // Leading house number "12 " / "12A " (but not if it's the whole token).
        if let r = s.range(of: #"^\d+[a-z]?\s+"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        return s
    }

    /// Drop a trailing UK postcode token (outcode or full) left on a segment,
    /// e.g. "London SW2" handled upstream, but "Acre Lane SW2 5SG" → "Acre Lane".
    private static func stripTrailingPostcode(from segment: String) -> String {
        let pattern = #"\s+[A-Z]{1,2}\d[A-Z\d]?(\s*\d[A-Z]{2})?$"#
        guard let r = segment.range(of: pattern, options: [.regularExpression]) else {
            return segment
        }
        var s = segment
        s.removeSubrange(r)
        return s
    }

    // MARK: comparison

    /// Lower-cased, de-punctuated, whitespace-collapsed form for substring
    /// comparison against an EPC address line.
    static func normalise(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = String(lowered.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return mapped.split(separator: " ").joined(separator: " ")
    }

    /// Common road-type abbreviations ⇄ full forms, applied only to the final
    /// token so "St Johns Road" (Saint) is never mangled.
    private static let roadTypeFull: [String: String] = [
        "rd": "road", "st": "street", "ave": "avenue", "av": "avenue",
        "ln": "lane", "dr": "drive", "cl": "close", "ct": "court",
        "pl": "place", "gdns": "gardens", "cres": "crescent", "sq": "square",
        "ter": "terrace", "wy": "way", "gr": "grove",
    ]

    /// Variants of the parsed street to test against an EPC address: the street
    /// itself, plus final-token expanded and abbreviated forms.
    static func matchVariants(of street: String) -> Set<String> {
        let base = normalise(street)
        var variants: Set<String> = [base]
        var tokens = base.split(separator: " ").map(String.init)
        guard let last = tokens.last else { return variants }

        if let full = roadTypeFull[last] {                 // "acre ln" → "acre lane"
            tokens[tokens.count - 1] = full
            variants.insert(tokens.joined(separator: " "))
        } else if let abbr = roadTypeFull.first(where: { $0.value == last })?.key {
            tokens[tokens.count - 1] = abbr               // "acre lane" → "acre ln"
            variants.insert(tokens.joined(separator: " "))
        }
        return variants
    }

    /// Does this EPC address line sit on the given street?
    static func address(_ epcAddress: String, isOn street: String) -> Bool {
        let hay = normalise(epcAddress)
        return matchVariants(of: street).contains { !$0.isEmpty && hay.contains($0) }
    }
}

// MARK: - Scoring

public struct ScoredCandidate: Equatable, Sendable {
    public let certificate: EPCCertificate
    /// 0…1, normalised over whichever signals were available.
    public let score: Double
    /// Human-readable reasons, for the candidate row UI.
    public let matchedSignals: [String]
}

public enum EPCMatcher {

    /// Narrow a page of search *summaries* down to the few worth fetching full
    /// detail for: filter to the listing's outcode and street, keep the latest
    /// certificate per address, and cap the count (detail is one request each).
    ///
    /// This runs before any detail fetch precisely because summaries carry no
    /// floor area / type / rooms — those only arrive from the detail endpoint.
    public static func shortlist(
        _ results: [EPCSearchResult],
        street: String?,
        outcode: String?,
        limit: Int = 20
    ) -> [EPCSearchResult] {
        var filtered = results
        if let outcode, !outcode.isEmpty {
            filtered = filtered.filter { postcode($0.postcode, isIn: outcode) }
        }
        if let street, !street.isEmpty {
            filtered = filtered.filter {
                guard let a = $0.address else { return false }
                return StreetName.address(a, isOn: street)
            }
        }

        // Latest certificate per distinct address.
        var best: [String: EPCSearchResult] = [:]
        for r in filtered {
            let key = StreetName.normalise(r.address ?? r.certificateNumber)
            if let existing = best[key] {
                if (r.registrationDate ?? .distantPast) > (existing.registrationDate ?? .distantPast) {
                    best[key] = r
                }
            } else {
                best[key] = r
            }
        }

        return Array(best.values)
            .sorted { ($0.registrationDate ?? .distantPast) > ($1.registrationDate ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Rank EPC certificates for a listing.
    /// - Parameters:
    ///   - floorAreaSqm: only the *real* OCR area (pass `nil` for the
    ///     `isApproximate` price-derived fallback — it's circular).
    ///   - areaTolerance: candidates whose EPC area differs by more than this
    ///     fraction are dropped (only when both areas are known).
    public static func rank(
        certificates: [EPCCertificate],
        street: String?,
        floorAreaSqm: Double?,
        bedrooms: Int?,
        propertySubType: String?,
        outcode: String? = nil,
        areaTolerance: Double = 0.10,
        limit: Int = 5
    ) -> [ScoredCandidate] {

        // 0. Outcode filter. The API's `address` search isn't geographically
        // scoped, so a street name can match other towns; pin results back to the
        // listing's outcode when we have one.
        let inArea: [EPCCertificate]
        if let outcode, !outcode.isEmpty {
            inArea = certificates.filter { postcode($0.postcode, isIn: outcode) }
        } else {
            inArea = certificates
        }

        // 1. Street filter (skipped when we couldn't parse a street).
        let onStreet: [EPCCertificate]
        if let street, !street.isEmpty {
            onStreet = inArea.filter {
                guard let a = $0.address else { return false }
                return StreetName.address(a, isOn: street)
            }
        } else {
            onStreet = inArea
        }

        // 2. Latest certificate per address.
        let deduped = latestPerAddress(onStreet)

        // 3. Score.
        let rmType = TypeProfile(rightmoveSubType: propertySubType)
        var scored: [ScoredCandidate] = []
        for cert in deduped {
            var weighted: [(score: Double, weight: Double)] = []
            var signals: [String] = []

            // Area (strongest).
            if let ocr = floorAreaSqm, ocr > 0, let epc = cert.totalFloorArea, epc > 0 {
                let delta = abs(epc - ocr) / ocr
                if delta > areaTolerance { continue } // hard drop
                let s = max(0, 1 - delta / areaTolerance)
                weighted.append((s, 0.6))
                signals.append(String(format: "floor area %.0f m² vs %.0f m² (%.0f%%)",
                                      epc, ocr, delta * 100))
            }

            // Type / built-form.
            let epcType = TypeProfile(epcPropertyType: cert.propertyType, builtForm: cert.builtForm)
            if let ts = rmType.score(against: epcType) {
                weighted.append((ts.score, 0.3))
                signals.append(ts.label)
            }

            // Habitable rooms vs bedrooms.
            if let beds = bedrooms, let rooms = cert.habitableRooms {
                let rs = roomScore(bedrooms: beds, habitableRooms: rooms)
                weighted.append((rs, 0.1))
                signals.append("\(rooms) habitable rooms ≈ \(beds) beds")
            }

            guard !weighted.isEmpty else { continue }
            let totalWeight = weighted.reduce(0) { $0 + $1.weight }
            let score = weighted.reduce(0) { $0 + $1.score * $1.weight } / totalWeight
            scored.append(ScoredCandidate(certificate: cert, score: score, matchedSignals: signals))
        }

        // 4. Rank: score desc, newest cert as tiebreak.
        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return ($0.certificate.lodgementDate ?? .distantPast)
                     > ($1.certificate.lodgementDate ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Strip a postcode to bare uppercase alphanumerics. Handles the API quirk of
    /// returning a `+` in place of the space (e.g. "M20+4AP" → "M204AP").
    private static func normalisePostcode(_ s: String) -> String {
        String(s.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    /// The outcode (postal district) of a UK postcode, e.g. "N14 5AB" → "N14".
    /// UK incodes are always 3 chars (digit + two letters), so the outcode is the
    /// normalised postcode minus its last three characters.
    static func outcode(of postcode: String?) -> String? {
        guard let p = postcode else { return nil }
        let raw = normalisePostcode(p)
        guard raw.count > 3 else { return nil }
        return String(raw.dropLast(3))
    }

    /// Whether an EPC postcode sits within the given outcode (case/space-insensitive).
    static func postcode(_ epcPostcode: String?, isIn outcode: String) -> Bool {
        guard let oc = self.outcode(of: epcPostcode) else { return false }
        return oc == normalisePostcode(outcode)
    }

    /// Keep the most recently lodged certificate for each distinct address.
    static func latestPerAddress(_ certs: [EPCCertificate]) -> [EPCCertificate] {
        var best: [String: EPCCertificate] = [:]
        for cert in certs {
            let key = StreetName.normalise(cert.address ?? cert.lmkKey ?? UUID().uuidString)
            if let existing = best[key] {
                let a = cert.lodgementDate ?? .distantPast
                let b = existing.lodgementDate ?? .distantPast
                if a > b { best[key] = cert }
            } else {
                best[key] = cert
            }
        }
        return Array(best.values)
    }

    /// EPC habitable rooms ≈ bedrooms + reception rooms (kitchens usually
    /// excluded). Reward the plausible band, fall off outside it.
    static func roomScore(bedrooms: Int, habitableRooms: Int) -> Double {
        let diff = habitableRooms - bedrooms
        switch diff {
        case 0...3:  return 1.0
        case -1, 4:  return 0.5
        default:     return 0.0
        }
    }
}

// MARK: - Type classification

/// Normalised property type, derived from either a Rightmove `propertySubType`
/// or an EPC `property-type` + `built-form`, so the two can be compared.
struct TypeProfile: Equatable {
    enum Family { case house, flat, unknown }
    enum Form { case detached, semiDetached, midTerrace, endTerrace, unknown }

    let family: Family
    let form: Form

    init(family: Family, form: Form) { self.family = family; self.form = form }

    init(rightmoveSubType raw: String?) {
        let s = (raw ?? "").lowercased()
        if s.isEmpty { family = .unknown; form = .unknown; return }
        if s.contains("flat") || s.contains("apartment")
            || s.contains("maisonette") || s.contains("studio") {
            family = .flat
        } else {
            family = .house
        }
        form = Self.parseForm(s)
    }

    init(epcPropertyType type: String?, builtForm: String?) {
        let t = (type ?? "").lowercased()
        if t.contains("flat") || t.contains("maisonette") {
            family = .flat
        } else if t.isEmpty {
            family = .unknown
        } else {
            family = .house // House, Bungalow, Park home
        }
        form = Self.parseForm((builtForm ?? "").lowercased())
    }

    private static func parseForm(_ s: String) -> Form {
        if s.contains("semi") { return .semiDetached }
        if s.contains("detached") { return .detached }
        if s.contains("end") && s.contains("terrace") { return .endTerrace }
        if s.contains("terrace") || s.contains("mews")
            || s.contains("town house") || s.contains("townhouse") { return .midTerrace }
        return .unknown
    }

    /// Compare to an EPC-derived profile. Returns nil when nothing is known on
    /// either side (so it contributes no weight).
    func score(against epc: TypeProfile) -> (score: Double, label: String)? {
        var parts: [(Double, Double)] = []

        if family != .unknown && epc.family != .unknown {
            parts.append((family == epc.family ? 1 : 0, 0.6))
        }
        if form != .unknown && epc.form != .unknown {
            let f: Double
            if form == epc.form { f = 1 }
            else if isTerrace(form) && isTerrace(epc.form) { f = 0.6 } // mid vs end
            else { f = 0 }
            parts.append((f, 0.4))
        }
        guard !parts.isEmpty else { return nil }
        let w = parts.reduce(0) { $0 + $1.1 }
        let s = parts.reduce(0) { $0 + $1.0 * $1.1 } / w
        return (s, "type \(label(epc))")
    }

    private func isTerrace(_ f: Form) -> Bool { f == .midTerrace || f == .endTerrace }

    private func label(_ epc: TypeProfile) -> String {
        let fam: String
        switch epc.family {
        case .house: fam = "house"; case .flat: fam = "flat"; case .unknown: fam = "?"
        }
        let form: String
        switch epc.form {
        case .detached: form = "detached"; case .semiDetached: form = "semi-detached"
        case .midTerrace: form = "mid-terrace"; case .endTerrace: form = "end-terrace"
        case .unknown: form = ""
        }
        return form.isEmpty ? fam : "\(fam)/\(form)"
    }
}
