import Foundation

public enum RightmoveParseError: Error, CustomStringConvertible {
    case markerNotFound(String)
    case unterminatedObject(String)
    case missingKey(String)
    case unexpectedShape(String)

    public var description: String {
        switch self {
        case .markerNotFound(let m): return "Could not find marker '\(m)' in HTML."
        case .unterminatedObject(let m): return "Found '\(m)' but its JSON object was never closed."
        case .missingKey(let k): return "Expected key '\(k)' was missing from the decoded payload."
        case .unexpectedShape(let s): return "Unexpected JSON shape: \(s)."
        }
    }
}
