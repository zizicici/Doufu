//
//  OpenAIProviderAuthMethodViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class OpenAIProviderAuthMethodViewController: UITableViewController {
    private let providerKind: LLMProviderRecord.Kind
    private var availableMethods: [Method] {
        switch providerKind {
        case .anthropic:
            return [.apiKey]
        case .openAICompatible, .googleGemini:
            return Method.allCases
        }
    }

    private enum Method: Int, CaseIterable {
        case apiKey
        case oauth

        var title: String {
            switch self {
            case .apiKey:
                return String(localized: "providers.auth_method.api_key.title")
            case .oauth:
                return String(localized: "providers.auth_method.oauth.title")
            }
        }

        var subtitle: String {
            switch self {
            case .apiKey:
                return String(localized: "providers.auth_method.api_key.subtitle")
            case .oauth:
                return String(localized: "providers.auth_method.oauth.subtitle")
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

    init(providerKind: LLMProviderRecord.Kind) {
        self.providerKind = providerKind
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = providerKind.displayName
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "MethodCell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        availableMethods.count
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        String(localized: "providers.auth_method.section.title")
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MethodCell", for: indexPath)
        cell.accessoryType = .disclosureIndicator

        guard indexPath.row < availableMethods.count else {
            return cell
        }
        let method = availableMethods[indexPath.row]

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
        guard indexPath.row < availableMethods.count else {
            return
        }
        let method = availableMethods[indexPath.row]

        switch method {
        case .apiKey:
            let controller = OpenAIAPIKeyProviderFormViewController(providerKind: providerKind)
            navigationController?.pushViewController(controller, animated: true)
        case .oauth:
            let controller = OpenAIOAuthProviderFormViewController(providerKind: providerKind)
            navigationController?.pushViewController(controller, animated: true)
        }
    }
}
