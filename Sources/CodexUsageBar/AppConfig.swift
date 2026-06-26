import Foundation

struct AppConfig {
    let codexHome: URL
    let refreshInterval: TimeInterval
    let modelPrices: [String: ModelPrice]
    let leaderboard: LeaderboardConfig?

    var stateDatabaseURL: URL {
        codexHome.appendingPathComponent("state_5.sqlite")
    }

    static func load() throws -> AppConfig {
        let environment = ProcessInfo.processInfo.environment
        let fileConfig = try loadFileConfig(environment: environment)

        let codexHomePath = value(
            environment: environment,
            keys: ["CODEX_USAGE_CODEX_HOME", "CODEX_HOME"],
            fallback: fileConfig?.codexHome
        )

        let codexHome = URL(fileURLWithPath: expandedPath(codexHomePath ?? "~/.codex"))
        let refreshInterval = refreshInterval(environment: environment, fileConfig: fileConfig)
        let modelPrices = defaultModelPrices().merging(fileConfig?.modelPrices ?? [:]) { _, override in
            override
        }
        let leaderboard = try leaderboardConfig(
            environment: environment,
            fileConfig: fileConfig,
            codexHome: codexHome
        )

        return AppConfig(
            codexHome: codexHome,
            refreshInterval: refreshInterval,
            modelPrices: modelPrices,
            leaderboard: leaderboard
        )
    }

    private static func loadFileConfig(environment: [String: String]) throws -> FileConfig? {
        for url in configURLs(environment: environment) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(FileConfig.self, from: data)
        }

