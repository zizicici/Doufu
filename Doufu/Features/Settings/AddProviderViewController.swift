//
//  AddProviderViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class AddProviderViewController: UITableViewController {
    private let sections: [(title: String, kinds: [LLMProviderRecord.Kind])] = [
        (
            String(localized: "providers.add.section.standard"),
            [.openAIResponses, .openAIChatCompletions, .anthropic]
        ),
        (
            String(localized: "providers.add.section.other"),
            [.googleGemini, .openRouter, .xiaomiMiMo]
        )
    ]

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .doufuBackground
        title = String(localized: "providers.add.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProviderOptionCell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].kinds.count
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        sections[section].title
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderOptionCell", for: indexPath)
        cell.accessoryType = .disclosureIndicator
        let kind = sections[indexPath.section].kinds[indexPath.row]

        var configuration = cell.defaultContentConfiguration()
        configuration.text = kind.displayName
        configuration.secondaryText = kind.subtitle
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let kind = sections[indexPath.section].kinds[indexPath.row]
        let controller: UIViewController
        switch kind {
        case .openAIResponses:
            controller = ProviderAuthMethodViewController()
        case .openRouter:
            controller = ProviderAuthMethodViewController(providerKind: .openRouter)
        case .openAIChatCompletions, .anthropic, .googleGemini, .xiaomiMiMo:
            controller = ProviderAPIKeyFormViewController(providerKind: kind)
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}
