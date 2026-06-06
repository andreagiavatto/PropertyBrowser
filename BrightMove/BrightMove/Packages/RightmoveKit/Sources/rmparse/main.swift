import Foundation
import RightmoveKit

// Usage: rmparse <file.html> [more.html ...]
// Auto-detects search-results vs property-detail pages, prints a summary of the
// parsed data, and exits non-zero if any file fails to parse. Point it at HTML
// you've saved from different Rightmove searches to validate the parser.

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: rmparse <file.html> [more.html ...]\n".utf8))
    exit(2)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

func oneLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: " ")
     .replacingOccurrences(of: "\r", with: " ")
     .replacingOccurrences(of: "  ", with: " ")
     .trimmingCharacters(in: .whitespaces)
}

var failures = 0

for path in paths {
    let html: String
    do {
        html = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        print("ERROR  \(path): could not read file (\(error))")
        failures += 1
        continue
    }

    switch RightmoveParser.detectKind(html: html) {
    case .searchResults:
        do {
            let page = try RightmoveParser.parseSearchResults(html: html)
            print("SEARCH \(path)")
            let count = page.resultCount?.description ?? "?"
            let pages = page.pagination?.total?.description ?? "?"
            if let loc = page.searchParameters?.locationIdentifier {
                print("  location: \(loc)   results: \(count)   pages: \(pages)   on this page: \(page.properties.count)")
            } else {
                print("  results: \(count)   pages: \(pages)   on this page: \(page.properties.count)")
            }
            print("  \(pad("ID", 10)) \(pad("PRICE", 13)) \(pad("STATUS", 12)) \(pad("UPDATE", 14)) BEDS  ADDRESS")
            for p in page.properties {
                let id = p.listingKey
                let price = p.price?.primaryDisplay ?? p.price?.amount?.description ?? "?"
                let status = p.listingState.rawValue
                let update = p.listingUpdate?.listingUpdateReason ?? "-"
                let beds = p.bedrooms?.description ?? "-"
                let addr = oneLine(p.displayAddress ?? "")
                print("  \(pad(id, 10)) \(pad(price, 13)) \(pad(status, 12)) \(pad(update, 14)) \(pad(beds, 4))  \(addr)")
            }
        } catch {
            print("ERROR  \(path): \(error)")
            failures += 1
        }

    case .propertyDetail:
        do {
            let d = try RightmoveParser.parsePropertyDetail(html: html)
            print("DETAIL \(path)")
            let id = d.propertyID.map(String.init) ?? "?"
            let price = d.prices?.primaryPrice ?? "?"
            let qualifier = d.prices?.displayPriceQualifier.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            print("  id: \(id)   price: \(price)\(qualifier)   state: \(d.listingState.rawValue)")
            let tagList = (d.tags ?? []).joined(separator: ", ")
            print("  status: published=\(d.status?.published.map(String.init) ?? "?") archived=\(d.status?.archived.map(String.init) ?? "?")   tags: [\(tagList)]")
            print("  address: \(oneLine(d.address?.displayAddress ?? "?"))")
            print("  type: \(d.propertySubType ?? "?")   beds: \(d.bedrooms?.description ?? "-")   baths: \(d.bathrooms?.description ?? "-")")
            print("  listingHistory: \(d.listingHistory?.listingUpdateReason ?? "-")")
            print("  images: \(d.images?.count ?? 0)   floorplans: \(d.floorplans?.count ?? 0)")
            if let lat = d.location?.lat, let lng = d.location?.lng {
                print("  location: \(lat), \(lng)")
            }
            let desc = (d.text?.description ?? "").replacingOccurrences(of: "\n", with: " ")
            if !desc.isEmpty {
                print("  description: \(String(desc.prefix(140)))…")
            }
        } catch {
            print("ERROR  \(path): \(error)")
            failures += 1
        }

    case .unknown:
        print("SKIP   \(path): no __NEXT_DATA__ or __PAGE_MODEL found (Cloudflare challenge page?)")
        failures += 1
    }
    print("")
}

exit(failures == 0 ? 0 : 1)
