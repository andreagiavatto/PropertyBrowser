import XCTest
import RightmoveKit
@testable import PropertyStore

@MainActor
final class TrackingStoreTests: XCTestCase {

    private func makeStore() throws -> TrackingStore {
        try TrackingStore.inMemory()
    }

    private func snap(_ id: Int, _ amount: Int?, _ state: ListingState, at t: Double) -> TrackedSnapshot {
        TrackedSnapshot(propertyID: id, priceAmount: amount,
                        priceDisplay: amount.map { "£\($0)" }, state: state,
                        capturedAt: Date(timeIntervalSince1970: t),
                        displayAddress: "1 Test St", bedrooms: 2)
    }

    func testPinCreatesFirstSeenEvent() throws {
        let store = try makeStore()
        store.pin(snap(1, 500_000, .available, at: 0))

        XCTAssertTrue(store.isPinned(id: 1))
        let pin = try XCTUnwrap(store.pinnedProperty(id: 1))
        XCTAssertEqual(pin.currentPriceAmount, 500_000)
        XCTAssertEqual(pin.events.count, 1)
        XCTAssertEqual(pin.events.first?.kind, .firstSeen)
    }

    func testPinIsIdempotent() throws {
        let store = try makeStore()
        store.pin(snap(1, 500_000, .available, at: 0))
        store.pin(snap(1, 500_000, .available, at: 10))
        XCTAssertEqual(store.allPins().count, 1)
        XCTAssertEqual(store.pinnedProperty(id: 1)?.events.count, 1)
    }

    func testApplyRecordsPriceDropThenStatusChange() throws {
        let store = try makeStore()
        store.pin(snap(1, 500_000, .available, at: 0))

        let priceEvents = store.apply(snap(1, 475_000, .available, at: 100))
        XCTAssertEqual(priceEvents.count, 1)
        XCTAssertEqual(priceEvents.first?.kind, .priceChange)
        XCTAssertTrue(priceEvents.first?.isPriceReduction ?? false)

        let statusEvents = store.apply(snap(1, 475_000, .underOffer, at: 200))
        XCTAssertEqual(statusEvents.count, 1)
        XCTAssertEqual(statusEvents.first?.kind, .statusChange)
        XCTAssertEqual(statusEvents.first?.toState, .underOffer)

        let pin = try XCTUnwrap(store.pinnedProperty(id: 1))
        XCTAssertEqual(pin.currentPriceAmount, 475_000)
        XCTAssertEqual(pin.currentState, .underOffer)
        XCTAssertEqual(pin.events.count, 3)   // firstSeen + price + status
    }

    func testApplyNoChangeRecordsNothingButTouchesChecked() throws {
        let store = try makeStore()
        store.pin(snap(1, 500_000, .available, at: 0))
        let events = store.apply(snap(1, 500_000, .available, at: 999))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(store.pinnedProperty(id: 1)?.lastCheckedAt, Date(timeIntervalSince1970: 999))
        XCTAssertEqual(store.pinnedProperty(id: 1)?.events.count, 1)
    }

    func testApplyOnUnpinnedIsNoOp() throws {
        let store = try makeStore()
        XCTAssertTrue(store.apply(snap(42, 1, .available, at: 0)).isEmpty)
        XCTAssertFalse(store.isPinned(id: 42))
    }

    func testUnpinRemovesEverything() throws {
        let store = try makeStore()
        store.pin(snap(1, 500_000, .available, at: 0))
        store.apply(snap(1, 475_000, .available, at: 100))
        store.unpin(id: 1)
        XCTAssertFalse(store.isPinned(id: 1))
        XCTAssertTrue(store.recentChanges().isEmpty)
    }

    func testRecentChangesAcrossPinsNewestFirst() throws {
        let store = try makeStore()
        store.pin(snap(1, 500_000, .available, at: 0))
        store.pin(snap(2, 300_000, .available, at: 0))
        store.apply(snap(1, 475_000, .available, at: 100))
        store.apply(snap(2, 280_000, .available, at: 200))

        let feed = store.recentChanges()
        XCTAssertEqual(feed.first?.date, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(feed.allSatisfy { $0.kind == .priceChange || $0.kind == .firstSeen })
    }
}
