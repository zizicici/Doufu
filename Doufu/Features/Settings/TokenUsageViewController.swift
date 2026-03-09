//
//  TokenUsageViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/06.
//

import UIKit

@MainActor
class TokenUsageDashboardViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case total
        case trend
    }

    private enum TrendRow: Int, CaseIterable {
        case weekNavigator
        case dimension
        case inputChart
        case outputChart
    }

    private enum ShareDimension: Int, CaseIterable {
        case provider
        case model
    }

    private struct DisplayDailyRecord {
        let dayKey: String
        let providerTitle: String
        let modelTitle: String
        let inputTokens: Int64
        let outputTokens: Int64

        var totalTokens: Int64 {
            inputTokens + outputTokens
        }
    }

    private struct TrendChartData {
        let weekTitle: String
        let canGoOlder: Bool
        let canGoNewer: Bool
        let legendItems: [TokenTrendChartTableViewCell.LegendItem]
        let inputPoints: [TokenBarChartView.Point]
        let outputPoints: [TokenBarChartView.Point]
        let inputTotal: Int64
        let outputTotal: Int64
        let hasAnyData: Bool
    }

    private struct CategoryTotals {
        let inputTokens: Int64
        let outputTokens: Int64

        var totalTokens: Int64 {
            inputTokens + outputTokens
        }
    }

    private let pageTitle: String
    private let projectIdentifier: String?
    private let includeDoneButton: Bool

    private let usageStore = LLMTokenUsageStore.shared
    private let providerStore = LLMProviderSettingsStore.shared

    private var totals = LLMTokenUsageTotals(inputTokens: 0, outputTokens: 0)
    private var allDailyRecords: [DisplayDailyRecord] = []
    private var selectedShareDimension: ShareDimension = .provider
    private var weekPage = 0
    private var trendChartData = TrendChartData(
        weekTitle: "",
        canGoOlder: false,
        canGoNewer: false,
        legendItems: [],
        inputPoints: [],
        outputPoints: [],
        inputTotal: 0,
        outputTotal: 0,
        hasAnyData: false
    )

    private let tokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private let weekRangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private let chartPalette: [UIColor] = [
        .systemBlue,
        .systemOrange,
        .systemGreen,
        .systemPink,
        .systemTeal,
        .systemPurple,
        .systemIndigo,
        .systemRed,
        .systemCyan,
        .systemBrown
    ]

    init(titleText: String, projectIdentifier: String?, includeDoneButton: Bool) {
        pageTitle = titleText
        self.projectIdentifier = projectIdentifier
        self.includeDoneButton = includeDoneButton
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .doufuBackground
        title = pageTitle
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UsageCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UsagePlaceholderCell")
        tableView.register(
            SegmentedControlTableViewCell.self,
            forCellReuseIdentifier: SegmentedControlTableViewCell.reuseIdentifier
        )
        tableView.register(
            WeekNavigationTableViewCell.self,
            forCellReuseIdentifier: WeekNavigationTableViewCell.reuseIdentifier
        )
        tableView.register(
            TokenTrendChartTableViewCell.self,
            forCellReuseIdentifier: TokenTrendChartTableViewCell.reuseIdentifier
        )
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 110

        if includeDoneButton {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(didTapDone)
            )
        }

        reloadUsageData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadUsageData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else {
            return 0
        }
        switch section {
        case .total:
            return 2
        case .trend:
            return TrendRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }
        switch section {
        case .total:
            return String(localized: "providers.usage.section.total")
        case .trend:
            return String(localized: "chat.project_usage.daily_usage")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .trend else {
            return nil
        }
        return trendChartData.hasAnyData ? nil : String(localized: "chat.project_usage.daily_empty")
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch section {
        case .total:
            return makeTotalCell(tableView: tableView, indexPath: indexPath)
        case .trend:
            return makeTrendCell(tableView: tableView, indexPath: indexPath)
        }
    }

    @objc
    private func didTapDone() {
        dismiss(animated: true)
    }

    private func makeTotalCell(tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UsageCell", for: indexPath)
        cell.selectionStyle = .none
        cell.accessoryType = .none
        var configuration = cell.defaultContentConfiguration()
        if indexPath.row == 0 {
            configuration.text = String(localized: "providers.usage.total.input")
            configuration.secondaryText = formattedTokens(totals.inputTokens)
        } else {
            configuration.text = String(localized: "providers.usage.total.output")
            configuration.secondaryText = formattedTokens(totals.outputTokens)
        }
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        return cell
    }

    private func makeTrendCell(tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        guard let row = TrendRow(rawValue: indexPath.row) else {
            return UITableViewCell()
        }

        switch row {
        case .weekNavigator:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: WeekNavigationTableViewCell.reuseIdentifier,
                    for: indexPath
                ) as? WeekNavigationTableViewCell
            else {
                return UITableViewCell()
            }
            cell.configure(
                title: trendChartData.weekTitle,
                canGoOlder: trendChartData.canGoOlder,
                canGoNewer: trendChartData.canGoNewer,
                onGoOlder: { [weak self] in
                    guard let self else { return }
                    self.weekPage += 1
                    self.recomputeTrendData()
                    self.reloadTrendSection()
                },
                onGoNewer: { [weak self] in
                    guard let self else { return }
                    guard self.weekPage > 0 else { return }
                    self.weekPage -= 1
                    self.recomputeTrendData()
                    self.reloadTrendSection()
                }
            )
            return cell

        case .dimension:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SegmentedControlTableViewCell.reuseIdentifier,
                    for: indexPath
                ) as? SegmentedControlTableViewCell
            else {
                return UITableViewCell()
            }
            let titles = [
                String(localized: "chat.menu.provider"),
                String(localized: "chat.menu.model")
            ]
            cell.configure(
                titles: titles,
                selectedIndex: selectedShareDimension.rawValue
            ) { [weak self] selectedIndex in
                guard let self, let newDimension = ShareDimension(rawValue: selectedIndex) else {
                    return
                }
                guard newDimension != self.selectedShareDimension else {
                    return
                }
                self.selectedShareDimension = newDimension
                self.recomputeTrendData()
                self.reloadTrendSection()
            }
            return cell

        case .inputChart, .outputChart:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: TokenTrendChartTableViewCell.reuseIdentifier,
                    for: indexPath
                ) as? TokenTrendChartTableViewCell
            else {
                return UITableViewCell()
            }
            let isInput = row == .inputChart
            let title = isInput
                ? String(localized: "providers.usage.total.input")
                : String(localized: "providers.usage.total.output")
            let value = isInput ? trendChartData.inputTotal : trendChartData.outputTotal
            let points = isInput ? trendChartData.inputPoints : trendChartData.outputPoints

            cell.configure(
                title: title,
                valueText: formattedTokens(value),
                points: points,
                legendItems: trendChartData.legendItems,
                emptyText: String(localized: "providers.usage.breakdown.empty")
            )
            return cell
        }
    }

    private func reloadUsageData() {
        totals = usageStore.loadTotals(projectIdentifier: projectIdentifier)

        let providers = providerStore.loadProviders()
        let providerByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let dailyRecords = usageStore.loadDailyRecords(projectIdentifier: projectIdentifier)
        allDailyRecords = dailyRecords.map { normalizedDisplayRecord($0, providerByID: providerByID) }
        weekPage = max(0, weekPage)

        recomputeTrendData()
        tableView.reloadData()
    }

    private func recomputeTrendData() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard
            let windowEnd = calendar.date(byAdding: .day, value: -(weekPage * 7), to: today),
            let windowStart = calendar.date(byAdding: .day, value: -6, to: windowEnd)
        else {
            trendChartData = TrendChartData(
                weekTitle: "",
                canGoOlder: false,
                canGoNewer: weekPage > 0,
                legendItems: [],
                inputPoints: [],
                outputPoints: [],
                inputTotal: 0,
                outputTotal: 0,
                hasAnyData: false
            )
            return
        }

        let dayKeys = (0 ..< 7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: windowStart).map { dayParser.string(from: $0) }
        }
        let dayKeySet = Set(dayKeys)
        let filteredRecords = allDailyRecords.filter { dayKeySet.contains($0.dayKey) }

        var categoryByTitle: [String: CategoryTotals] = [:]
        var dayInputBuckets: [String: [String: Int64]] = [:]
        var dayOutputBuckets: [String: [String: Int64]] = [:]

        for record in filteredRecords {
            let categoryTitle = selectedShareDimension == .provider ? record.providerTitle : record.modelTitle

            let existingCategory = categoryByTitle[categoryTitle] ?? CategoryTotals(inputTokens: 0, outputTokens: 0)
            categoryByTitle[categoryTitle] = CategoryTotals(
                inputTokens: existingCategory.inputTokens + record.inputTokens,
                outputTokens: existingCategory.outputTokens + record.outputTokens
            )

            var inputBucket = dayInputBuckets[record.dayKey] ?? [:]
            inputBucket[categoryTitle, default: 0] += record.inputTokens
            dayInputBuckets[record.dayKey] = inputBucket

            var outputBucket = dayOutputBuckets[record.dayKey] ?? [:]
            outputBucket[categoryTitle, default: 0] += record.outputTokens
            dayOutputBuckets[record.dayKey] = outputBucket
        }

        let categoryOrder = categoryByTitle
            .map { (title: $0.key, total: $0.value.totalTokens) }
            .sorted { lhs, rhs in
                if lhs.total != rhs.total {
                    return lhs.total > rhs.total
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .map(\.title)

        var colorByCategory: [String: UIColor] = [:]
        for (index, category) in categoryOrder.enumerated() {
            colorByCategory[category] = chartPalette[index % chartPalette.count]
        }

        let inputPoints = dayKeys.map { dayKey -> TokenBarChartView.Point in
            let bucket = dayInputBuckets[dayKey] ?? [:]
            let segments = categoryOrder.compactMap { category -> TokenBarChartView.Segment? in
                guard let value = bucket[category], value > 0 else {
                    return nil
                }
                return TokenBarChartView.Segment(
                    title: category,
                    color: colorByCategory[category] ?? .systemBlue,
                    value: value
                )
            }
            return TokenBarChartView.Point(
                label: shortDayLabel(forDayKey: dayKey),
                segments: segments
            )
        }

        let outputPoints = dayKeys.map { dayKey -> TokenBarChartView.Point in
            let bucket = dayOutputBuckets[dayKey] ?? [:]
            let segments = categoryOrder.compactMap { category -> TokenBarChartView.Segment? in
                guard let value = bucket[category], value > 0 else {
                    return nil
                }
                return TokenBarChartView.Segment(
                    title: category,
                    color: colorByCategory[category] ?? .systemBlue,
                    value: value
                )
            }
            return TokenBarChartView.Point(
                label: shortDayLabel(forDayKey: dayKey),
                segments: segments
            )
        }

        let legendItems = categoryOrder.map { category in
            TokenTrendChartTableViewCell.LegendItem(
                title: category,
                color: colorByCategory[category] ?? .systemBlue
            )
        }

        let inputTotal = filteredRecords.reduce(Int64(0)) { $0 + $1.inputTokens }
        let outputTotal = filteredRecords.reduce(Int64(0)) { $0 + $1.outputTokens }
        let hasAnyData = filteredRecords.contains { $0.totalTokens > 0 }

        let earliestDate = allDailyRecords.compactMap { dayParser.date(from: $0.dayKey) }.min()
        let canGoOlder: Bool
        if let earliestDate {
            canGoOlder = earliestDate < windowStart
        } else {
            canGoOlder = false
        }

        trendChartData = TrendChartData(
            weekTitle: String(
                format: String(localized: "providers.usage.week.range_format"),
                weekRangeFormatter.string(from: windowStart),
                weekRangeFormatter.string(from: windowEnd)
            ),
            canGoOlder: canGoOlder,
            canGoNewer: weekPage > 0,
            legendItems: legendItems,
            inputPoints: inputPoints,
            outputPoints: outputPoints,
            inputTotal: inputTotal,
            outputTotal: outputTotal,
            hasAnyData: hasAnyData
        )
    }

    private func reloadTrendSection() {
        tableView.reloadSections(IndexSet(integer: Section.trend.rawValue), with: .automatic)
    }

    private func normalizedDisplayRecord(
        _ record: LLMTokenUsageDailyRecord,
        providerByID: [String: LLMProviderRecord]
    ) -> DisplayDailyRecord {
        let deletedProvider = String(localized: "chat.project_usage.deleted_provider")
        let deletedModel = String(localized: "chat.project_usage.deleted_model")

        if let provider = providerByID[record.providerID] {
            let normalizedProviderLabel = provider.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let providerTitle = normalizedProviderLabel.isEmpty ? provider.kind.displayName : normalizedProviderLabel

            let isModelAvailable = provider.availableModels.contains {
                $0.modelID.caseInsensitiveCompare(record.model) == .orderedSame
            }
            let modelTitle = isModelAvailable ? record.model : deletedModel
            return DisplayDailyRecord(
                dayKey: record.dayKey,
                providerTitle: providerTitle,
                modelTitle: modelTitle,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens
            )
        }

        return DisplayDailyRecord(
            dayKey: record.dayKey,
            providerTitle: deletedProvider,
            modelTitle: deletedModel,
            inputTokens: record.inputTokens,
            outputTokens: record.outputTokens
        )
    }

    private func shortDayLabel(forDayKey dayKey: String) -> String {
        guard let date = dayParser.date(from: dayKey) else {
            return dayKey
        }
        return shortDayFormatter.string(from: date)
    }

    private func formattedTokens(_ value: Int64) -> String {
        let number = NSNumber(value: value)
        let formatted = tokenFormatter.string(from: number) ?? "\(value)"
        return String(format: String(localized: "providers.usage.tokens_format"), formatted)
    }
}

