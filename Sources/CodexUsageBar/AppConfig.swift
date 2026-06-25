import Foundation

struct AppConfig {
    let codexHome: URL
    let refreshInterval: TimeInterval
    let modelPrices: [String: ModelPrice]

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

        return AppConfig(
            codexHome: codexHome,
            refreshInterval: refreshInterval,
            modelPrices: modelPrices
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

private struct FileConfig: Decodable {
    let codexHome: String?
    let refreshIntervalSeconds: TimeInterval?
    let modelPrices: [String: ModelPrice]?
}
