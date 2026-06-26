import AppKit
import Foundation
import Sparkle

final class CodexUsageBarApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusMenu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Loading Codex usage...", action: nil, keyEquivalent: "")
    private let refreshMenuItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
    private let checkForUpdatesMenuItem = NSMenuItem(
        title: "Check for Updates...",
        action: #selector(checkForUpdates),
        keyEquivalent: "u"
    )
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
    private let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
    private let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
    private let resetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private var timer: Timer?
    private var spinnerTimer: Timer?
    private var config: AppConfig?
    private var store: CodexUsageStore?
    private var leaderboardClient: LeaderboardClient?
    private var leaderboardEntries: [LeaderboardEntry] = []
    private var leaderboardError: String?
    private var snapshot: CodexUsageSnapshot?
    private var isRefreshing = false
    private var spinnerIndex = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        rebuildMenu()

        do {
            let config = try AppConfig.load()
            self.config = config
            store = CodexUsageStore(config: config)
            if let leaderboardConfig = config.leaderboard {
                leaderboardClient = LeaderboardClient(config: leaderboardConfig)
            }
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshInterval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            refresh()
        } catch {
            showError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        spinnerTimer?.invalidate()
    }

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.title = "Codex --"
        button.image = codexIcon()
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Codex usage"
        statusItem.menu = statusMenu
        statusMenuItem.isEnabled = false
        refreshMenuItem.target = self
        checkForUpdatesMenuItem.target = self
    }

    private func codexIcon() -> NSImage? {
        let fileManager = FileManager.default
        let bundledURL = Bundle.main.url(forResource: "codex", withExtension: "png")
        let workingDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("codex.png")

        let imageURL = bundledURL ?? (fileManager.fileExists(atPath: workingDirectoryURL.path) ? workingDirectoryURL : nil)
        guard let imageURL, let image = NSImage(contentsOf: imageURL) else {
            return nil
        }

        image.size = NSSize(width: 14, height: 14)
        return image
    }

    private func refresh() {
        guard !isRefreshing, let store else {
            return
        }

        isRefreshing = true
        refreshMenuItem.isEnabled = false
        startRefreshIndicator()

        DispatchQueue.global(qos: .utility).async { [store] in
            let result: Result<CodexUsageSnapshot, Error>

            do {
                let snapshot = try store.loadSnapshot()
                result = .success(snapshot)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishRefresh(result)
            }
        }
    }

    private func finishRefresh(_ result: Result<CodexUsageSnapshot, Error>) {
        isRefreshing = false
        refreshMenuItem.isEnabled = true
        stopRefreshIndicator()

        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            showSnapshot(snapshot)
            publishLeaderboard(snapshot)
        case .failure(let error):
            showError(error)
        }

        rebuildMenu()
    }

    private func startRefreshIndicator() {
        spinnerTimer?.invalidate()
        spinnerIndex = 0
        updateRefreshIndicator()
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updateRefreshIndicator()
        }
    }

    private func stopRefreshIndicator() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
    }

    private func updateRefreshIndicator() {
        let percentageText = percentText(snapshot?.primaryLimit?.usedPercent)
        let spinnerText = spinnerFrames[spinnerIndex % spinnerFrames.count]
        spinnerIndex += 1
        setStatusText("\(percentageText) \(spinnerText)")
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()
        statusMenu.addItem(statusMenuItem)
        statusMenu.addItem(.separator())

        if let snapshot {
            addUsageDetails(snapshot)
        } else {
            let emptyItem = NSMenuItem(title: "No usage loaded", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            statusMenu.addItem(emptyItem)
        }

        if leaderboardClient != nil {
            statusMenu.addItem(.separator())
            addLeaderboardDetails()
        }

        statusMenu.addItem(.separator())
        statusMenu.addItem(refreshMenuItem)
        statusMenu.addItem(checkForUpdatesMenuItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addUsageDetails(_ snapshot: CodexUsageSnapshot) {
        statusMenu.addItem(summaryItem(for: snapshot))
        statusMenu.addItem(.separator())

        if let primaryLimit = snapshot.primaryLimit {
            statusMenu.addItem(textItem("5h reset: \(resetText(for: primaryLimit))", color: .secondaryLabelColor))
        }

        if let weeklyLimit = snapshot.weeklyLimit {
            statusMenu.addItem(textItem("Weekly reset: \(resetText(for: weeklyLimit))", color: .secondaryLabelColor))
        }

        if let latestModel = snapshot.latestModel {
            statusMenu.addItem(textItem("Latest model: \(latestModel)", color: .secondaryLabelColor))
        }

        if let latestEventDate = snapshot.latestEventDate {
            statusMenu.addItem(textItem("Updated: \(relativeFormatter.localizedString(for: latestEventDate, relativeTo: Date()))", color: .secondaryLabelColor))
        }
    }

    private func addLeaderboardDetails() {
        if let leaderboardError {
            statusMenu.addItem(textItem("Leaderboard unavailable: \(leaderboardError)", color: .secondaryLabelColor))
            return
        }

        guard !leaderboardEntries.isEmpty else {
            statusMenu.addItem(textItem("No friends loaded yet", color: .secondaryLabelColor))
            return
        }

        statusMenu.addItem(textItem("Friends today", color: .secondaryLabelColor))
        statusMenu.addItem(leaderboardItem(
            entries: topLeaderboardEntries { $0.todayTokens },
            tokenValue: { $0.todayTokens },
            costValue: { $0.todayEstimatedCost }
        ))

        statusMenu.addItem(textItem("Friends last 7 days", color: .secondaryLabelColor))
        statusMenu.addItem(leaderboardItem(
            entries: topLeaderboardEntries { $0.last7DaysTokens },
            tokenValue: { $0.last7DaysTokens },
            costValue: { $0.last7DaysEstimatedCost }
        ))

        statusMenu.addItem(textItem("Friends last 30 days", color: .secondaryLabelColor))
        statusMenu.addItem(leaderboardItem(
            entries: topLeaderboardEntries { $0.last30DaysTokens },
            tokenValue: { $0.last30DaysTokens },
            costValue: { $0.last30DaysEstimatedCost }
        ))
    }

    private func leaderboardItem(
        entries: [LeaderboardEntry],
        tokenValue: (LeaderboardEntry) -> Int,
        costValue: (LeaderboardEntry) -> Double
    ) -> NSMenuItem {
        let rowHeight: CGFloat = 30
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: CGFloat(entries.count) * rowHeight))

        for (index, entry) in entries.enumerated() {
            let y = CGFloat(entries.count - index - 1) * rowHeight + 6
            view.addSubview(label(
                "\(rankText(for: index)) \(entry.displayName)",
                frame: NSRect(x: 14, y: y, width: 156, height: 18),
                font: .systemFont(ofSize: 13),
                color: .labelColor
            ))
            view.addSubview(label(
                "\(formatted(tokenValue(entry))) tok",
                frame: NSRect(x: 176, y: y, width: 76, height: 18),
                font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                color: .secondaryLabelColor
            ))
            view.addSubview(label(
                formattedCurrency(costValue(entry)),
                frame: NSRect(x: 252, y: y, width: 54, height: 18),
                font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                color: .secondaryLabelColor
            ))
        }

        return viewItem(view)
    }

    private func topLeaderboardEntries(
        by score: (LeaderboardEntry) -> Int
    ) -> [LeaderboardEntry] {
        Array(leaderboardEntries.sorted { lhs, rhs in
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)

            if lhsScore == rhsScore {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

            return lhsScore > rhsScore
        }.prefix(5))
    }

    private func rankText(for index: Int) -> String {
        switch index {
        case 0:
            return "🥇"
        case 1:
            return "🥈"
        case 2:
            return "🥉"
        default:
            return "\(index + 1)."
        }
    }

    private func summaryItem(for snapshot: CodexUsageSnapshot) -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))

        addSummaryMetric(
            title: "5h window",
            value: percentText(snapshot.primaryLimit?.usedPercent),
            x: 14,
            y: 104,
            to: view
        )
        addSummaryMetric(
            title: "Weekly",
            value: percentText(snapshot.weeklyLimit?.usedPercent),
            x: 164,
            y: 104,
            to: view
        )
        addSummaryMetric(
            title: "Today spent",
            value: formattedCurrency(snapshot.today.estimatedCost),
            detail: "\(formatted(snapshot.today.totalTokens)) tokens",
            x: 14,
            y: 56,
            to: view
        )
        addSummaryMetric(
            title: "30 days spent",
            value: formattedCurrency(snapshot.last30Days.estimatedCost),
            detail: "\(formatted(snapshot.last30Days.totalTokens)) tokens",
            x: 164,
            y: 56,
            to: view
        )
        addSummaryMetric(
            title: "Today calls",
            value: formatted(snapshot.today.calls),
            x: 14,
            y: 8,
            to: view
        )
        addSummaryMetric(
            title: "30 days calls",
            value: formatted(snapshot.last30Days.calls),
            x: 164,
            y: 8,
            to: view
        )

        return viewItem(view)
    }

    private func addSummaryMetric(
        title: String,
        value: String,
        detail: String? = nil,
        x: CGFloat,
        y: CGFloat,
        to view: NSView
    ) {
        let titleLabel = label(
            title,
            frame: NSRect(x: x, y: y + 28, width: 140, height: 14),
            font: .systemFont(ofSize: 10, weight: .medium),
            color: .secondaryLabelColor
        )

        let valueLabel = label(
            value,
            frame: NSRect(x: x, y: y + 10, width: 140, height: 18),
            font: .monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            color: .labelColor
        )

        view.addSubview(titleLabel)
        view.addSubview(valueLabel)

        if let detail {
            view.addSubview(label(
                detail,
                frame: NSRect(x: x, y: y - 4, width: 140, height: 13),
                font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                color: .secondaryLabelColor
            ))
        }
    }

    private func textItem(_ text: String, color: NSColor) -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        view.addSubview(label(
            text,
            frame: NSRect(x: 14, y: 5, width: 292, height: 18),
            font: .systemFont(ofSize: 13),
            color: color
        ))
        return viewItem(view)
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func label(
        _ text: String,
        frame: NSRect,
        font: NSFont,
        color: NSColor
    ) -> NSTextField {
        let textField = NSTextField(labelWithString: text)
        textField.frame = frame
        textField.font = font
        textField.textColor = color
        textField.lineBreakMode = .byTruncatingTail
        return textField
    }

    private func showSnapshot(_ snapshot: CodexUsageSnapshot) {
        let primaryText = percentText(snapshot.primaryLimit?.usedPercent)
        let weeklyText = percentText(snapshot.weeklyLimit?.usedPercent)
        setStatusText(primaryText)
        statusItem.button?.toolTip = "Codex usage: \(primaryText) in 5h window, \(weeklyText) weekly"
        statusMenuItem.title = "Codex: 5h \(primaryText) | Weekly \(weeklyText)"
    }

    private func showError(_ error: Error) {
        setStatusText("Codex --")
        statusItem.button?.toolTip = error.localizedDescription
        statusMenuItem.title = error.localizedDescription
    }

    private func publishLeaderboard(_ snapshot: CodexUsageSnapshot) {
        guard let leaderboardClient else {
            return
        }

        leaderboardClient.publish(snapshot: snapshot) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let entries):
                    self?.leaderboardEntries = entries
                    self?.leaderboardError = nil
                case .failure(let error):
                    self?.leaderboardError = error.localizedDescription
                }

                self?.rebuildMenu()
            }
        }
    }

    private func setStatusText(_ text: String) {
        guard let button = statusItem.button else {
            return
        }

        button.attributedTitle = NSAttributedString(
            string: " \(text)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        return percentFormatter.string(from: NSNumber(value: value / 100)) ?? "\(value)%"
    }

    private func resetText(for limit: RateLimitSnapshot) -> String {
        guard let resetsAt = limit.resetsAt else {
            return "--"
        }

        return resetDateFormatter.string(from: resetsAt)
    }

    private func formatted(_ value: Int) -> String {
        let absoluteValue = abs(value)

        if absoluteValue >= 1_000_000 {
            return compactNumber(value, divisor: 1_000_000, suffix: "M")
        }

        if absoluteValue >= 1_000 {
            return compactNumber(value, divisor: 1_000, suffix: "k")
        }

        return numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func compactNumber(_ value: Int, divisor: Double, suffix: String) -> String {
        let scaledValue = Double(value) / divisor
        let roundedValue = (scaledValue * 10).rounded() / 10

        if roundedValue.rounded() == roundedValue {
            return "\(Int(roundedValue))\(suffix)"
        }

        return String(format: "%.1f%@", roundedValue, suffix)
    }

    private func formattedCurrency(_ value: Double) -> String {
        let amountText = currencyFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "$\(amountText)"
    }
}

let application = NSApplication.shared
let delegate = CodexUsageBarApp()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
