import Foundation

/// Top-level entry points for turning Rightmove HTML into typed models.
public enum RightmoveParser {

    private static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    // MARK: Search results

    private struct NextDataRoot: Decodable {
        let props: Props
        struct Props: Decodable {
            let pageProps: PageProps
            struct PageProps: Decodable {
                let searchResults: SearchResultsPage
            }
        }
    }

    /// Parses a Rightmove search-results page (`__NEXT_DATA__`).
    public static func parseSearchResults(html: String) throws -> SearchResultsPage {
        let json = try HTMLExtractor.nextData(in: html)
        guard let data = json.data(using: .utf8) else {
            throw RightmoveParseError.unexpectedShape("__NEXT_DATA__ was not valid UTF-8")
        }
        let root = try makeDecoder().decode(NextDataRoot.self, from: data)
        return root.props.pageProps.searchResults
    }

    // MARK: Property detail

    private struct PageModelWrapper: Decodable {
        let data: String      // a flatted-encoded JSON string
    }

    /// Parses a Rightmove property-detail page (`window.__PAGE_MODEL`).
    public static func parsePropertyDetail(html: String) throws -> PropertyDetail {
        let objectText = try HTMLExtractor.bracedObject(in: html, after: "window.__PAGE_MODEL")
        guard let wrapperData = objectText.data(using: .utf8) else {
            throw RightmoveParseError.unexpectedShape("__PAGE_MODEL was not valid UTF-8")
        }
        let wrapper = try makeDecoder().decode(PageModelWrapper.self, from: wrapperData)

        let graph = try Flatted.parse(wrapper.data)
        guard let root = graph as? NSDictionary else {
            throw RightmoveParseError.unexpectedShape("flatted root was not an object")
        }
        guard let propertyData = root["propertyData"] else {
            throw RightmoveParseError.missingKey("propertyData")
        }
        let detailData = try JSONSerialization.data(withJSONObject: propertyData)
        return try makeDecoder().decode(PropertyDetail.self, from: detailData)
    }

    // MARK: Convenience

    public enum PageKind { case searchResults, propertyDetail, unknown }

    /// Best-effort detection of which kind of page a blob of HTML is.
    public static func detectKind(html: String) -> PageKind {
        if html.contains("__NEXT_DATA__") { return .searchResults }
        if html.contains("window.__PAGE_MODEL") { return .propertyDetail }
        return .unknown
    }
}