final class TokenUsageViewController: TokenUsageDashboardViewController {
    init() {
        super.init(
            titleText: String(localized: "providers.usage.title"),
            projectIdentifier: nil,
            includeDoneButton: false
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class SegmentedControlTableViewCell: UITableViewCell {
    static let reuseIdentifier = "SegmentedControlTableViewCell"

    private let segmentedControl = UISegmentedControl()
    private var onSelectionChanged: ((Int) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.selectedSegmentTintColor = .tintColor
        segmentedControl.addTarget(self, action: #selector(valueDidChange), for: .valueChanged)

        contentView.addSubview(segmentedControl)
        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            segmentedControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        titles: [String],
        selectedIndex: Int,
        onSelectionChanged: @escaping (Int) -> Void
    ) {
        segmentedControl.removeAllSegments()
        for (index, title) in titles.enumerated() {
            segmentedControl.insertSegment(withTitle: title, at: index, animated: false)
        }
        if titles.indices.contains(selectedIndex) {
            segmentedControl.selectedSegmentIndex = selectedIndex
        } else if titles.isEmpty {
            segmentedControl.selectedSegmentIndex = UISegmentedControl.noSegment
        } else {
            segmentedControl.selectedSegmentIndex = 0
        }
        self.onSelectionChanged = onSelectionChanged
    }

    @objc
    private func valueDidChange() {
        onSelectionChanged?(segmentedControl.selectedSegmentIndex)
    }
}

final class WeekNavigationTableViewCell: UITableViewCell {
    static let reuseIdentifier = "WeekNavigationTableViewCell"

    private let olderButton = UIButton(type: .system)
    private let newerButton = UIButton(type: .system)
    private let titleLabel = UILabel()

    private var onGoOlder: (() -> Void)?
    private var onGoNewer: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        olderButton.translatesAutoresizingMaskIntoConstraints = false
        olderButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        olderButton.addTarget(self, action: #selector(didTapOlder), for: .touchUpInside)

        newerButton.translatesAutoresizingMaskIntoConstraints = false
        newerButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        newerButton.addTarget(self, action: #selector(didTapNewer), for: .touchUpInside)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1

        contentView.addSubview(olderButton)
        contentView.addSubview(newerButton)
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            olderButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            olderButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            olderButton.widthAnchor.constraint(equalToConstant: 32),
            olderButton.heightAnchor.constraint(equalToConstant: 32),

            newerButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            newerButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            newerButton.widthAnchor.constraint(equalToConstant: 32),
            newerButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: olderButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: newerButton.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        canGoOlder: Bool,
        canGoNewer: Bool,
        onGoOlder: @escaping () -> Void,
        onGoNewer: @escaping () -> Void
    ) {
        titleLabel.text = title
        olderButton.isEnabled = canGoOlder
        newerButton.isEnabled = canGoNewer
        self.onGoOlder = onGoOlder
        self.onGoNewer = onGoNewer
    }

    @objc
    private func didTapOlder() {
        onGoOlder?()
    }

    @objc
    private func didTapNewer() {
        onGoNewer?()
    }
}

final class TokenTrendChartTableViewCell: UITableViewCell {
    struct LegendItem {
        let title: String
        let color: UIColor
    }

    static let reuseIdentifier = "TokenTrendChartTableViewCell"

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let chartView = TokenBarChartView()

    private let legendScrollView = UIScrollView()
    private let legendStackView = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .label

        valueLabel.font = .preferredFont(forTextStyle: .footnote)
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), valueLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        chartView.translatesAutoresizingMaskIntoConstraints = false

        legendScrollView.translatesAutoresizingMaskIntoConstraints = false
        legendScrollView.showsHorizontalScrollIndicator = false

        legendStackView.translatesAutoresizingMaskIntoConstraints = false
        legendStackView.axis = .horizontal
        legendStackView.alignment = .center
        legendStackView.spacing = 12

        contentView.addSubview(titleRow)
        contentView.addSubview(chartView)
        contentView.addSubview(legendScrollView)
        legendScrollView.addSubview(legendStackView)

        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            chartView.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 8),
            chartView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            chartView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            chartView.heightAnchor.constraint(equalToConstant: 156),

            legendScrollView.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 8),
            legendScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            legendScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            legendScrollView.heightAnchor.constraint(equalToConstant: 22),
            legendScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            legendStackView.topAnchor.constraint(equalTo: legendScrollView.contentLayoutGuide.topAnchor),
            legendStackView.leadingAnchor.constraint(equalTo: legendScrollView.contentLayoutGuide.leadingAnchor),
            legendStackView.trailingAnchor.constraint(equalTo: legendScrollView.contentLayoutGuide.trailingAnchor),
            legendStackView.bottomAnchor.constraint(equalTo: legendScrollView.contentLayoutGuide.bottomAnchor),
            legendStackView.heightAnchor.constraint(equalTo: legendScrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        valueText: String,
        points: [TokenBarChartView.Point],
        legendItems: [LegendItem],
        emptyText: String
    ) {
        titleLabel.text = title
        valueLabel.text = valueText
        chartView.configure(points: points, emptyText: emptyText)
        configureLegend(legendItems)
    }

    private func configureLegend(_ items: [LegendItem]) {
        for view in legendStackView.arrangedSubviews {
            legendStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if items.isEmpty {
            legendScrollView.isHidden = true
            return
        }

        legendScrollView.isHidden = false
        for item in items {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = item.color
            dot.layer.cornerRadius = 4
            dot.layer.cornerCurve = .continuous
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8)
            ])

            let label = UILabel()
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabel
            label.text = item.title
            label.setContentCompressionResistancePriority(.required, for: .horizontal)

            let chip = UIStackView(arrangedSubviews: [dot, label])
            chip.axis = .horizontal
            chip.alignment = .center
            chip.spacing = 4
            legendStackView.addArrangedSubview(chip)
        }
    }
}

