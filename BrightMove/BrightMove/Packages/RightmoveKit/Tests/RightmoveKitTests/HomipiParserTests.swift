import XCTest
@testable import RightmoveKit

final class HomipiParserTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "html", subdirectory: "Fixtures"
        ) else {
            XCTFail("Missing fixture \(name).html")
            throw RightmoveParseError.markerNotFound(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sampleReport() throws -> HomipiReport {
        let html = try fixture("homipi-detail")
        let url = URL(string: "https://www.homipi.co.uk/property/london/sw4-7eu/15-felmersham-close/")!
        return HomipiParser.parseDetail(html: html, url: url)
    }

    // MARK: - URL building & slug

    func testPropertySlug() {
        XCTAssertEqual(HomipiParser.propertySlug(fromAddress: "15, Felmersham Close"),
                       "15-felmersham-close")
        XCTAssertEqual(HomipiParser.propertySlug(fromAddress: "Flat 7, Ascot Court, Clapham Park Road"),
                       "flat-7-ascot-court-clapham-park-road")
        XCTAssertEqual(HomipiParser.propertySlug(fromAddress: "16A, Haselrigge Road"),
                       "16a-haselrigge-road")
        // Punctuation Homipi elides rather than hyphenates.
        XCTAssertEqual(HomipiParser.propertySlug(fromAddress: "Flat D, 2, St. John's Road"),
                       "flat-d-2-st-johns-road")
        XCTAssertNil(HomipiParser.propertySlug(fromAddress: "   "))
        XCTAssertNil(HomipiParser.propertySlug(fromAddress: nil))
    }

    func testPostcodePageURL() {
        XCTAssertEqual(HomipiParser.postcodePageURL(postcode: "SW4 7EU")?.absoluteString,
                       "https://www.homipi.co.uk/house-prices/postcode/sw4-7eu/")
        XCTAssertEqual(HomipiParser.postcodePageURL(postcode: "  n8 7ra ")?.absoluteString,
                       "https://www.homipi.co.uk/house-prices/postcode/n8-7ra/")
        XCTAssertNil(HomipiParser.postcodePageURL(postcode: "   "))
    }

    func testPostcodePageURLPaginated() {
        XCTAssertEqual(HomipiParser.postcodePageURL(postcode: "N8 7LA", page: 3)?.absoluteString,
                       "https://www.homipi.co.uk/house-prices/postcode/n8-7la/?page=3")
        // page 1 stays unqualified.
        XCTAssertEqual(HomipiParser.postcodePageURL(postcode: "N8 7LA", page: 1)?.absoluteString,
                       "https://www.homipi.co.uk/house-prices/postcode/n8-7la/")
    }

    // MARK: - Pagination & neighbourhood path segment

    func testLastPageNumber() throws {
        // The dense N8 7LA postcode page (95 properties) links 10 pages.
        XCTAssertEqual(HomipiParser.lastPageNumber(inPostcodeHTML: try fixture("homipi-postcode-n8")), 10)
        // An unpaginated page reports 1.
        XCTAssertEqual(HomipiParser.lastPageNumber(inPostcodeHTML: "<html>no pages</html>"), 1)
    }

    func testDiscoverHandlesNeighbourhoodSegment() throws {
        // N8 URLs carry an extra `/crouch-end/` neighbourhood segment between
        // city and postcode; last-component matching must still resolve them.
        let html = try fixture("homipi-postcode-n8")
        XCTAssertEqual(
            HomipiParser.discoverDetailURL(inPostcodeHTML: html, matchingSlug: "152-middle-lane")?.absoluteString,
            "https://www.homipi.co.uk/property/london/crouch-end/n8-7la/152-middle-lane/")
    }

    func testDiscoverDetailURL() {
        let html = """
        <h2><a href="https://www.homipi.co.uk/property/london/sw4-7eu/21-felmersham-close/">21</a></h2>
        <h2><a href="/property/london/sw4-7eu/15-felmersham-close/" title="x">15</a></h2>
        <h2><a href="/property/london/sw4-7eu/18-felmersham-close/">18</a></h2>
        """
        XCTAssertEqual(
            HomipiParser.discoverDetailURL(inPostcodeHTML: html, matchingSlug: "15-felmersham-close")?.absoluteString,
            "https://www.homipi.co.uk/property/london/sw4-7eu/15-felmersham-close/")
        // Absolute href carried through untouched.
        XCTAssertEqual(
            HomipiParser.discoverDetailURL(inPostcodeHTML: html, matchingSlug: "21-felmersham-close")?.absoluteString,
            "https://www.homipi.co.uk/property/london/sw4-7eu/21-felmersham-close/")
        XCTAssertNil(
            HomipiParser.discoverDetailURL(inPostcodeHTML: html, matchingSlug: "99-nowhere-road"))
    }

    // MARK: - Postcode listing (no detail fetch)

    /// Listing variant that carries a headline `Homipi Price Estimate` and a
    /// value-change line, parsed straight from the postcode page.
    func testParseListingEstimateVariant() throws {
        let html = try fixture("homipi-postcode-n12")
        let r = try XCTUnwrap(
            HomipiParser.parseListing(inPostcodeHTML: html, matchingSlug: "56-churchfield-avenue"))
        XCTAssertEqual(r.detailURL.absoluteString,
                       "https://www.homipi.co.uk/property/london/n12-0nt/56-churchfield-avenue/")
        XCTAssertEqual(r.estimate, 372_000)
        XCTAssertNil(r.priceLower)
        XCTAssertNil(r.priceUpper)
        XCTAssertEqual(r.lastSoldPrice, 340_000)
        XCTAssertEqual(r.lastSoldDate, "7 Oct 2016")
        XCTAssertEqual(r.propertyType, "Flat")
        XCTAssertEqual(r.valueChange?.amount, 32_000)
        XCTAssertEqual(r.valueChange?.percent, "9.4%")
        XCTAssertEqual(r.valueChange?.isIncrease, true)
        // Point estimate drives the valuation range directly.
        XCTAssertEqual(r.valueRange, MoneyRange(lower: 372_000, mid: 372_000, upper: 372_000))

        // The postcode page's page-level area facts are folded into the listing
        // report (no detail fetch): reported crime and Census area stats.
        let crime = try XCTUnwrap(r.crime)
        XCTAssertEqual(crime.total, 7)
        XCTAssertEqual(crime.radiusText, "1 mile")
        XCTAssertEqual(crime.byType.count, 4)
        XCTAssertEqual(crime.byType.first, .init(type: "Anti-social behaviour", count: 4))
        XCTAssertEqual(crime.byType.map(\.count).reduce(0, +), 7)

        XCTAssertEqual(r.areaStats.count, 2)
        XCTAssertEqual(r.areaStats.first?.area, "District: N12")
        XCTAssertEqual(r.areaStats.first?.population, "28,757")
        XCTAssertEqual(r.areaStats.first?.households, "11,462")
        XCTAssertEqual(r.areaStats.last?.area, "Area: N")

        // Still not on the postcode page: per-property sale history.
        XCTAssertTrue(r.saleHistory.isEmpty)
    }

    /// Listing variant for a property Homipi only brackets: a `Price Range` +
    /// `Estimate Confidence`, with no point estimate. The valuation range falls
    /// back to the range midpoint.
    func testParseListingRangeVariant() throws {
        let html = try fixture("homipi-postcode-n12")
        let r = try XCTUnwrap(
            HomipiParser.parseListing(inPostcodeHTML: html, matchingSlug: "10-churchfield-avenue"))
        XCTAssertNil(r.estimate)
        XCTAssertEqual(r.priceLower, 420_000)
        XCTAssertEqual(r.priceUpper, 475_000)
        XCTAssertEqual(r.confidence, "High")
        XCTAssertEqual(r.lastSoldPrice, 420_000)
        XCTAssertEqual(r.lastSoldDate, "27 Jul 2018")
        XCTAssertEqual(r.propertyType, "Flat")
        XCTAssertEqual(r.tenure, "Leasehold")
        XCTAssertEqual(r.valueRange, MoneyRange(lower: 420_000, mid: 447_500, upper: 475_000))
    }

    func testParseListingMissReturnsNil() throws {
        let html = try fixture("homipi-postcode-n12")
        XCTAssertNil(HomipiParser.parseListing(inPostcodeHTML: html, matchingSlug: "99-nowhere-road"))
    }

    /// Regression: a resolved address carries a trailing postcode (and sometimes
    /// a locality) that Homipi's URL slug omits, so the resolved slug is *longer*
    /// than the page's. Matching must treat the page slug as a hyphen-delimited
    /// prefix — otherwise the property never matches on any page and the report
    /// falsely shows "unavailable".
    func testParseListingMatchesSlugWithTrailingPostcode() throws {
        let html = try fixture("homipi-postcode-n12")
        let r = try XCTUnwrap(
            HomipiParser.parseListing(inPostcodeHTML: html,
                                      matchingSlug: "10-churchfield-avenue-n12-0nt"))
        // Resolves to the same listing as the bare "10-churchfield-avenue".
        XCTAssertEqual(r.detailURL.absoluteString,
                       "https://www.homipi.co.uk/property/london/n12-0nt/10-churchfield-avenue/")
        XCTAssertEqual(r.priceLower, 420_000)
        XCTAssertEqual(r.priceUpper, 475_000)
    }

    /// Regression (real case): an EPC-resolved address carries a sub-building in
    /// front ("Ground Floor Flat") and a locality behind ("North Finchley"),
    /// neither of which is in Homipi's bare `10-churchfield-avenue` slug. The page
    /// slug's tokens must still be found as a contiguous run inside the resolved
    /// slug.
    func testParseListingMatchesSlugWithLeadingSubBuildingAndLocality() throws {
        let html = try fixture("homipi-postcode-n12")
        let r = try XCTUnwrap(
            HomipiParser.parseListing(
                inPostcodeHTML: html,
                matchingSlug: "ground-floor-flat-10-churchfield-avenue-north-finchley"))
        XCTAssertEqual(r.detailURL.absoluteString,
                       "https://www.homipi.co.uk/property/london/n12-0nt/10-churchfield-avenue/")
        XCTAssertEqual(r.priceLower, 420_000)
    }

    /// The hyphen boundary must stop "10-…" being matched by a shorter "1-…"
    /// number that happens to share the street.
    func testParseListingPrefixRespectsHyphenBoundary() throws {
        let html = """
        <a href="/property/london/n12-0nt/10-churchfield-avenue/" title="View Property Details">x</a>
        <label class="css-label-a"> Price Range <strong>£420,000 - £475,000</strong></label>
        """
        // "1-churchfield-avenue…" must NOT match the "10-churchfield-avenue" link.
        XCTAssertNil(HomipiParser.parseListing(inPostcodeHTML: html,
                                               matchingSlug: "1-churchfield-avenue-n12-0nt"))
    }

    // MARK: - Detail valuation block

    func testParseValuation() throws {
        let r = try sampleReport()
        XCTAssertEqual(r.estimate, 384_000)
        XCTAssertEqual(r.priceLower, 345_000)
        XCTAssertEqual(r.priceUpper, 384_000)
        XCTAssertEqual(r.confidence, "High")
        XCTAssertEqual(r.lastSoldPrice, 345_000)
        XCTAssertEqual(r.lastSoldDate, "25 Mar 2020")

        XCTAssertEqual(r.valueChange?.amount, 39_000)
        XCTAssertEqual(r.valueChange?.percent, "11.3%")
        XCTAssertEqual(r.valueChange?.isIncrease, true)
        XCTAssertEqual(r.valueChange?.text, "£39,000 - 11.3%")
    }

    func testValueRangeForProvider() throws {
        let range = try sampleReport().valueRange
        XCTAssertEqual(range, MoneyRange(lower: 345_000, mid: 384_000, upper: 384_000))
    }

    /// Regression: Homipi pairs `css-label-a` with extra classes on its rows
    /// (e.g. `class="css-label-a dotted-bottom-border"`). The label matcher must
    /// treat `css-label-a` as one class among a list, not require it to be the
    /// whole attribute — otherwise every valuation field silently parses as nil.
    func testParseLabelRowsWithAdditionalClasses() {
        let html = """
        <div class="row">
        <label class="css-label-a dotted-bottom-border"> Homipi Price Estimate \
        <a href="/privacy/" class="btn_listing"><i class="icon-info-4"></i></a>\
        <strong>£372,000</strong></label>
        <label class="css-label-a dotted-bottom-border"> Price Range \
        <strong>£420,000 - £475,000</strong></label>
        <label class="css-label-a dotted-bottom-border">Estimate Confidence \
        <strong>High</strong></label>
        <label class="css-label-a dotted-bottom-border"> Last Sold Price \
        <strong>£420,000</strong></label>
        </div>
        """
        let url = URL(string: "https://www.homipi.co.uk/property/x/")!
        let r = HomipiParser.parseDetail(html: html, url: url)
        XCTAssertEqual(r.estimate, 372_000)
        XCTAssertEqual(r.priceLower, 420_000)
        XCTAssertEqual(r.priceUpper, 475_000)
        XCTAssertEqual(r.confidence, "High")
        XCTAssertEqual(r.lastSoldPrice, 420_000)
    }

    // MARK: - Detail facts

    func testParseFacts() throws {
        let r = try sampleReport()
        XCTAssertEqual(r.propertyType, "Flat")
        XCTAssertEqual(r.tenure, "Leasehold")
        XCTAssertEqual(r.floorAreaSqM, 52)
        XCTAssertEqual(r.epcCurrent, "D / 63")
        XCTAssertEqual(r.epcPotential, "D / 66")
        XCTAssertEqual(r.councilTaxRate, "£1,291")
        XCTAssertEqual(r.councilTaxBand, "B")
        XCTAssertEqual(r.buildEra, "1967-1975")
        XCTAssertEqual(r.newBuild, false)
        XCTAssertEqual(r.floodRisk, "Very Low")
        XCTAssertEqual(r.localAuthority, "Lambeth")
    }

    // MARK: - Tables

    func testParseSaleHistory() throws {
        let sales = try sampleReport().saleHistory
        XCTAssertEqual(sales.count, 4)
        XCTAssertEqual(sales.first?.index, 1)
        XCTAssertEqual(sales.first?.price, 345_000)
        XCTAssertEqual(sales.first?.date, "25 Mar 2020")
        XCTAssertEqual(sales.first?.tenure, "Leasehold")
        XCTAssertEqual(sales.first?.valueChange, "91.7%")
        XCTAssertEqual(sales.last?.price, 110_500)
        XCTAssertEqual(sales.last?.valueChange, "n/a")
    }

    func testParseCrime() throws {
        let crime = try XCTUnwrap(sampleReport().crime)
        XCTAssertEqual(crime.total, 13)
        XCTAssertEqual(crime.radiusText, "1 mile")
        XCTAssertEqual(crime.byType.count, 5)
        XCTAssertEqual(crime.byType.first, .init(type: "Anti-social behaviour", count: 5))
        XCTAssertEqual(crime.byType.map(\.count).reduce(0, +), 13)
    }

    func testParseAreaStats() throws {
        let stats = try sampleReport().areaStats
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.first?.area, "District: SW4")
        XCTAssertEqual(stats.first?.population, "40,539")
        XCTAssertEqual(stats.first?.households, "17,438")
        XCTAssertEqual(stats.last?.area, "Area: SW")
    }

    // MARK: - Challenge detection

    /// Regression: Cloudflare injects its `challenge-platform` script (and
    /// Turnstile) into *successful* pages, so that substring must NOT be treated
    /// as a bot wall — otherwise every real fetch is rejected and the report
    /// always shows "unavailable".
    func testSuccessfulPageWithChallengePlatformScriptIsNotFlagged() {
        let html = """
        <html><head>
        <script src="https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/g/scripts/jsd/main.js"></script>
        <title>House Prices in N12 0NT, London - Homipi</title>
        </head><body><h1>House Prices in N12 0NT</h1></body></html>
        """
        XCTAssertNil(HomipiClient.challengeReason(html: html, status: 200))
    }

    /// An actual interstitial is still detected.
    func testRealChallengePageIsFlagged() {
        let html = "<html><head><title>Just a moment...</title></head><body>_cf_chl_opt</body></html>"
        XCTAssertNotNil(HomipiClient.challengeReason(html: html, status: 200))
    }

    /// Blocking status codes are still flagged regardless of body.
    func testBlockingStatusCodesAreFlagged() {
        XCTAssertNotNil(HomipiClient.challengeReason(html: "<html></html>", status: 403))
        XCTAssertNotNil(HomipiClient.challengeReason(html: "<html></html>", status: 503))
        XCTAssertNil(HomipiClient.challengeReason(html: "<html></html>", status: 200))
    }

    // MARK: - Robustness

    func testEmptyHTMLDegradesNotCrashes() {
        let url = URL(string: "https://www.homipi.co.uk/x/")!
        let r = HomipiParser.parseDetail(html: "<html><body>nothing</body></html>", url: url)
        XCTAssertNil(r.estimate)
        XCTAssertNil(r.valueRange)
        XCTAssertNil(r.crime)
        XCTAssertTrue(r.saleHistory.isEmpty)
        XCTAssertTrue(r.areaStats.isEmpty)
    }
}
