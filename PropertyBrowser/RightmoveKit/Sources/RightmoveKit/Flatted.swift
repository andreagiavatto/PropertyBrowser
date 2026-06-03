import Foundation

/// Decoder for the `flatted` (npm) wire format used by Rightmove's
/// `window.__PAGE_MODEL.data`. The payload is a JSON array of "known" values:
/// the root is at index 0, every container's children are integer indices into
/// the array, and scalars (string/number/bool/null) sit as standalone entries.
/// Verified against real pages: every dictionary value and array element is an
/// integer index, so resolution is unambiguous.
///
/// Reference-type containers (NSMutableDictionary/NSMutableArray) are used so
/// that shared sub-objects resolve to a single instance and cycles terminate.
enum Flatted {

    /// Parses a flatted JSON string and returns the rehydrated object graph
    /// (NSDictionary / NSArray / scalar). Root is the value at index 0.
    static func parse(_ jsonString: String) throws -> Any {
        guard let data = jsonString.data(using: .utf8) else {
            throw RightmoveParseError.unexpectedShape("data string was not valid UTF-8")
        }
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let array = raw as? [Any] else {
            throw RightmoveParseError.unexpectedShape("flatted payload was not a top-level array")
        }
        guard !array.isEmpty else {
            throw RightmoveParseError.unexpectedShape("flatted payload was empty")
        }
        let memo = NSMutableDictionary()
        return resolve(0, in: array, memo: memo)
    }

    private static func resolve(_ index: Int, in array: [Any], memo: NSMutableDictionary) -> Any {
        let key = index as NSNumber
        if let cached = memo[key] { return cached }
        guard index >= 0, index < array.count else { return NSNull() }

        let entry = array[index]

        if let dict = entry as? [String: Any] {
            let out = NSMutableDictionary()
            memo[key] = out                       // placeholder first → cycles resolve to `out`
            for (k, v) in dict {
                if let childIdx = childIndex(v) {
                    out[k] = resolve(childIdx, in: array, memo: memo)
                } else {
                    out[k] = v
                }
            }
            return out
        }

        if let list = entry as? [Any] {
            let out = NSMutableArray()
            memo[key] = out
            for v in list {
                if let childIdx = childIndex(v) {
                    out.add(resolve(childIdx, in: array, memo: memo))
                } else {
                    out.add(v)
                }
            }
            return out
        }

        memo[key] = entry
        return entry
    }

    /// Container children are always non-negative integer indices. Booleans are
    /// also NSNumber under JSONSerialization, so they are explicitly excluded.
    private static func childIndex(_ value: Any) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let intValue = number.intValue
        // Reject non-integral values (a literal float child would not be an index).
        guard Double(intValue) == number.doubleValue, intValue >= 0 else { return nil }
        return intValue
    }
}
