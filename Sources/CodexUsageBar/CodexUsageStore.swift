import Foundation

struct CodexUsageSnapshot {
    let capturedAt: Date
    let latestEventDate: Date?
    let latestModel: String?
    let primaryLimit: RateLimitSnapshot?
    let weeklyLimit: RateLimitSnapshot?
    let today: CostSummary
    let last7Days: CostSummary
    let last30Days: CostSummary
    let todayBuckets: [UsageBucket]
    let last7DaysBuckets: [UsageBucket]
    let last30DaysBuckets: [UsageBucket]
}

struct RateLimitSnapshot {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
}

struct CostSummary {
    var calls = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var totalTokens = 0
    var estimatedCost = 0.0

    mutating func add(_ usage: TokenUsage, cost: Double) {
        calls += 1
        inputTokens += usage.inputTokens
        cachedInputTokens += usage.cachedInputTokens
        outputTokens += usage.outputTokens
        totalTokens += usage.totalTokens
        estimatedCost += cost
    }
}

struct UsageBucket {
    let startDate: Date
    var summary: CostSummary
}

struct TokenUsage {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
}

private struct SessionFile {
    let path: String
    let model: String?
}

final class CodexUsageStore {
    private let config: AppConfig
    private let calendar: Calendar
    private let isoFormatter: ISO8601DateFormatter
    private let isoFormatterWithoutFractions: ISO8601DateFormatter

    init(config: AppConfig, calendar: Calendar = .current) {
        self.config = config
        self.calendar = calendar

        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        isoFormatterWithoutFractions = ISO8601DateFormatter()
        isoFormatterWithoutFractions.formatOptions = [.withInternetDateTime]
    }

    func loadSnapshot() throws -> CodexUsageSnapshot {
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let last7DaysStart = calendar.date(byAdding: .day, value: -7, to: now)
            ?? now.addingTimeInterval(-7 * 24 * 60 * 60)
        let last30DaysStart = calendar.date(byAdding: .day, value: -30, to: todayStart)
            ?? now.addingTimeInterval(-30 * 24 * 60 * 60)

        let sessionFiles = try recentSessionFiles(startingAt: last30DaysStart)
        var today = CostSummary()
        var last7Days = CostSummary()
        var last30Days = CostSummary()
        var todayBuckets = makeBuckets(startingAt: todayStart, count: 24, component: .hour)
        var last7DaysBuckets = makeBuckets(
            startingAt: calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart,
            count: 7,
            component: .day
        )
        var last30DaysBuckets = makeBuckets(
            startingAt: calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart,
            count: 30,
            component: .day
        )
        let todayBucketIndexes = bucketIndexes(for: todayBuckets)
        let last7DaysBucketIndexes = bucketIndexes(for: last7DaysBuckets)
        let last30DaysBucketIndexes = bucketIndexes(for: last30DaysBuckets)
        var latestEventDate: Date?
        var latestModel: String?
        var primaryLimit: RateLimitSnapshot?
        var weeklyLimit: RateLimitSnapshot?
        var primaryLimitDate: Date?
        var weeklyLimitDate: Date?
        var primaryLimitReachedDate: Date?
        var weeklyLimitReachedDate: Date?

        for sessionFile in sessionFiles {
            parseSessionFile(sessionFile) { event in
                if latestEventDate == nil || event.date > latestEventDate! {
                    latestEventDate = event.date
                    latestModel = event.model
                }

                if let eventPrimaryLimit = event.primaryLimit,
                   primaryLimitDate == nil || event.date > primaryLimitDate! {
                    primaryLimit = eventPrimaryLimit
                    primaryLimitDate = event.date
                }

                if let eventWeeklyLimit = event.weeklyLimit,
                   weeklyLimitDate == nil || event.date > weeklyLimitDate! {
                    weeklyLimit = eventWeeklyLimit
                    weeklyLimitDate = event.date
                }

                if event.reachedPrimaryLimit,
                   primaryLimitReachedDate == nil || event.date > primaryLimitReachedDate! {
                    primaryLimitReachedDate = event.date
                }

                if event.reachedWeeklyLimit,
                   weeklyLimitReachedDate == nil || event.date > weeklyLimitReachedDate! {
                    weeklyLimitReachedDate = event.date
                }

                guard let usage = event.usage else {
                    return
                }

                let cost = estimatedCost(for: usage, model: event.model)

                if event.date >= last30DaysStart {
                    last30Days.add(usage, cost: cost)
                    add(
                        usage,
                        cost: cost,
                        date: event.date,
                        component: .day,
                        buckets: &last30DaysBuckets,
                        indexes: last30DaysBucketIndexes
                    )
                }

                if event.date >= last7DaysStart {
                    last7Days.add(usage, cost: cost)
                    add(
                        usage,
                        cost: cost,
                        date: event.date,
                        component: .day,
                        buckets: &last7DaysBuckets,
                        indexes: last7DaysBucketIndexes
                    )
                }

                if event.date >= todayStart {
                    today.add(usage, cost: cost)
                    add(
                        usage,
                        cost: cost,
                        date: event.date,
                        component: .hour,
                        buckets: &todayBuckets,
                        indexes: todayBucketIndexes
                    )
                }
            }
        }

        if let primaryLimitReachedDate,
           primaryLimitDate == nil || primaryLimitReachedDate > primaryLimitDate! {
            primaryLimit = RateLimitSnapshot(
                usedPercent: 100,
                windowMinutes: primaryLimit?.windowMinutes ?? 300,
                resetsAt: primaryLimit?.resetsAt
            )
        }

        if let weeklyLimitReachedDate,
           weeklyLimitDate == nil || weeklyLimitReachedDate > weeklyLimitDate! {
            weeklyLimit = RateLimitSnapshot(
                usedPercent: 100,
                windowMinutes: weeklyLimit?.windowMinutes ?? 10_080,
                resetsAt: weeklyLimit?.resetsAt
            )
        }

        primaryLimit = resetExpiredLimit(primaryLimit, fallbackWindowMinutes: 300, now: now)
        weeklyLimit = resetExpiredLimit(weeklyLimit, fallbackWindowMinutes: 10_080, now: now)

        return CodexUsageSnapshot(
            capturedAt: now,
            latestEventDate: latestEventDate,
            latestModel: latestModel,
            primaryLimit: primaryLimit,
            weeklyLimit: weeklyLimit,
            today: today,
            last7Days: last7Days,
            last30Days: last30Days,
            todayBuckets: todayBuckets,
            last7DaysBuckets: last7DaysBuckets,
            last30DaysBuckets: last30DaysBuckets
        )
    }

