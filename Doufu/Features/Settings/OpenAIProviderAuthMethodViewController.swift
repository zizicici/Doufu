//
//  OpenAIProviderAuthMethodViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class OpenAIProviderAuthMethodViewController: UITableViewController {

    private enum Method: Int, CaseIterable {
        case apiKey
        case oauth

        var title: String {
            switch self {
            case .apiKey:
                return "API Key"
            case .oauth:
                return "OAuth"
            }
        }

        var subtitle: String {
            switch self {
            case .apiKey:
                return "通过 API Key 添加 Provider"
            case .oauth:
                return "登录成功后自动填入网址与 Bearer Token"
            }
        }

        var image: UIImage? {
            switch self {
            case .apiKey:
                return UIImage(systemName: "key.fill")
            case .oauth:
                return UIImage(systemName: "person.crop.circle.badge.checkmark")
            }
        }
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "OpenAI / Compatible API"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "MethodCell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Method.allCases.count
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        "Method"
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MethodCell", for: indexPath)
        cell.accessoryType = .disclosureIndicator

        guard let method = Method(rawValue: indexPath.row) else {
            return cell
        }

        var configuration = cell.defaultContentConfiguration()
        configuration.image = method.image
        configuration.text = method.title
        configuration.secondaryText = method.subtitle
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let method = Method(rawValue: indexPath.row) else {
            return
        }

        switch method {
        case .apiKey:
            let controller = OpenAIAPIKeyProviderFormViewController()
            navigationController?.pushViewController(controller, animated: true)
        case .oauth:
            let controller = OpenAIOAuthProviderFormViewController()
            navigationController?.pushViewController(controller, animated: true)
        }
    }
}
