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
    private var selectedStatsRange: StatsRange = .today
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
        statusMenu.addItem(statsViewerItem(for: snapshot))
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))

        addSummaryMetric(
            title: "5h window",
            value: percentText(snapshot.primaryLimit?.usedPercent),
            x: 14,
            y: 8,
            to: view
        )
        addSummaryMetric(
            title: "Weekly",
            value: percentText(snapshot.weeklyLimit?.usedPercent),
            x: 164,
            y: 8,
            to: view
        )

        return viewItem(view)
    }

    private func statsViewerItem(for snapshot: CodexUsageSnapshot) -> NSMenuItem {
        let view = StatsViewerView(
            snapshot: snapshot,
            selectedRange: selectedStatsRange,
            formatTokens: { [weak self] value in
                self?.formatted(value) ?? "\(value)"
            },
            formatCurrency: { [weak self] value in
                self?.formattedCurrency(value) ?? String(format: "$%.2f", value)
            },
            onRangeChanged: { [weak self] range in
                self?.selectedStatsRange = range
            }
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

private enum StatsRange: Int {
    case today
    case last7Days
    case last30Days

    var segmentIndex: Int {
        rawValue
    }
}

private final class StatsViewerView: NSView {
    private static let viewWidth: CGFloat = 520
    private static let statsYOffset: CGFloat = 136

    private let snapshot: CodexUsageSnapshot
    private let formatTokens: (Int) -> String
    private let formatCurrency: (Double) -> String
    private let onRangeChanged: (StatsRange) -> Void
    private let spentValueLabel: NSTextField
    private let tokensValueLabel: NSTextField
    private let spentSparklineView: SparklineView
    private let tokensSparklineView: SparklineView
    private let tokenActivityGridView: TokenActivityGridView
    private let hoverTooltipView: HoverTooltipView

    init(
        snapshot: CodexUsageSnapshot,
        selectedRange: StatsRange,
        formatTokens: @escaping (Int) -> String,
        formatCurrency: @escaping (Double) -> String,
        onRangeChanged: @escaping (StatsRange) -> Void
    ) {
        self.snapshot = snapshot
        self.formatTokens = formatTokens
        self.formatCurrency = formatCurrency
        self.onRangeChanged = onRangeChanged
        spentValueLabel = StatsViewerView.makeLabel(
            "",
            frame: NSRect(x: 14, y: StatsViewerView.statsYOffset + 76, width: 110, height: 20),
            font: .monospacedDigitSystemFont(ofSize: 16, weight: .semibold),
            color: .labelColor
        )
        tokensValueLabel = StatsViewerView.makeLabel(
            "",
            frame: NSRect(x: 14, y: StatsViewerView.statsYOffset + 22, width: 110, height: 20),
            font: .monospacedDigitSystemFont(ofSize: 16, weight: .semibold),
            color: .labelColor
        )
        spentSparklineView = SparklineView(
            frame: NSRect(x: 132, y: StatsViewerView.statsYOffset + 62, width: 374, height: 44),
            value: { $0.spent },
            tooltipText: { point in
                "\(point.dateText)\n\(formatCurrency(point.spent)) spent\n\(formatTokens(point.tokens)) tokens"
            }
        )
        tokensSparklineView = SparklineView(
            frame: NSRect(x: 132, y: StatsViewerView.statsYOffset + 8, width: 374, height: 44),
            value: { Double($0.tokens) },
            tooltipText: { point in
                "\(point.dateText)\n\(formatCurrency(point.spent)) spent\n\(formatTokens(point.tokens)) tokens"
            }
        )
        tokenActivityGridView = TokenActivityGridView(
            frame: NSRect(x: 14, y: 12, width: 492, height: 86),
            buckets: snapshot.last12MonthsDailyBuckets,
            formatTokens: formatTokens
        )
        hoverTooltipView = HoverTooltipView(frame: .zero)

        super.init(frame: NSRect(x: 0, y: 0, width: StatsViewerView.viewWidth, height: 286))
        tokenActivityGridView.onHoverChanged = { [weak self] hover in
            self?.updateActivityHover(hover)
        }

        addSubview(StatsViewerView.makeLabel(
            "Stats",
            frame: NSRect(x: 14, y: StatsViewerView.statsYOffset + 116, width: 90, height: 18),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        ))

        let segmentedControl = NSSegmentedControl(labels: ["Today", "7D", "30D"], trackingMode: .selectOne, target: self, action: #selector(rangeChanged(_:)))
        segmentedControl.frame = NSRect(x: 358, y: StatsViewerView.statsYOffset + 110, width: 148, height: 26)
        segmentedControl.selectedSegment = selectedRange.segmentIndex
        addSubview(segmentedControl)

        addSubview(StatsViewerView.makeLabel(
            "$ spent",
            frame: NSRect(x: 14, y: StatsViewerView.statsYOffset + 96, width: 110, height: 14),
            font: .systemFont(ofSize: 10, weight: .medium),
            color: .secondaryLabelColor
        ))
        addSubview(spentValueLabel)
        addSubview(spentSparklineView)

        addSubview(StatsViewerView.makeLabel(
            "Tokens spent",
            frame: NSRect(x: 14, y: StatsViewerView.statsYOffset + 42, width: 110, height: 14),
            font: .systemFont(ofSize: 10, weight: .medium),
            color: .secondaryLabelColor
        ))
        addSubview(tokensValueLabel)
        addSubview(tokensSparklineView)

        addSubview(StatsViewerView.makeLabel(
            "Token activity",
            frame: NSRect(x: 14, y: 106, width: 140, height: 18),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        ))

        addSubview(tokenActivityGridView)
        addSubview(hoverTooltipView)

        update(range: selectedRange)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        guard let range = StatsRange(rawValue: sender.selectedSegment) else {
            return
        }

        onRangeChanged(range)
        update(range: range)
    }

    private func updateActivityHover(_ hover: TokenActivityHover?) {
        guard let hover else {
            hoverTooltipView.isHidden = true
            return
        }

        hoverTooltipView.text = hover.text
        let size = hoverTooltipView.fittingSize(maxWidth: bounds.width - 16)
        let cellRect = convert(hover.cellRect, from: tokenActivityGridView)
        let x = min(max(cellRect.midX - size.width / 2, 8), bounds.width - size.width - 8)
        let y = min(max(cellRect.maxY + 7, 8), bounds.height - size.height - 8)
        hoverTooltipView.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        hoverTooltipView.isHidden = false
    }

    private func update(range: StatsRange) {
        let buckets = buckets(for: range)
        let summary = summary(for: buckets)

        spentValueLabel.stringValue = formatCurrency(summary.estimatedCost)
        tokensValueLabel.stringValue = "\(formatTokens(summary.totalTokens)) tok"
        let points = buckets.map { bucket in
            SparklinePoint(
                dateText: dateText(for: bucket, range: range),
                spent: bucket.summary.estimatedCost,
                tokens: bucket.summary.totalTokens
            )
        }
        spentSparklineView.points = points
        tokensSparklineView.points = points
    }

    private func summary(for buckets: [UsageBucket]) -> CostSummary {
        buckets.reduce(into: CostSummary()) { total, bucket in
            total.calls += bucket.summary.calls
            total.inputTokens += bucket.summary.inputTokens
            total.cachedInputTokens += bucket.summary.cachedInputTokens
            total.outputTokens += bucket.summary.outputTokens
            total.totalTokens += bucket.summary.totalTokens
            total.estimatedCost += bucket.summary.estimatedCost
        }
    }

    private func buckets(for range: StatsRange) -> [UsageBucket] {
        switch range {
        case .today:
            return snapshot.todayBuckets
        case .last7Days:
            return snapshot.last7DaysBuckets
        case .last30Days:
            return snapshot.last30DaysBuckets
        }
    }

    private func dateText(for bucket: UsageBucket, range: StatsRange) -> String {
        switch range {
        case .today:
            return StatsViewerView.hourFormatter.string(from: bucket.startDate)
        case .last7Days, .last30Days:
            return StatsViewerView.dayFormatter.string(from: bucket.startDate)
        }
    }

    private static func makeLabel(
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, h a")
        return formatter
    }()
}

private struct TokenActivityCell {
    let date: Date
    let rect: NSRect
    let tokens: Int
}

private struct TokenActivityGridLayout {
    let firstWeekStart: Date
    let lastWeekEnd: Date
    let cellSize: CGFloat
    let gap: CGFloat
    let originX: CGFloat
    let originY: CGFloat
    let gridHeight: CGFloat
}

private struct TokenActivityHover {
    let text: String
    let cellRect: NSRect
}

private final class TokenActivityGridView: NSView {
    var onHoverChanged: (TokenActivityHover?) -> Void = { _ in }
    private let buckets: [UsageBucket]
    private let formatTokens: (Int) -> String
    private let calendar: Calendar
    private var trackingArea: NSTrackingArea?
    private var hoveredDate: Date?

    init(
        frame frameRect: NSRect,
        buckets: [UsageBucket],
        formatTokens: @escaping (Int) -> String,
        calendar: Calendar = .current
    ) {
        self.buckets = buckets
        self.formatTokens = formatTokens
        self.calendar = calendar
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredDate = nil
        onHoverChanged(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let layout = gridLayout() else {
            return
        }

        let cells = activityCells(layout: layout)
        let maxValue = cells.map(\.tokens).max() ?? 0

        for cell in cells {
            fillColor(for: cell, maxValue: maxValue).setFill()
            NSBezierPath(
                roundedRect: cell.rect,
                xRadius: min(2, layout.cellSize / 2),
                yRadius: min(2, layout.cellSize / 2)
            ).fill()
        }

        drawMonthLabels(layout: layout)
    }

    private func activityCells(layout: TokenActivityGridLayout) -> [TokenActivityCell] {
        let dailyValues = dailyValuesByDate()
        var cells: [TokenActivityCell] = []
        var date = layout.firstWeekStart

        while date <= layout.lastWeekEnd {
            let dayStart = calendar.startOfDay(for: date)
            let dayOffset = calendar.dateComponents([.day], from: layout.firstWeekStart, to: dayStart).day ?? 0
            let column = max(dayOffset / 7, 0)
            let row = weekdayIndex(for: dayStart)
            let x = layout.originX + CGFloat(column) * (layout.cellSize + layout.gap)
            let y = layout.originY + layout.gridHeight - layout.cellSize - CGFloat(row) * (layout.cellSize + layout.gap)

            cells.append(TokenActivityCell(
                date: dayStart,
                rect: NSRect(x: x, y: y, width: layout.cellSize, height: layout.cellSize),
                tokens: dailyValues[dayStart] ?? 0
            ))

            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: date) else {
                break
            }
            date = nextDate
        }

        return cells
    }

    private func gridLayout() -> TokenActivityGridLayout? {
        guard let firstBucket = buckets.first,
              let lastBucket = buckets.last,
              let firstWeekStart = calendar.dateInterval(of: .weekOfYear, for: firstBucket.startDate)?.start,
              let lastWeekStart = calendar.dateInterval(of: .weekOfYear, for: lastBucket.startDate)?.start else {
            return nil
        }

        let daySpan = calendar.dateComponents([.day], from: firstWeekStart, to: lastWeekStart).day ?? 0
        let columns = max(daySpan / 7 + 1, 1)
        let gap: CGFloat = 2
        let labelHeight: CGFloat = 18
        let availableWidth = bounds.width
        let availableHeight = max(bounds.height - labelHeight, 1)
        let cellWidth = (availableWidth - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let cellHeight = (availableHeight - 6 * gap) / 7
        let cellSize = max(floor(min(cellWidth, cellHeight)), 1)
        let gridWidth = CGFloat(columns) * cellSize + CGFloat(columns - 1) * gap
        let gridHeight = 7 * cellSize + 6 * gap
        let originX = bounds.minX + max((bounds.width - gridWidth) / 2, 0)
        let originY = bounds.minY + labelHeight + max((availableHeight - gridHeight) / 2, 0)
        let lastWeekEnd = calendar.date(byAdding: .day, value: 6, to: lastWeekStart) ?? lastBucket.startDate

        return TokenActivityGridLayout(
            firstWeekStart: firstWeekStart,
            lastWeekEnd: lastWeekEnd,
            cellSize: cellSize,
            gap: gap,
            originX: originX,
            originY: originY,
            gridHeight: gridHeight
        )
    }

    private func dailyValuesByDate() -> [Date: Int] {
        Dictionary(uniqueKeysWithValues: buckets.map { bucket in
            (bucket.startDate, bucket.summary.totalTokens)
        })
    }

    private func weekdayIndex(for date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private func fillColor(for cell: TokenActivityCell, maxValue: Int) -> NSColor {
        guard cell.tokens > 0, maxValue > 0 else {
            return NSColor.labelColor.withAlphaComponent(0.08)
        }

        let normalizedValue = CGFloat(cell.tokens) / CGFloat(maxValue)
        let alpha = min(0.95, 0.28 + normalizedValue * 0.67)
        return NSColor.systemBlue.withAlphaComponent(alpha)
    }

    private func updateHover(at point: NSPoint) {
        guard let layout = gridLayout(),
              let cell = activityCells(layout: layout).first(where: { $0.rect.contains(point) }) else {
            hoveredDate = nil
            onHoverChanged(nil)
            return
        }

        guard hoveredDate != cell.date else {
            return
        }

        hoveredDate = cell.date
        onHoverChanged(TokenActivityHover(
            text: "\(formatTokens(cell.tokens)) tokens on \(TokenActivityGridView.hoverDateFormatter.string(from: cell.date))",
            cellRect: cell.rect
        ))
    }

    private func drawMonthLabels(layout: TokenActivityGridLayout) {
        guard let firstBucket = buckets.first,
              let lastBucket = buckets.last,
              var monthStart = calendar.dateInterval(of: .month, for: firstBucket.startDate)?.start else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        while monthStart <= lastBucket.startDate {
            let dayOffset = calendar.dateComponents([.day], from: layout.firstWeekStart, to: monthStart).day ?? 0
            let column = max(dayOffset / 7, 0)
            let x = layout.originX + CGFloat(column) * (layout.cellSize + layout.gap)
            NSString(string: TokenActivityGridView.monthFormatter.string(from: monthStart)).draw(
                in: NSRect(x: x, y: bounds.minY, width: 32, height: 14),
                withAttributes: attributes
            )

            guard let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                break
            }
            monthStart = nextMonthStart
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()

    private static let hoverDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}

private final class HoverTooltipView: NSView {
    var text = "" {
        didSet {
            textField.stringValue = text
            needsDisplay = true
            needsLayout = true
        }
    }

    private let textField: NSTextField = {
        let textField = NSTextField(labelWithString: "")
        textField.font = .systemFont(ofSize: 13, weight: .regular)
        textField.textColor = .white
        textField.alignment = .center
        textField.lineBreakMode = .byTruncatingTail
        return textField
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        addSubview(textField)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textField.font ?? NSFont.systemFont(ofSize: 13),
        ]
        let textSize = NSString(string: text).size(withAttributes: attributes)
        let width = min(max(textSize.width + 28, 72), maxWidth)
        return NSSize(width: width, height: 34)
    }

    override func layout() {
        super.layout()
        textField.frame = bounds.insetBy(dx: 12, dy: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.86).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private struct SparklinePoint {
    let dateText: String
    let spent: Double
    let tokens: Int
}

private final class SparklineView: NSView, NSViewToolTipOwner {
    var points: [SparklinePoint] = [] {
        didSet {
            resetToolTips()
            needsDisplay = true
        }
    }
    private let value: (SparklinePoint) -> Double
    private let tooltipText: (SparklinePoint) -> String
    private var tooltipPoints: [NSView.ToolTipTag: SparklinePoint] = [:]

    init(
        frame frameRect: NSRect,
        value: @escaping (SparklinePoint) -> Double,
        tooltipText: @escaping (SparklinePoint) -> String
    ) {
        self.value = value
        self.tooltipText = tooltipText
        super.init(frame: frameRect)
        resetToolTips()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetToolTips()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let values = points.map(value)
        guard values.count > 1, let maxValue = values.max(), maxValue > 0 else {
            return
        }

        let minValue = values.min() ?? 0
        let valueRange = maxValue - minValue
        let drawingRect = bounds.insetBy(dx: 3, dy: 4)
        let stepX = drawingRect.width / CGFloat(values.count - 1)
        let path = NSBezierPath()

        for (index, value) in values.enumerated() {
            let normalizedValue = valueRange > 0 ? (value - minValue) / valueRange : 0.5
            let x = drawingRect.minX + CGFloat(index) * stepX
            let y = drawingRect.maxY - CGFloat(normalizedValue) * drawingRect.height
            let point = NSPoint(x: x, y: y)

            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }

        let fillPath = path.copy() as? NSBezierPath
        fillPath?.line(to: NSPoint(x: drawingRect.maxX, y: drawingRect.maxY))
        fillPath?.line(to: NSPoint(x: drawingRect.minX, y: drawingRect.maxY))
        fillPath?.close()
        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        fillPath?.fill()

        path.lineWidth = 2.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.systemBlue.setStroke()
        path.stroke()
    }

    @objc(view:stringForToolTip:point:userData:)
    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let point = tooltipPoints[tag] else {
            return ""
        }

        return tooltipText(point)
    }

    private func resetToolTips() {
        removeAllToolTips()
        tooltipPoints.removeAll()

        guard !points.isEmpty else {
            return
        }

        if points.count == 1 {
            let tag = addToolTip(bounds, owner: self, userData: nil)
            tooltipPoints[tag] = points[0]
            return
        }

        let drawingRect = bounds.insetBy(dx: 3, dy: 4)
        let stepX = drawingRect.width / CGFloat(points.count - 1)

        for (index, point) in points.enumerated() {
            let centerX = drawingRect.minX + CGFloat(index) * stepX
            let leftX = index == 0 ? bounds.minX : centerX - stepX / 2
            let rightX = index == points.count - 1 ? bounds.maxX : centerX + stepX / 2
            let rect = NSRect(
                x: leftX,
                y: bounds.minY,
                width: max(rightX - leftX, 1),
                height: bounds.height
            )
            let tag = addToolTip(rect, owner: self, userData: nil)
            tooltipPoints[tag] = point
        }
    }
}

let application = NSApplication.shared
let delegate = CodexUsageBarApp()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