        return nil
    }

    private static func configURLs(environment: [String: String]) -> [URL] {
        var urls: [URL] = []

        if let configPath = environment["CODEX_USAGE_CONFIG"], !configPath.isEmpty {
            urls.append(URL(fileURLWithPath: expandedPath(configPath)))
        }

        if let resourceURL = Bundle.main.url(forResource: "config", withExtension: "json") {
            urls.append(resourceURL)
        }

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        urls.append(homeDirectory.appendingPathComponent(".config/codex-usage-bar/config.json"))
        urls.append(homeDirectory.appendingPathComponent(".codex-usage-bar.json"))
        urls.append(URL(fileURLWithPath: "config.json"))

        return urls
    }

    private static func value(
        environment: [String: String],
        keys: [String],
        fallback: String?
    ) -> String? {
        for key in keys {
            if let value = environment[key], !value.isEmpty {
                return value
            }
        }

        return fallback
    }

    private static func refreshInterval(
        environment: [String: String],
        fileConfig: FileConfig?
    ) -> TimeInterval {
        let stringValue = value(
            environment: environment,
            keys: ["CODEX_USAGE_REFRESH_SECONDS"],
            fallback: nil
        )

        if let stringValue, let seconds = TimeInterval(stringValue), seconds >= 15 {
            return seconds
        }

        if let seconds = fileConfig?.refreshIntervalSeconds, seconds >= 15 {
            return seconds
        }

        return 60
    }

    private static func leaderboardConfig(
        environment: [String: String],
        fileConfig: FileConfig?,
        codexHome: URL
    ) throws -> LeaderboardConfig? {
        let urlString = value(
            environment: environment,
            keys: ["CODEX_USAGE_LEADERBOARD_URL"],
            fallback: fileConfig?.leaderboardURL ?? "https://codex-usage-leaderboard.evanss.workers.dev"
        )
        let token = value(
            environment: environment,
            keys: ["CODEX_USAGE_LEADERBOARD_TOKEN"],
            fallback: fileConfig?.leaderboardToken ?? defaultLeaderboardToken
        )
        let teamId = value(
            environment: environment,
            keys: ["CODEX_USAGE_LEADERBOARD_TEAM_ID"],
            fallback: fileConfig?.leaderboardTeamId ?? "friends"
        )
        let userId = value(
            environment: environment,
            keys: ["CODEX_USAGE_LEADERBOARD_USER_ID"],
            fallback: fileConfig?.leaderboardUserId ?? stableLeaderboardUserId()
        )
        let displayName = value(
            environment: environment,
            keys: ["CODEX_USAGE_LEADERBOARD_DISPLAY_NAME"],
            fallback: fileConfig?.leaderboardDisplayName ?? defaultLeaderboardDisplayName(codexHome: codexHome)
        )

        guard let urlString, let baseURL = URL(string: urlString),
              let teamId, !teamId.isEmpty,
              let userId, !userId.isEmpty,
              let displayName, !displayName.isEmpty else {
            throw AppConfigError.incompleteLeaderboardConfig
        }

        return LeaderboardConfig(
            baseURL: baseURL,
            token: token,
            teamId: teamId,
            userId: userId,
            displayName: displayName
        )
    }

    private static func stableLeaderboardUserId() -> String {
        let defaults = UserDefaults.standard
        let key = "leaderboardUserId"

        if let existingUserId = defaults.string(forKey: key), !existingUserId.isEmpty {
            return existingUserId
        }

        let userId = UUID().uuidString.lowercased()
        defaults.set(userId, forKey: key)
        return userId
    }

    private static func defaultLeaderboardDisplayName(codexHome: URL) -> String {
        if let codexDisplayName = codexDisplayName(codexHome: codexHome) {
            return codexDisplayName
        }

        let username = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty {
            return username
        }

        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullName.isEmpty {
            return fullName
        }

        return "Codex user"
    }

    private static func codexDisplayName(codexHome: URL) -> String? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else {
            return nil
        }

        let parts = idToken.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = base64URLDecodedData(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        for key in ["name", "preferred_username", "nickname"] {
            if let value = claims[key] as? String,
               let displayName = cleanedDisplayName(value) {
                return displayName
            }
        }

        if let email = claims["email"] as? String,
           let username = email.split(separator: "@").first,
           let displayName = cleanedDisplayName(String(username)) {
            return displayName
        }

        return nil
    }

    private static func cleanedDisplayName(_ value: String) -> String? {
        let displayName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? nil : displayName
    }

    private static func base64URLDecodedData(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingLength = (4 - base64.count % 4) % 4
        if paddingLength > 0 {
            base64 += String(repeating: "=", count: paddingLength)
        }

        return Data(base64Encoded: base64)
    }

    private static let defaultLeaderboardToken = "NlHgoRR63eSUw4nuCItM6t9LUcRzInBG"

    private static func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func defaultModelPrices() -> [String: ModelPrice] {
        [
            "gpt-5.5": ModelPrice(inputPerMillion: 5.00, cachedInputPerMillion: 0.50, outputPerMillion: 30.00),
            "gpt-5.5-pro": ModelPrice(inputPerMillion: 30.00, cachedInputPerMillion: 0, outputPerMillion: 180.00),
            "gpt-5.4": ModelPrice(inputPerMillion: 2.50, cachedInputPerMillion: 0.25, outputPerMillion: 15.00),
            "gpt-5.4-mini": ModelPrice(inputPerMillion: 0.75, cachedInputPerMillion: 0.075, outputPerMillion: 4.50),
            "gpt-5.4-nano": ModelPrice(inputPerMillion: 0.20, cachedInputPerMillion: 0.02, outputPerMillion: 1.25),
            "gpt-5.3-codex": ModelPrice(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14.00),
            "chat-latest": ModelPrice(inputPerMillion: 5.00, cachedInputPerMillion: 0.50, outputPerMillion: 30.00),
        ]
    }
}

struct ModelPrice: Decodable {
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let outputPerMillion: Double
}

struct LeaderboardConfig {
    let baseURL: URL
    let token: String?
    let teamId: String
    let userId: String
    let displayName: String
}

private struct FileConfig: Decodable {
    let codexHome: String?
    let refreshIntervalSeconds: TimeInterval?
    let leaderboardURL: String?
    let leaderboardToken: String?
    let leaderboardTeamId: String?
    let leaderboardUserId: String?
    let leaderboardDisplayName: String?
    let modelPrices: [String: ModelPrice]?
}

enum AppConfigError: LocalizedError {
    case incompleteLeaderboardConfig

    var errorDescription: String? {
        switch self {
        case .incompleteLeaderboardConfig:
            return "Leaderboard config requires URL, team ID, user ID, and display name."
        }
    }
}
