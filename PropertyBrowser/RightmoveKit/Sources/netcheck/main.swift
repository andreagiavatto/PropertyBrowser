import Foundation
import RightmoveKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// netcheck — probe live Rightmove pages and report whether the real embedded
// JSON came back or a Cloudflare / bot-wall challenge did. This is the
// experiment that decides whether plain URLSession works or we need the
// WKWebView fallback.
//
// Usage:
//   netcheck <url> [more urls ...]          probe arbitrary Rightmove URLs
//   netcheck --search "<pasted search url>" fetch + parse a search's first page
//   netcheck --property <id>                fetch + parse a property detail page
//   netcheck --cookie "<cookie header>" …   reuse a browser session (combine with above)
//
// Tip: run once with no --cookie, then again with a Cookie header copied from
// your browser's dev tools, to see whether cookies are what gets you past CF.

func usage() -> Never {
    let text = """
    usage:
      netcheck <url> [more urls ...]
      netcheck --search "<pasted search url>"
      netcheck --property <id>
      netcheck --cookie "<cookie header>" <any of the above>
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

// --- argument parsing ---
var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { usage() }

var cookie: String?
var searchURLString: String?
var propertyID: Int?
var rawURLs: [String] = []

var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "--cookie":
        i += 1
        guard i < args.count else { usage() }
        cookie = args[i]
    case "--search":
        i += 1
        guard i < args.count else { usage() }
        searchURLString = args[i]
    case "--property":
        i += 1
        guard i < args.count, let id = Int(args[i]) else { usage() }
        propertyID = id
    default:
        rawURLs.append(a)
    }
    i += 1
}

let config = RightmoveClientConfig(cookie: cookie)
let client = RightmoveClient(config: config)

if cookie != nil { print("• using supplied Cookie header") }
print("• User-Agent: \(config.userAgent)\n")

func report(label: String, outcome: FetchOutcome) {
    switch outcome {
    case .ok(let html, let status, let bytes):
        let kind = RightmoveParser.detectKind(html: html)
        print("OK         \(label)")
        print("           HTTP \(status), \(bytes) bytes, page kind: \(kind)")
    case .challenged(let status, let reason, let bytes):
        print("CHALLENGED \(label)")
        print("           HTTP \(status), \(bytes) bytes — \(reason)")
    case .httpError(let status, let bytes):
        print("HTTP-ERR   \(label)")
        print("           HTTP \(status), \(bytes) bytes")
    }
}

var hadFailure = false

do {
    // --search: fetch first page and parse a summary
    if let s = searchURLString {
        guard let search = RightmoveSearchURL(string: s), let url = search.pageURL(index: 0) else {
            print("ERROR  could not parse search URL")
            exit(1)
        }
        let outcome = try await client.fetch(url)
        report(label: url.absoluteString, outcome: outcome)
        if case .ok(let html, _, _) = outcome {
            let page = try RightmoveParser.parseSearchResults(html: html)
            print("           parsed: \(page.resultCount?.description ?? "?") results, \(page.properties.count) on page")
            let states = Dictionary(grouping: page.properties, by: { $0.listingState.rawValue })
                .mapValues(\.count).sorted { $0.key < $1.key }
            print("           states: \(states.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        } else {
            hadFailure = true
        }
        print("")
    }

    // --property: fetch detail and parse a summary
    if let id = propertyID {
        guard let url = URL(string: "https://www.rightmove.co.uk/properties/\(id)") else { usage() }
        let outcome = try await client.fetch(url)
        report(label: url.absoluteString, outcome: outcome)
        if case .ok(let html, _, _) = outcome {
            let d = try RightmoveParser.parsePropertyDetail(html: html)
            print("           parsed: id \(d.propertyID.map(String.init) ?? "?"), \(d.prices?.primaryPrice ?? "?"), state=\(d.listingState.rawValue)")
        } else {
            hadFailure = true
        }
        print("")
    }

    // raw URLs
    for raw in rawURLs {
        guard let url = URL(string: raw) else {
            print("ERROR  not a valid URL: \(raw)\n")
            hadFailure = true
            continue
        }
        let outcome = try await client.fetch(url)
        report(label: url.absoluteString, outcome: outcome)
        if case .ok = outcome {} else { hadFailure = true }
        print("")
    }
} catch {
    print("ERROR  \(error)")
    exit(1)
}

if rawURLs.isEmpty && searchURLString == nil && propertyID == nil { usage() }

exit(hadFailure ? 1 : 0)
