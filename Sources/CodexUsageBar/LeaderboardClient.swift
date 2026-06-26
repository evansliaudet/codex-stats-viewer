import Foundation

struct LeaderboardEntry: Decodable {
    let displayName: String
    let todayTokens: Int
    let todayCalls: Int
    let todayEstimatedCost: Double
    let last7DaysTokens: Int
    let last7DaysCalls: Int
    let last7DaysEstimatedCost: Double
    let last30DaysTokens: Int
    let last30DaysCalls: Int
    let last30DaysEstimatedCost: Double
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case displayName
        case todayTokens
        case todayCalls
        case todayEstimatedCost
        case last7DaysTokens
        case last7DaysCalls
        case last7DaysEstimatedCost
        case last30DaysTokens
        case last30DaysCalls
        case last30DaysEstimatedCost
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        todayTokens = try container.decodeIfPresent(Int.self, forKey: .todayTokens) ?? 0
        todayCalls = try container.decodeIfPresent(Int.self, forKey: .todayCalls) ?? 0
        todayEstimatedCost = try container.decodeIfPresent(Double.self, forKey: .todayEstimatedCost) ?? 0
        last7DaysTokens = try container.decodeIfPresent(Int.self, forKey: .last7DaysTokens) ?? 0
        last7DaysCalls = try container.decodeIfPresent(Int.self, forKey: .last7DaysCalls) ?? 0
        last7DaysEstimatedCost = try container.decodeIfPresent(Double.self, forKey: .last7DaysEstimatedCost) ?? 0
        last30DaysTokens = try container.decodeIfPresent(Int.self, forKey: .last30DaysTokens) ?? 0
        last30DaysCalls = try container.decodeIfPresent(Int.self, forKey: .last30DaysCalls) ?? 0
        last30DaysEstimatedCost = try container.decodeIfPresent(Double.self, forKey: .last30DaysEstimatedCost) ?? 0
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

final class LeaderboardClient {
    private let config: LeaderboardConfig
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(config: LeaderboardConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func publish(
        snapshot: CodexUsageSnapshot,
        completion: @escaping (Result<[LeaderboardEntry], Error>) -> Void
    ) {
        let requestBody = LeaderboardSnapshotRequest(
            teamId: config.teamId,
            userId: config.userId,
            displayName: config.displayName,
            todayTokens: snapshot.today.totalTokens,
            todayCalls: snapshot.today.calls,
            todayEstimatedCost: snapshot.today.estimatedCost,
            last7DaysTokens: snapshot.last7Days.totalTokens,
            last7DaysCalls: snapshot.last7Days.calls,
            last7DaysEstimatedCost: snapshot.last7Days.estimatedCost,
            last30DaysTokens: snapshot.last30Days.totalTokens,
            last30DaysCalls: snapshot.last30Days.calls,
            last30DaysEstimatedCost: snapshot.last30Days.estimatedCost
        )

        do {
            var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/snapshot"))
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            if let token = config.token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(requestBody)

            session.dataTask(with: request) { [decoder] data, response, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(LeaderboardClientError.invalidResponse))
                    return
                }

                guard 200..<300 ~= httpResponse.statusCode else {
                    completion(.failure(LeaderboardClientError.httpStatus(httpResponse.statusCode)))
                    return
                }

                guard let data else {
                    completion(.failure(LeaderboardClientError.invalidResponse))
                    return
                }

                do {
                    let response = try decoder.decode(LeaderboardResponse.self, from: data)
                    completion(.success(response.leaderboard))
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }
}

private struct LeaderboardSnapshotRequest: Encodable {
    let teamId: String
    let userId: String
    let displayName: String
    let todayTokens: Int
    let todayCalls: Int
    let todayEstimatedCost: Double
    let last7DaysTokens: Int
    let last7DaysCalls: Int
    let last7DaysEstimatedCost: Double
    let last30DaysTokens: Int
    let last30DaysCalls: Int
    let last30DaysEstimatedCost: Double
}

private struct LeaderboardResponse: Decodable {
    let leaderboard: [LeaderboardEntry]
}

private enum LeaderboardClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid leaderboard response."
        case .httpStatus(let statusCode):
            return "Leaderboard request failed with HTTP \(statusCode)."
        }
    }
}
