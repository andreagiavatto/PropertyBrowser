import Foundation
import Vision
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// Result of a floor-area extraction attempt.
struct FloorArea {
    /// Area in square metres.
    let sqm: Double
    /// True when the value was back-calculated from price/sqft rather than read directly.
    let isApproximate: Bool

    var formatted: String {
        let s = String(format: sqm >= 100 ? "%.0f" : "%.1f", sqm)
        return isApproximate ? "~\(s) m²" : "\(s) m²"
    }
}

/// Extracts floor area from a floorplan image URL using Vision OCR,
/// falling back to a price-per-sqft back-calculation when OCR finds nothing.
enum FloorplanAnalyser {

    // MARK: - Public entry point

    /// Attempt to extract floor area.
    /// - Parameters:
    ///   - floorplanURL: URL of the floorplan image (may be nil).
    ///   - totalPriceGBP: Property price in GBP (used for fallback).
    ///   - pricePerSqFtString: e.g. "£523 sqft" from DetailPrices (used for fallback).
    static func extract(
        floorplanURL: URL?,
        totalPriceGBP: Int? = nil,
        pricePerSqFtString: String? = nil
    ) async -> FloorArea? {
        // 1. Try OCR on the floorplan image.
        if let url = floorplanURL,
           let area = await extractViaOCR(from: url) {
            return area
        }
        // 2. Fall back to price / price-per-sqft back-calculation.
        return fallback(totalPriceGBP: totalPriceGBP, pricePerSqFtString: pricePerSqFtString)
    }

    // MARK: - OCR path

    private static func extractViaOCR(from url: URL) async -> FloorArea? {
        guard let imageData = try? await URLSession.shared.data(from: url).0,
              let cgImage = cgImage(from: imageData) else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let strings = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                let area = largestArea(from: strings)
                continuation.resume(returning: area)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    /// From all recognised strings, find the largest area value (likely the total).
    private static func largestArea(from strings: [String]) -> FloorArea? {
        // Patterns: "85.3 sq m", "85m²", "915 sq ft", "915sqft", "85 sqm", etc.
        // We normalise to m².
        let sqmPattern  = #"(\d{1,4}(?:[.,]\d{1,2})?)\s*(?:sq\.?\s*m(?:etres?)?|m²|sqm)\b"#
        let sqftPattern = #"(\d{3,5}(?:[.,]\d{1,2})?)\s*(?:sq\.?\s*ft|sqft|square\s*feet)\b"#

        var candidates: [Double] = []

        let combined = strings.joined(separator: "\n")

        if let re = try? NSRegularExpression(pattern: sqmPattern, options: .caseInsensitive) {
            let matches = re.matches(in: combined, range: NSRange(combined.startIndex..., in: combined))
            for m in matches {
                if let r = Range(m.range(at: 1), in: combined),
                   let v = Double(combined[r].replacingOccurrences(of: ",", with: ".")) {
                    candidates.append(v)
                }
            }
        }

        // Convert sq ft → m² (1 sq ft = 0.092903 m²)
        if let re = try? NSRegularExpression(pattern: sqftPattern, options: .caseInsensitive) {
            let matches = re.matches(in: combined, range: NSRange(combined.startIndex..., in: combined))
            for m in matches {
                if let r = Range(m.range(at: 1), in: combined),
                   let v = Double(combined[r].replacingOccurrences(of: ",", with: ".")) {
                    candidates.append(v * 0.092903)
                }
            }
        }

        guard let largest = candidates.max(), largest > 5 else { return nil }
        return FloorArea(sqm: largest, isApproximate: false)
    }

    // MARK: - Fallback: price ÷ price-per-sqft

    private static func fallback(totalPriceGBP: Int?, pricePerSqFtString: String?) -> FloorArea? {
        guard let price = totalPriceGBP, price > 0,
              let ppsf = pricePerSqFtString,
              let perSqFt = extractPoundValue(from: ppsf),
              perSqFt > 0 else { return nil }
        let sqft = Double(price) / perSqFt
        let sqm  = sqft * 0.092903
        return FloorArea(sqm: sqm, isApproximate: true)
    }

    private static func extractPoundValue(from s: String) -> Double? {
        // e.g. "£523 sqft" or "523" or "£1,200"
        let digits = s.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        return Double(digits)
    }

    // MARK: - Helpers

    private static func cgImage(from data: Data) -> CGImage? {
#if canImport(AppKit)
        return NSImage(data: data).flatMap { img in
            var rect = CGRect(origin: .zero, size: img.size)
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
#else
        return nil
#endif
    }
}
