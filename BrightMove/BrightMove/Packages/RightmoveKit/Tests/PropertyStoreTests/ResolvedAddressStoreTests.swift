import XCTest
@testable import PropertyStore

@MainActor
final class ResolvedAddressStoreTests: XCTestCase {

    private func makeStore() throws -> ResolvedAddressStore {
        try ResolvedAddressStore.inMemory()
    }

    private func candidate(_ address: String, score: Double, uprn: String? = nil)
        -> StoredCandidate {
        StoredCandidate(address: address, postcode: "SW2 5SG", uprn: uprn,
                        score: score, matchedSignals: ["floor area 84 m²"],
                        streetViewURLString: "https://maps.google.com/maps?q=&layer=c&cbll=51,0")
    }

    func testUpsertAutoSavesTopAsUnconfirmed() throws {
        let store = try makeStore()
        let ra = store.upsert(propertyID: 1, candidates: [
            candidate("10, Acre Lane, London", score: 0.93, uprn: "100"),
            candidate("12, Acre Lane, London", score: 0.40, uprn: "102"),
        ])
        XCTAssertEqual(ra.resolvedAddress, "10, Acre Lane, London")
        XCTAssertEqual(ra.uprn, "100")
        XCTAssertEqual(ra.confirmation, .unconfirmed)
        XCTAssertEqual(ra.candidates.count, 2)
    }

    func testLookupRoundTripsCandidates() throws {
        let store = try makeStore()
        store.upsert(propertyID: 7, candidates: [candidate("1 High St", score: 0.8)])
        let found = try XCTUnwrap(store.lookup(propertyID: 7))
        XCTAssertEqual(found.candidates.first?.address, "1 High St")
        XCTAssertEqual(found.candidates.first?.matchedSignals, ["floor area 84 m²"])
        XCTAssertNotNil(found.candidates.first?.streetViewURL)
    }

    func testUpsertIsIdempotentByPropertyID() throws {
        let store = try makeStore()
        store.upsert(propertyID: 1, candidates: [candidate("A", score: 0.5)])
        store.upsert(propertyID: 1, candidates: [candidate("B", score: 0.6)])
        // Still a single row; latest candidates win.
        XCTAssertEqual(store.lookup(propertyID: 1)?.candidates.first?.address, "B")
    }

    func testConfirmCommitsChoiceAndPersists() throws {
        let store = try makeStore()
        store.upsert(propertyID: 1, candidates: [
            candidate("10, Acre Lane, London", score: 0.93, uprn: "100"),
            candidate("12, Acre Lane, London", score: 0.40, uprn: "102"),
        ])
        let chosen = candidate("12, Acre Lane, London", score: 0.40, uprn: "102")
        store.confirm(propertyID: 1, choosing: chosen)

        let ra = try XCTUnwrap(store.lookup(propertyID: 1))
        XCTAssertEqual(ra.confirmation, .confirmed)
        XCTAssertEqual(ra.resolvedAddress, "12, Acre Lane, London")
        XCTAssertEqual(ra.uprn, "102")
        XCTAssertNotNil(ra.confirmedAt)
    }

    func testConfirmedAddressSurvivesReResolve() throws {
        let store = try makeStore()
        store.upsert(propertyID: 1, candidates: [candidate("10, Acre Lane", score: 0.9, uprn: "100")])
        store.confirm(propertyID: 1,
                      choosing: candidate("10, Acre Lane", score: 0.9, uprn: "100"))

        // Re-resolving later must not overwrite the user's confirmed choice.
        store.upsert(propertyID: 1, candidates: [candidate("99, Wrong Rd", score: 0.99, uprn: "999")])
        let ra = try XCTUnwrap(store.lookup(propertyID: 1))
        XCTAssertEqual(ra.confirmation, .confirmed)
        XCTAssertEqual(ra.resolvedAddress, "10, Acre Lane")
        XCTAssertEqual(ra.candidates.first?.address, "99, Wrong Rd") // list still refreshes
    }
}
