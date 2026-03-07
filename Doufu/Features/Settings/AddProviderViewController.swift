//
//  AddProviderViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class AddProviderViewController: UITableViewController {
    private let providerKinds: [LLMProviderRecord.Kind] = [
        .openAICompatible,
        .anthropic,
        .googleGemini
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
        title = String(localized: "providers.add.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProviderOptionCell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        providerKinds.count
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        String(localized: "providers.add.section.provider_type")
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderOptionCell", for: indexPath)
        cell.accessoryType = .disclosureIndicator
        guard indexPath.row < providerKinds.count else {
            return cell
        }
        let kind = providerKinds[indexPath.row]

        var configuration = cell.defaultContentConfiguration()
        configuration.image = UIImage(systemName: kind.iconSystemName)
        configuration.text = kind.displayName
        configuration.secondaryText = kind.subtitle
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < providerKinds.count else {
            return
        }
        let controller = ProviderAuthMethodViewController(providerKind: providerKinds[indexPath.row])
        navigationController?.pushViewController(controller, animated: true)
    }
}