    private func makeBuckets(
        startingAt startDate: Date,
        count: Int,
        component: Calendar.Component
    ) -> [UsageBucket] {
        (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: component, value: offset, to: startDate) else {
                return nil
            }

            return UsageBucket(startDate: date, summary: CostSummary())
        }
    }

    private func bucketIndexes(for buckets: [UsageBucket]) -> [Date: Int] {
        Dictionary(uniqueKeysWithValues: buckets.enumerated().map { index, bucket in
            (bucket.startDate, index)
        })
    }

    private func add(
        _ usage: TokenUsage,
        cost: Double,
        date: Date,
        component: Calendar.Component,
        buckets: inout [UsageBucket],
        indexes: [Date: Int]
    ) {
        guard let bucketStart = calendar.dateInterval(of: component, for: date)?.start,
              let bucketIndex = indexes[bucketStart] else {
            return
        }

        buckets[bucketIndex].summary.add(usage, cost: cost)
    }

    private func recentSessionFiles(startingAt startDate: Date) throws -> [SessionFile] {
        let cutoff = Int(startDate.timeIntervalSince1970)
        let query = """
        select rollout_path, coalesce(model, '')
        from threads
        where rollout_path <> ''
          and (updated_at >= \(cutoff) or recency_at >= \(cutoff))
        order by updated_at desc
        """

        let output = try runSQLite(query: query)
        var seenPaths = Set<String>()
        var sessionFiles: [SessionFile] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let firstColumn = columns.first else {
                continue
            }

            let path = String(firstColumn)
            guard FileManager.default.fileExists(atPath: path), !seenPaths.contains(path) else {
                continue
            }

            seenPaths.insert(path)
            let model = columns.count > 1 && !columns[1].isEmpty ? String(columns[1]) : nil
            sessionFiles.append(SessionFile(path: path, model: model))
        }

        return sessionFiles
    }

    private func runSQLite(query: String) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-separator", "\t", config.stateDatabaseURL.path, query]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorText = String(data: errorData, encoding: .utf8) ?? "sqlite3 failed"
            throw CodexUsageError.sqlite(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private func parseSessionFile(_ sessionFile: SessionFile, onEvent: (ParsedUsageEvent) -> Void) {
        guard let content = try? String(contentsOfFile: sessionFile.path, encoding: .utf8) else {
            return
        }

        var currentModel = sessionFile.model

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""type":"event_msg""#) || line.contains(#""type":"turn_context""#) else {
                continue
            }

            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            if type == "turn_context",
               let payload = object["payload"] as? [String: Any],
               let model = payload["model"] as? String {
                currentModel = model
                continue
            }

            guard type == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let timestamp = date(from: object["timestamp"] as? String) else {
                continue
            }

            let info = payload["info"] as? [String: Any]
            let rateLimits = payload["rate_limits"] as? [String: Any]

            let usage = tokenUsage(from: info?["last_token_usage"] as? [String: Any])
            let event = ParsedUsageEvent(
                date: timestamp,
                model: currentModel ?? sessionFile.model,
                usage: usage,
                primaryLimit: rateLimit(from: rateLimits?["primary"] as? [String: Any]),
                weeklyLimit: rateLimit(from: rateLimits?["secondary"] as? [String: Any]),
                rateLimitReachedType: rateLimits?["rate_limit_reached_type"] as? String
            )

            onEvent(event)
        }
    }

    private func tokenUsage(from dictionary: [String: Any]?) -> TokenUsage? {
        guard let dictionary,
              let inputTokens = intValue(dictionary["input_tokens"]),
              let outputTokens = intValue(dictionary["output_tokens"]),
              let totalTokens = intValue(dictionary["total_tokens"]) else {
            return nil
        }

        return TokenUsage(
            inputTokens: inputTokens,
            cachedInputTokens: intValue(dictionary["cached_input_tokens"]) ?? 0,
            outputTokens: outputTokens,
            totalTokens: totalTokens
        )
    }

    private func rateLimit(from dictionary: [String: Any]?) -> RateLimitSnapshot? {
        guard let dictionary,
              let usedPercent = doubleValue(dictionary["used_percent"]),
              let windowMinutes = intValue(dictionary["window_minutes"]) else {
            return nil
        }

        let resetsAt = doubleValue(dictionary["resets_at"]).map { Date(timeIntervalSince1970: $0) }

        return RateLimitSnapshot(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt
        )
    }

    private func resetExpiredLimit(
        _ limit: RateLimitSnapshot?,
        fallbackWindowMinutes: Int,
        now: Date
    ) -> RateLimitSnapshot? {
        guard let limit else {
            return nil
        }

        guard let resetsAt = limit.resetsAt, resetsAt <= now else {
            return limit
        }

        let windowMinutes = limit.windowMinutes > 0 ? limit.windowMinutes : fallbackWindowMinutes
        let windowDuration = TimeInterval(windowMinutes * 60)
        var nextReset = Date(timeInterval: windowDuration, since: resetsAt)

        while nextReset <= now {
            nextReset = Date(timeInterval: windowDuration, since: nextReset)
        }

        return RateLimitSnapshot(
            usedPercent: 0,
            windowMinutes: windowMinutes,
            resetsAt: nextReset
        )
    }

    private func estimatedCost(for usage: TokenUsage, model: String?) -> Double {
        guard let model,
              let price = config.modelPrices[model] else {
            return 0
        }

        let uncachedInputTokens = max(usage.inputTokens - usage.cachedInputTokens, 0)
        let inputCost = Double(uncachedInputTokens) / 1_000_000 * price.inputPerMillion
        let cachedInputCost = Double(usage.cachedInputTokens) / 1_000_000 * price.cachedInputPerMillion
        let outputCost = Double(usage.outputTokens) / 1_000_000 * price.outputPerMillion

        return inputCost + cachedInputCost + outputCost
    }

    private func date(from string: String?) -> Date? {
        guard let string else {
            return nil
        }

        return isoFormatter.date(from: string) ?? isoFormatterWithoutFractions.date(from: string)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }

        if let number = value as? NSNumber {
            return number.doubleValue
        }

        return nil
    }
}

private struct ParsedUsageEvent {
    let date: Date
    let model: String?
    let usage: TokenUsage?
    let primaryLimit: RateLimitSnapshot?
    let weeklyLimit: RateLimitSnapshot?
    let rateLimitReachedType: String?

    var reachedPrimaryLimit: Bool {
        reachedLimit(named: "primary")
    }

    var reachedWeeklyLimit: Bool {
        reachedLimit(named: "secondary") || reachedLimit(named: "weekly")
    }

    private func reachedLimit(named name: String) -> Bool {
        rateLimitReachedType?.localizedCaseInsensitiveContains(name) ?? false
    }
}

enum CodexUsageError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            return "Could not read Codex state database: \(message)"
        }
    }
}
