import Foundation
import SQLite3
import XCTest
@testable import CodexUsageBar

final class CodexUsageStoreTests: XCTestCase {
    private var codexHome: URL!
    private let now = Date(timeIntervalSince1970: 1_791_626_400)

    override func setUpWithError() throws {
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: codexHome)
    }

    func testLoadsLargeThreadIndexWithoutStallingOrCountingDuplicatePaths() throws {
        let rollout = try writeRollout([context(), event()])
        try createIndex(rollout: rollout, rowCount: 2_000)

        let snapshot = try store().loadSnapshot(now: now)

        XCTAssertEqual(snapshot.today.calls, 1)
        XCTAssertEqual(snapshot.today.totalTokens, 1_100_000)
    }

    func testWeeklyOnlyPlanUsesWeeklyLimitAndClearsEarlierFiveHourWindow() throws {
        let rollout = try writeRollout([
            context(),
            event(date: now.addingTimeInterval(-60), limits: [
                "primary": limit(percent: 20, minutes: 300),
                "secondary": limit(percent: 30, minutes: 10_080),
            ]),
            event(limits: [
                "limit_id": "codex",
                "primary": limit(percent: 54, minutes: 10_080),
                "secondary": NSNull(),
            ]),
        ])
        try createIndex(rollout: rollout)

        let snapshot = try store().loadSnapshot(now: now)

        XCTAssertNil(snapshot.primaryLimit)
        XCTAssertEqual(snapshot.weeklyLimit?.usedPercent, 54)
        XCTAssertEqual(snapshot.weeklyLimit?.windowMinutes, 10_080)
    }

    func testReachedPrimaryLimitOnWeeklyOnlyPlanMarksWeeklyWindowFull() throws {
        let rollout = try writeRollout([
            context(),
            event(date: now.addingTimeInterval(-60), limits: [
                "limit_id": "codex",
                "primary": limit(percent: 54, minutes: 10_080),
            ]),
            event(limits: ["limit_id": "codex", "rate_limit_reached_type": "primary"]),
        ])
        try createIndex(rollout: rollout)

        let snapshot = try store().loadSnapshot(now: now)

        XCTAssertNil(snapshot.primaryLimit)
        XCTAssertEqual(snapshot.weeklyLimit?.usedPercent, 100)
    }

    func testOlderDualWindowPlanAndExpiredLimitsStillLoad() throws {
        var primary = limit(percent: 20, minutes: 300)
        primary["resets_at"] = now.addingTimeInterval(-60).timeIntervalSince1970
        let rollout = try writeRollout([context(), event(limits: [
            "primary": primary,
            "secondary": limit(percent: 30, minutes: 10_080),
        ])])
        try createIndex(rollout: rollout)

        let snapshot = try store().loadSnapshot(now: now)

        XCTAssertEqual(snapshot.primaryLimit?.usedPercent, 0)
        XCTAssertEqual(snapshot.primaryLimit?.resetsAt, now.addingTimeInterval(17_940))
        XCTAssertEqual(snapshot.weeklyLimit?.usedPercent, 30)
    }

    func testOtherModelLimitDoesNotReplaceCodexPlanLimits() throws {
        let rollout = try writeRollout([
            context(),
            event(date: now.addingTimeInterval(-60), limits: [
                "limit_id": "codex",
                "primary": limit(percent: 20, minutes: 300),
                "secondary": limit(percent: 30, minutes: 10_080),
            ]),
            event(limits: [
                "limit_id": "codex_spark",
                "primary": limit(percent: 90, minutes: 300),
            ]),
        ])
        try createIndex(rollout: rollout)

        let snapshot = try store().loadSnapshot(now: now)

        XCTAssertEqual(snapshot.primaryLimit?.usedPercent, 20)
        XCTAssertEqual(snapshot.weeklyLimit?.usedPercent, 30)
    }

    func testLoadsJSONLinesWithWhitespaceAroundKeys() throws {
        let rollout = try writeRollout([context(), event()], spaced: true)
        try createIndex(rollout: rollout)

        let snapshot = try store().loadSnapshot(now: now)

        XCTAssertEqual(snapshot.today.calls, 1)
        XCTAssertEqual(snapshot.latestModel, "gpt-6.1-sol")
    }

    func testRefreshReadsAppendedUsageOnceIncludingPartialLines() throws {
        let rollout = try writeRollout([context(), event()])
        try createIndex(rollout: rollout)
        let usageStore = store()
        XCTAssertEqual(try usageStore.loadSnapshot(now: now).today.calls, 1)
        XCTAssertEqual(try usageStore.loadSnapshot(now: now).today.calls, 1)

        let data = try JSONSerialization.data(withJSONObject: event())
        let split = data.count / 2
        let handle = try FileHandle(forWritingTo: rollout)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data.prefix(split))
        XCTAssertEqual(try usageStore.loadSnapshot(now: now).today.calls, 1)
        try handle.write(contentsOf: data.suffix(data.count - split) + Data([0x0A]))

        XCTAssertEqual(try usageStore.loadSnapshot(now: now).today.calls, 2)
        XCTAssertEqual(try usageStore.loadSnapshot(now: now).today.calls, 2)
    }

    func testMissingDatabaseReportsErrorWithoutCreatingDatabase() throws {
        XCTAssertThrowsError(try store().loadSnapshot(now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("state_5.sqlite").path))
    }

    func testMalformedDatabaseReportsSQLiteError() throws {
        try Data("not a database".utf8).write(to: codexHome.appendingPathComponent("state_5.sqlite"))
        XCTAssertThrowsError(try store().loadSnapshot(now: now)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Could not read Codex state database"))
        }
    }

    func testCurrentModelPricesProduceAPIEquivalentEstimates() throws {
        let cases: [(String, Double)] = [
            ("gpt-6-astra", 10.50),
            ("gpt-6.1-sol", 2.05),
            ("gpt-6-sol", 2.10),
            ("gpt-6-luna", 0.105),
            ("gpt-5.6-sol", 4.20),
            ("gpt-5.6-terra", 2.30),
            ("gpt-5.6-luna", 0.23),
            ("gpt-5.6", 5.75), // Preserve the legacy identifier's prior estimate.
            ("gpt-5.2-codex", 2.3625),
            ("gpt-5.1-codex-mini", 0.3375),
        ]
        // 500K uncached + 500K cached input, and 100K output, at published standard rates.
        for (model, expectedCost) in cases {
            let rollout = try writeRollout([context(model: model), event()])
            try createIndex(rollout: rollout)
            let snapshot = try store().loadSnapshot(now: now)
            XCTAssertEqual(snapshot.today.estimatedCost, expectedCost, accuracy: 0.000001, model)
        }
    }

    func testCacheWritesUseSeparatePriceWithoutCountingInputTwice() throws {
        let rollout = try writeRollout([context(), event(cacheWrites: 100_000)])
        try createIndex(rollout: rollout)
        let snapshot = try store().loadSnapshot(now: now)
        // 400K regular input ($0.80), 500K cache reads ($0.05),
        // 100K cache writes ($0.25), and 100K output ($1.00).
        XCTAssertEqual(snapshot.today.estimatedCost, 2.10, accuracy: 0.000001)
    }

    func testExistingCustomPricesDecodeWithoutCacheWritePrice() throws {
        let price = try JSONDecoder().decode(ModelPrice.self, from: Data(
            #"{"inputPerMillion":3,"cachedInputPerMillion":0.3,"outputPerMillion":12}"#.utf8
        ))
        XCTAssertEqual(price.inputPerMillion, 3)
        XCTAssertNil(price.cacheWriteInputPerMillion)
    }

    private func store() -> CodexUsageStore {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return CodexUsageStore(config: AppConfig(
            codexHome: codexHome,
            refreshInterval: 60,
            modelPrices: AppConfig.defaultModelPrices(),
            leaderboard: nil
        ), calendar: calendar)
    }

    private func context(model: String = "gpt-6.1-sol") -> [String: Any] {
        ["type": "turn_context", "payload": ["model": model]]
    }

    private func limit(percent: Double, minutes: Int) -> [String: Any] {
        [
            "used_percent": percent,
            "window_minutes": minutes,
            "resets_at": now.addingTimeInterval(86_400).timeIntervalSince1970,
        ]
    }

    private func event(date: Date? = nil, limits: [String: Any]? = nil, cacheWrites: Int = 0) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": ISO8601DateFormatter().string(from: date ?? now),
            "payload": [
                "type": "token_count",
                "info": ["last_token_usage": [
                    "input_tokens": 1_000_000,
                    "cached_input_tokens": 500_000,
                    "cache_write_input_tokens": cacheWrites,
                    "output_tokens": 100_000,
                    "total_tokens": 1_100_000,
                ]],
                "rate_limits": limits ?? [:],
            ],
        ]
    }

    private func writeRollout(_ objects: [[String: Any]], spaced: Bool = false) throws -> URL {
        let url = codexHome.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        var data = Data()
        for object in objects {
            let line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            if spaced {
                let text = try XCTUnwrap(String(data: line, encoding: .utf8))
                data.append(Data(text.replacingOccurrences(of: "\":", with: "\": ").utf8))
            } else {
                data.append(line)
            }
            data.append(0x0A)
        }
        try data.write(to: url)
        return url
    }

    private func createIndex(rollout: URL, rowCount: Int = 1) throws {
        let databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close(db) }
        let path = rollout.path.replacingOccurrences(of: "'", with: "''")
        let timestamp = Int(now.timeIntervalSince1970)
        let query = """
        drop table if exists threads;
        create table threads (rollout_path text, model text, updated_at integer, recency_at integer);
        with recursive rows(n) as (select 1 union all select n + 1 from rows where n < \(rowCount))
        insert into threads select '\(path)', 'gpt-6.1-sol', \(timestamp), \(timestamp) from rows;
        """
        XCTAssertEqual(sqlite3_exec(db, query, nil, nil, nil), SQLITE_OK)
    }
}