final class TokenBarChartView: UIView {
    struct Segment {
        let title: String
        let color: UIColor
        let value: Int64
    }

    struct Point {
        let label: String
        let segments: [Segment]

        var total: Int64 {
            segments.reduce(Int64(0)) { $0 + $1.value }
        }
    }

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let emptyLabel = UILabel()
    private let tooltipContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let tooltipLabel = UILabel()
    private var tooltipCenterXConstraint: NSLayoutConstraint?
    private var tooltipTopConstraint: NSLayoutConstraint?
    private var stackWidthConstraint: NSLayoutConstraint?
    private var pointColumns: [UIView] = []
    private var currentPoints: [Point] = []

    private let tokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(points: [Point], emptyText: String) {
        currentPoints = points
        hideTooltip()

        for arrangedSubview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
        pointColumns.removeAll()

        emptyLabel.text = emptyText
        let hasAnyValue = points.contains { $0.total > 0 }
        if !hasAnyValue {
            emptyLabel.isHidden = false
            scrollView.isHidden = true
            return
        }

        emptyLabel.isHidden = true
        scrollView.isHidden = false

        let maxTotal = max(Int64(1), points.map(\.total).max() ?? 1)
        let maxBarHeight: CGFloat = 104

        for point in points {
            let column = UIStackView()
            column.axis = .vertical
            column.alignment = .center
            column.spacing = 4

            let barContainer = UIView()
            barContainer.translatesAutoresizingMaskIntoConstraints = false
            barContainer.backgroundColor = .clear
            let barWidthRelativeConstraint = barContainer.widthAnchor.constraint(equalTo: column.widthAnchor, multiplier: 0.42)
            let barWidthMinConstraint = barContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 12)
            let barWidthMaxConstraint = barContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 26)
            let barHeightConstraint = barContainer.heightAnchor.constraint(equalToConstant: maxBarHeight)

