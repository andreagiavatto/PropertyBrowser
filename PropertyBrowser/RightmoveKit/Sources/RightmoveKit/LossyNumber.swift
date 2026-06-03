import Foundation

/// A numeric value that may arrive from Rightmove's JSON as an `Int`, a `Double`,
/// or a `String` (their payloads are inconsistent across endpoints — e.g.
/// `resultCount` is a string while `price.amount` is an int). Decoding never
/// throws on a recognisable number, so a single odd field can't fail a whole page.
public struct LossyNumber: Decodable, Equatable, CustomStringConvertible {
    public let int: Int?
    public let double: Double?

    public init(int: Int? = nil, double: Double? = nil) {
        self.int = int
        self.double = double
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            int = i
            double = Double(i)
        } else if let d = try? c.decode(Double.self) {
            double = d
            int = Int(d)
        } else if let s = try? c.decode(String.self) {
            let cleaned = s.filter { $0.isNumber || $0 == "." || $0 == "-" }
            if let d = Double(cleaned) {
                double = d
                int = Int(d)
            } else {
                double = nil
                int = nil
            }
        } else {
            int = nil
            double = nil
        }
    }

    public var description: String {
        if let i = int { return String(i) }
        if let d = double { return String(d) }
        return "nil"
    }
}
