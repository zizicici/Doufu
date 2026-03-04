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
        title = "Add Provider"
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
        "Provider Type"
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderOptionCell", for: indexPath)
        cell.accessoryType = .disclosureIndicator

        var configuration = cell.defaultContentConfiguration()
        configuration.image = UIImage(systemName: "sparkles.rectangle.stack")
        configuration.text = "OpenAI / Compatible API"
        configuration.secondaryText = "OpenAI 官方或兼容 OpenAI API 的服务"
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
