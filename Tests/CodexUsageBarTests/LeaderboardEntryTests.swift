import Foundation
import XCTest
@testable import CodexUsageBar

final class LeaderboardEntryTests: XCTestCase {
    func testTokenCountsWithoutReportedCostsHaveUnavailableEstimates() throws {
        let entry = try decode()

        XCTAssertEqual(entry.todayTokens, 30_000_000)
        XCTAssertNil(entry.todayEstimatedCost)
        XCTAssertNil(entry.last7DaysEstimatedCost)
        XCTAssertNil(entry.last30DaysEstimatedCost)
    }

    func testZeroEstimatesWithConsumedTokensAreUnavailable() throws {
        let entry = try decode(costs: [
            "todayEstimatedCost": 0,
            "last7DaysEstimatedCost": 0,
            "last30DaysEstimatedCost": 0,
        ])

        XCTAssertNil(entry.todayEstimatedCost)
        XCTAssertNil(entry.last7DaysEstimatedCost)
        XCTAssertNil(entry.last30DaysEstimatedCost)
    }

    func testReportedPositiveEstimatesArePreservedForEachRange() throws {
        let entry = try decode(costs: [
            "todayEstimatedCost": 12.50,
            "last7DaysEstimatedCost": 30.25,
            "last30DaysEstimatedCost": 60.75,
        ])

        XCTAssertEqual(entry.todayEstimatedCost, 12.50)
        XCTAssertEqual(entry.last7DaysEstimatedCost, 30.25)
        XCTAssertEqual(entry.last30DaysEstimatedCost, 60.75)
    }

    func testReportedZeroEstimatesWithNoUsageRemainZero() throws {
        let entry = try decode(costs: [
            "todayEstimatedCost": 0,
            "last7DaysEstimatedCost": 0,
            "last30DaysEstimatedCost": 0,
        ], tokens: 0)

        XCTAssertEqual(entry.todayEstimatedCost, 0)
        XCTAssertEqual(entry.last7DaysEstimatedCost, 0)
        XCTAssertEqual(entry.last30DaysEstimatedCost, 0)
    }

    func testOlderPayloadDoesNotInventCostsForMissingHistoryRanges() throws {
        let entry = try decode(costs: ["todayEstimatedCost": 12.50])

        XCTAssertEqual(entry.todayEstimatedCost, 12.50)
        XCTAssertNil(entry.last7DaysEstimatedCost)
        XCTAssertNil(entry.last30DaysEstimatedCost)
    }

    func testNullEstimatesAreUnavailable() throws {
        let entry = try decode(costs: [
            "todayEstimatedCost": NSNull(),
            "last7DaysEstimatedCost": NSNull(),
            "last30DaysEstimatedCost": NSNull(),
        ])

        XCTAssertNil(entry.todayEstimatedCost)
        XCTAssertNil(entry.last7DaysEstimatedCost)
        XCTAssertNil(entry.last30DaysEstimatedCost)
    }

    private func decode(costs: [String: Any] = [:], tokens: Int = 30_000_000) throws -> LeaderboardEntry {
        let payload: [String: Any] = [
            "displayName": "Friend",
            "todayTokens": tokens,
            "last7DaysTokens": tokens,
            "last30DaysTokens": tokens,
        ].merging(costs) { _, cost in cost }
        return try JSONDecoder().decode(
            LeaderboardEntry.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }
}