            var accumulatedHeight: CGFloat = 0
            for segment in point.segments {
                guard segment.value > 0 else {
                    continue
                }
                let rawHeight = CGFloat(segment.value) / CGFloat(maxTotal) * maxBarHeight
                let segmentHeight = max(1, rawHeight)

                let segmentView = UIView()
                segmentView.translatesAutoresizingMaskIntoConstraints = false
                segmentView.backgroundColor = segment.color
                segmentView.layer.cornerRadius = 2
                segmentView.layer.cornerCurve = .continuous
                barContainer.addSubview(segmentView)

                NSLayoutConstraint.activate([
                    segmentView.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
                    segmentView.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor),
                    segmentView.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor, constant: -accumulatedHeight),
                    segmentView.heightAnchor.constraint(equalToConstant: segmentHeight)
                ])

                accumulatedHeight += segmentHeight
            }

            let dayLabel = UILabel()
            dayLabel.font = .systemFont(ofSize: 10)
            dayLabel.textColor = .secondaryLabel
            dayLabel.textAlignment = .center
            dayLabel.text = point.label

            column.addArrangedSubview(barContainer)
            column.addArrangedSubview(dayLabel)
            stackView.addArrangedSubview(column)
            NSLayoutConstraint.activate([
                barWidthRelativeConstraint,
                barWidthMinConstraint,
                barWidthMaxConstraint,
                barHeightConstraint
            ])
            pointColumns.append(column)
        }
    }

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .bottom
        stackView.spacing = 10
        stackView.distribution = .fillEqually

        tooltipContainer.translatesAutoresizingMaskIntoConstraints = false
        tooltipContainer.layer.cornerRadius = 10
        tooltipContainer.layer.cornerCurve = .continuous
        tooltipContainer.clipsToBounds = true
        tooltipContainer.isHidden = true

        tooltipLabel.translatesAutoresizingMaskIntoConstraints = false
        tooltipLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        tooltipLabel.textColor = .label
        tooltipLabel.numberOfLines = 0
        tooltipLabel.textAlignment = .left
        tooltipContainer.contentView.addSubview(tooltipLabel)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 2
        emptyLabel.isHidden = true

        addSubview(scrollView)
        addSubview(emptyLabel)
        addSubview(tooltipContainer)
        scrollView.addSubview(stackView)

        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.08
        addGestureRecognizer(longPressGesture)

        tooltipCenterXConstraint = tooltipContainer.centerXAnchor.constraint(equalTo: leadingAnchor)
        tooltipTopConstraint = tooltipContainer.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        stackWidthConstraint = stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -20)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -10),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -16),
            stackWidthConstraint!,

            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            emptyLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            tooltipCenterXConstraint!,
            tooltipTopConstraint!,
            tooltipContainer.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),

            tooltipLabel.topAnchor.constraint(equalTo: tooltipContainer.contentView.topAnchor, constant: 8),
            tooltipLabel.leadingAnchor.constraint(equalTo: tooltipContainer.contentView.leadingAnchor, constant: 10),
            tooltipLabel.trailingAnchor.constraint(equalTo: tooltipContainer.contentView.trailingAnchor, constant: -10),
            tooltipLabel.bottomAnchor.constraint(equalTo: tooltipContainer.contentView.bottomAnchor, constant: -8)
        ])
    }

    @objc
    private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard !scrollView.isHidden, !currentPoints.isEmpty else {
            hideTooltip()
            return
        }

        switch gesture.state {
        case .began, .changed:
            let locationInStack = gesture.location(in: stackView)
            guard let index = nearestPointIndex(for: locationInStack) else {
                hideTooltip()
                return
            }
            showTooltip(for: index)
        case .ended, .cancelled, .failed:
            hideTooltip()
        default:
            break
        }
    }

    private func nearestPointIndex(for location: CGPoint) -> Int? {
        guard !pointColumns.isEmpty else {
            return nil
        }

        var nearestIndex: Int?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (index, column) in pointColumns.enumerated() {
            let centerInStack = column.convert(column.bounds, to: stackView).midX
            let distance = abs(location.x - centerInStack)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = index
            }
        }
        return nearestIndex
    }

    private func showTooltip(for index: Int) {
        guard currentPoints.indices.contains(index), pointColumns.indices.contains(index) else {
            hideTooltip()
            return
        }

        let point = currentPoints[index]
        let sortedSegments = point.segments.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        var lines: [String] = [point.label]
        if sortedSegments.isEmpty {
            lines.append(String(localized: "providers.usage.tooltip.zero"))
        } else {
            for segment in sortedSegments {
                lines.append(
                    String(
                        format: String(localized: "providers.usage.tooltip.segment_format"),
                        segment.title,
                        formattedTokens(segment.value)
                    )
                )
            }
        }
        tooltipLabel.text = lines.joined(separator: "\n")

        let columnFrameInSelf = pointColumns[index].convert(pointColumns[index].bounds, to: self)
        let clampedX = min(max(columnFrameInSelf.midX, 24), bounds.width - 24)
        tooltipCenterXConstraint?.constant = clampedX
        tooltipContainer.isHidden = false
        bringSubviewToFront(tooltipContainer)

        UIView.animate(withDuration: 0.12) {
            self.tooltipContainer.alpha = 1
        }
    }

    private func hideTooltip() {
        tooltipContainer.alpha = 0
        tooltipContainer.isHidden = true
    }

    private func formattedTokens(_ value: Int64) -> String {
        let number = NSNumber(value: value)
        return tokenFormatter.string(from: number) ?? "\(value)"
    }
}
