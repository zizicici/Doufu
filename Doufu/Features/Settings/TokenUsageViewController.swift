//
//  TokenUsageViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/06.
//

import UIKit

final class TokenUsageViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case total
        case breakdown
    }

    private let usageStore = LLMTokenUsageStore.shared
    private var totals = LLMTokenUsageTotals(inputTokens: 0, outputTokens: 0)
    private var records: [LLMTokenUsageRecord] = []
    private let tokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "providers.usage.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UsageCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UsagePlaceholderCell")
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
        case .breakdown:
            return max(records.count, 1)
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }
        switch section {
        case .total:
            return String(localized: "providers.usage.section.total")
        case .breakdown:
            return String(localized: "providers.usage.section.breakdown")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .breakdown else {
            return nil
        }
        return records.isEmpty ? String(localized: "providers.usage.breakdown.footer.empty") : nil
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

        case .breakdown:
            if records.isEmpty {
                let cell = tableView.dequeueReusableCell(withIdentifier: "UsagePlaceholderCell", for: indexPath)
                cell.selectionStyle = .none
                cell.accessoryType = .none
                var configuration = UIListContentConfiguration.cell()
                configuration.text = String(localized: "providers.usage.breakdown.empty")
                configuration.textProperties.alignment = .center
                configuration.textProperties.color = .secondaryLabel
                cell.contentConfiguration = configuration
                return cell
            }

            let record = records[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "UsageCell", for: indexPath)
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
            var configuration = cell.defaultContentConfiguration()
            configuration.text = record.providerLabel
            configuration.secondaryText = String(
                format: String(localized: "providers.usage.breakdown.item.subtitle_format"),
                record.model,
                formattedTokens(record.inputTokens),
                formattedTokens(record.outputTokens)
            )
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .breakdown else {
            return
        }
        guard !records.isEmpty else {
            return
        }

        let record = records[indexPath.row]
        let controller = TokenUsageModelDetailViewController(record: record)
        navigationController?.pushViewController(controller, animated: true)
    }

    private func reloadUsageData() {
        records = usageStore.loadRecords()
        totals = usageStore.loadTotals()
        tableView.reloadData()
    }

    private func formattedTokens(_ value: Int64) -> String {
        let number = NSNumber(value: value)
        let formatted = tokenFormatter.string(from: number) ?? "\(value)"
        return String(format: String(localized: "providers.usage.tokens_format"), formatted)
    }
}

final class TokenUsageModelDetailViewController: UITableViewController {
    private let record: LLMTokenUsageRecord
    private let tokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    init(record: LLMTokenUsageRecord) {
        self.record = record
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = record.model
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UsageDetailCell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        String(
            format: String(localized: "providers.usage.detail.section.model_format"),
            record.providerLabel,
            record.model
        )
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UsageDetailCell", for: indexPath)
        cell.selectionStyle = .none
        cell.accessoryType = .none

        var configuration = cell.defaultContentConfiguration()
        if indexPath.row == 0 {
            configuration.text = String(localized: "providers.usage.detail.input")
            configuration.secondaryText = formattedTokens(record.inputTokens)
        } else {
            configuration.text = String(localized: "providers.usage.detail.output")
            configuration.secondaryText = formattedTokens(record.outputTokens)
        }
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        return cell
    }

    private func formattedTokens(_ value: Int64) -> String {
        let number = NSNumber(value: value)
        let formatted = tokenFormatter.string(from: number) ?? "\(value)"
        return String(format: String(localized: "providers.usage.tokens_format"), formatted)
    }
}
