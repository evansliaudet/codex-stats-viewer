import AppKit
import Foundation

final class CodexUsageBarApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusMenu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Loading Codex usage...", action: nil, keyEquivalent: "")
    private let refreshMenuItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")

    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
    private let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
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

    private var timer: Timer?
    private var config: AppConfig?
    private var store: CodexUsageStore?
    private var snapshot: CodexUsageSnapshot?
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        rebuildMenu()

        do {
            let config = try AppConfig.load()
            self.config = config
            store = CodexUsageStore(config: config)
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
    }

    @objc private func refreshNow() {
        refresh()
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
        setStatusText("Codex ...")

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

        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            showSnapshot(snapshot)
        case .failure(let error):
            showError(error)
        }

        rebuildMenu()
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

        statusMenu.addItem(.separator())
        statusMenu.addItem(refreshMenuItem)
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
        currencyFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}

let application = NSApplication.shared
let delegate = CodexUsageBarApp()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
