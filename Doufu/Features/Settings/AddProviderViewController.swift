//
//  AddProviderViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class AddProviderViewController: UITableViewController {

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
        1
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

        var configuration = cell.defaultContentConfiguration()
        configuration.image = UIImage(systemName: "sparkles.rectangle.stack")
        configuration.text = String(localized: "providers.kind.openai_compatible.title")
        configuration.secondaryText = String(localized: "providers.kind.openai_compatible.subtitle")
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let controller = OpenAIProviderAuthMethodViewController()
        navigationController?.pushViewController(controller, animated: true)
    }
}
