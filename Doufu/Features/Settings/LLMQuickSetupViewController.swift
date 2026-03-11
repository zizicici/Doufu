//
//  LLMQuickSetupViewController.swift
//  Doufu
//
//  Created by Claude on 2026/03/09.
//

import UIKit

@MainActor
final class LLMQuickSetupViewController: UITableViewController {

    var onDismiss: (() -> Void)?

    private enum Row: Int, CaseIterable {
        case manageProviders
        case defaultModel
    }

    private let store = LLMProviderSettingsStore.shared
    private let modelSelectionStore = ModelSelectionStateStore.shared
    private var modelSelectionObserver: NSObjectProtocol?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let modelSelectionObserver {
            NotificationCenter.default.removeObserver(modelSelectionObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .doufuBackground
        title = String(localized: "settings.section.llm_providers")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(didTapDone)
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        modelSelectionObserver = modelSelectionStore.addObserver { [weak self] change in
            guard case .appDefault = change.scope else { return }
            self?.reloadDefaultModelRow()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        String(localized: "settings.section.llm_providers")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.accessoryType = .disclosureIndicator
        guard let row = Row(rawValue: indexPath.row) else { return cell }

        var configuration = UIListContentConfiguration.valueCell()
        switch row {
        case .manageProviders:
            let count = store.loadProviders().count
            configuration.text = String(localized: "settings.providers.title")
            configuration.secondaryText = String(
                format: String(localized: "settings.manage_providers.configured_count_format"),
                count
            )
        case .defaultModel:
            configuration.text = String(localized: "settings.default_model.title")
            configuration.secondaryText = defaultModelDisplayName()
        }
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = Row(rawValue: indexPath.row) else { return }
        switch row {
        case .manageProviders:
            let controller = ManageProvidersViewController()
            navigationController?.pushViewController(controller, animated: true)
        case .defaultModel:
            let controller = DefaultModelSelectionViewController()
            navigationController?.pushViewController(controller, animated: true)
        }
    }

    @objc
    private func didTapDone() {
        dismiss(animated: true) { [weak self] in
            self?.onDismiss?()
        }
    }

    private func defaultModelDisplayName() -> String {
        guard let selection = modelSelectionStore.loadAppDefaultSelection() else {
            return String(localized: "settings.default_model.not_set")
        }
        let resolution = ModelSelectionResolver.resolve(
            appDefault: selection,
            projectDefault: nil,
            threadSelection: nil,
            availableCredentials: ProviderCredentialResolver.resolveAvailableCredentials(providerStore: store),
            providerStore: store
        )
        guard resolution.state == .valid,
              let provider = store.loadProvider(id: selection.providerID)
        else {
            return String(
                localized: "settings.default_model.invalid",
                defaultValue: "Invalid App Default"
            )
        }
        let model = provider.availableModels.first(where: {
            $0.id.caseInsensitiveCompare(selection.modelRecordID) == .orderedSame
        })
        let modelName = model?.effectiveDisplayName ?? selection.modelRecordID
        return provider.label + " · " + modelName
    }

    private func reloadDefaultModelRow() {
        guard isViewLoaded else { return }
        let indexPath = IndexPath(row: Row.defaultModel.rawValue, section: 0)
        guard tableView.numberOfRows(inSection: 0) > indexPath.row else {
            return
        }
        tableView.reloadRows(at: [indexPath], with: .none)
    }
}
