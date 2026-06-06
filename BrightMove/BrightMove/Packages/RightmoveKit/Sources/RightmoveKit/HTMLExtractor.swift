import Foundation

/// Pulls embedded JSON out of Rightmove HTML pages. Two shapes exist:
///   • Search results — `<script id="__NEXT_DATA__" type="application/json">…</script>`
///   • Property detail — `window.__PAGE_MODEL = { … };`
enum HTMLExtractor {

    /// Returns the raw JSON text inside the `__NEXT_DATA__` script tag.
    static func nextData(in html: String) throws -> String {
        guard let idRange = html.range(of: "id=\"__NEXT_DATA__\"") else {
            throw RightmoveParseError.markerNotFound("__NEXT_DATA__")
        }
        guard let gt = html.range(of: ">", range: idRange.upperBound..<html.endIndex) else {
            throw RightmoveParseError.unterminatedObject("__NEXT_DATA__")
        }
        guard let close = html.range(of: "</script>", range: gt.upperBound..<html.endIndex) else {
            throw RightmoveParseError.unterminatedObject("__NEXT_DATA__")
        }
        return String(html[gt.upperBound..<close.lowerBound])
    }

    /// Returns the JSON object literal assigned after `marker`
    /// (e.g. "window.__PAGE_MODEL"), found by brace-matching with
    /// string/escape awareness so braces inside string values are ignored.
    static func bracedObject(in html: String, after marker: String) throws -> String {
        guard let markerRange = html.range(of: marker) else {
            throw RightmoveParseError.markerNotFound(marker)
        }
        let chars = Array(html[markerRange.upperBound...])
        guard let start = chars.firstIndex(of: "{") else {
            throw RightmoveParseError.unterminatedObject(marker)
        }

        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(chars[start...i])
                    }
                }
            }
            i += 1
        }
        throw RightmoveParseError.unterminatedObject(marker)
    }
}
