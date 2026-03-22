//
//  ProviderModelEditorViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/07.
//

import UIKit

final class ProviderModelEditorViewController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    struct SavePayload {
        let modelID: String
        let displayName: String
        let capabilities: LLMProviderModelCapabilities
    }

    var onSave: ((SavePayload) -> Void)?

    private let provider: ProjectChatService.ProviderCredential
    private var existingModel: LLMProviderModelRecord?
    private var readOnly: Bool
    private var modelIDText: String
    private var displayNameText: String
    private var reasoningEfforts: Set<ProjectChatService.ReasoningEffort>
    private var thinkingSupported: Bool
    private var thinkingCanDisable: Bool
    private var structuredOutputSupported: Bool
    private var maxOutputTokensText: String
    private var contextWindowTokensText: String
    private let resolvedMaxOutputTokens: Int
    private let resolvedContextWindowTokens: Int

    private var diffableDataSource: ModelEditorDataSource!

    init(
        provider: ProjectChatService.ProviderCredential,
        existingModel: LLMProviderModelRecord?,
        readOnly: Bool = false
    ) {
        self.provider = provider
        self.existingModel = existingModel
        self.readOnly = readOnly
        let modelID = existingModel?.modelID ?? ""
        modelIDText = modelID
        displayNameText = existingModel?.effectiveDisplayName ?? ""
        let capabilities = existingModel?.capabilities ?? .defaults(for: provider.providerKind, modelID: modelID)
        reasoningEfforts = Set(capabilities.reasoningEfforts)
        thinkingSupported = capabilities.thinkingSupported
        thinkingCanDisable = capabilities.thinkingCanDisable
        structuredOutputSupported = capabilities.structuredOutputSupported
        maxOutputTokensText = capabilities.maxOutputTokensOverride.map { String($0) } ?? ""
        contextWindowTokensText = capabilities.contextWindowTokensOverride.map { String($0) } ?? ""
        let profile = LLMModelRegistry.resolve(
            providerKind: provider.providerKind,
            modelID: modelID,
            modelRecord: existingModel
        )
        resolvedMaxOutputTokens = profile.maxOutputTokens
        resolvedContextWindowTokens = profile.contextWindowTokens
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .doufuBackground
        tableView.backgroundColor = .doufuBackground
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        if readOnly {
            title = String(localized: "provider_model.editor.title.detail")
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: String(localized: "provider_model.editor.button.duplicate"),
                style: .plain,
                target: self,
                action: #selector(duplicateAsCustomModel)
            )
        } else {
            title = existingModel == nil
                ? String(localized: "provider_model.editor.title.add")
                : String(localized: "provider_model.editor.title.edit")
        }
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsToggleCell.self, forCellReuseIdentifier: SettingsToggleCell.reuseIdentifier)
        tableView.register(SettingsCenteredButtonCell.self, forCellReuseIdentifier: SettingsCenteredButtonCell.reuseIdentifier)

        configureDiffableDataSource()
        applySnapshot()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = ModelEditorDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            return self.cell(for: tableView, indexPath: indexPath, itemID: itemID)
        }
        diffableDataSource.defaultRowAnimation = .none

        let providerKind = provider.providerKind
        diffableDataSource.headerProvider = { sectionID in
            switch sectionID {
            case .capability:
                switch providerKind {
                case .openAIResponses, .openAIChatCompletions, .openRouter:
                    return String(localized: "provider_model.editor.section.capabilities")
                case .anthropic, .googleGemini, .xiaomiMiMo:
                    return String(localized: "provider_model.editor.section.thinking")
                }
            default:
                return sectionID.header
            }
        }
    }

    private func cell(
        for tableView: UITableView,
        indexPath: IndexPath,
        itemID: ModelEditorItemID
    ) -> UITableViewCell {
        switch itemID {
        case .modelID:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsTextInputCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsTextInputCell else { return UITableViewCell() }
            cell.configure(
                title: String(localized: "provider_model.editor.field.model_id"),
                text: modelIDText,
                placeholder: provider.providerKind.defaultModelID,
                autocapitalizationType: .none
            ) { [weak self] text in
                self?.modelIDText = text
                self?.refreshSaveButton()
            }
            if readOnly {
                cell.textField.isEnabled = false
                cell.textField.textColor = .secondaryLabel
            }
            return cell

        case .displayName:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsTextInputCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsTextInputCell else { return UITableViewCell() }
            cell.configure(
                title: String(localized: "provider_model.editor.field.display_name"),
                text: displayNameText,
                placeholder: String(localized: "provider_model.editor.field.display_name.placeholder"),
                autocapitalizationType: .words
            ) { [weak self] text in
                self?.displayNameText = text
            }
            if readOnly {
                cell.textField.isEnabled = false
                cell.textField.textColor = .secondaryLabel
            }
            return cell

        case .reasoningEffort(let effort):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsToggleCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsToggleCell else { return UITableViewCell() }
            cell.configure(
                title: String(
                    format: String(localized: "provider_model.editor.reasoning_format"),
                    effort.displayName
                ),
                isOn: reasoningEfforts.contains(effort)
            ) { [weak self] isOn in
                guard let self else { return }
                if isOn {
                    self.reasoningEfforts.insert(effort)
                } else {
                    self.reasoningEfforts.remove(effort)
                }
                self.applySnapshot()
            }
            if readOnly {
                (cell.accessoryView as? UISwitch)?.isEnabled = false
            }
            return cell

        case .thinkingToggle:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsToggleCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsToggleCell else { return UITableViewCell() }
            cell.configure(
                title: String(localized: "provider_model.editor.thinking_supported"),
                isOn: thinkingSupported
            ) { [weak self] isOn in
                guard let self else { return }
                self.thinkingSupported = isOn
                if !isOn {
                    self.thinkingCanDisable = false
                }
                self.applySnapshot()
            }
            if readOnly {
                (cell.accessoryView as? UISwitch)?.isEnabled = false
            }
            return cell

        case .thinkingCanDisable(let enabled):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsToggleCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsToggleCell else { return UITableViewCell() }
            cell.configure(
                title: String(localized: "provider_model.editor.thinking_can_disable"),
                isOn: thinkingCanDisable
            ) { [weak self] isOn in
                self?.thinkingCanDisable = isOn
            }
            cell.isUserInteractionEnabled = enabled
            cell.contentView.alpha = enabled ? 1.0 : 0.72
            if readOnly {
                (cell.accessoryView as? UISwitch)?.isEnabled = false
            }
            return cell

        case .structuredOutput:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsToggleCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsToggleCell else { return UITableViewCell() }
            cell.configure(
                title: String(localized: "provider_model.editor.structured_output"),
                isOn: structuredOutputSupported
            ) { [weak self] isOn in
                self?.structuredOutputSupported = isOn
            }
            if readOnly {
                (cell.accessoryView as? UISwitch)?.isEnabled = false
            }
            return cell

        case .maxOutputTokens:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsTextInputCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsTextInputCell else { return UITableViewCell() }
            let autoLabel = String(localized: "provider_model.editor.field.max_output_tokens.placeholder")
            let placeholder = "\(autoLabel)\u{ff08}\(resolvedMaxOutputTokens.formatted())\u{ff09}"
            cell.configure(
                title: String(localized: "provider_model.editor.field.max_output_tokens"),
                text: maxOutputTokensText,
                placeholder: placeholder,
                keyboardType: .numberPad
            ) { [weak self] text in
                self?.maxOutputTokensText = text
            }
            if readOnly {
                cell.textField.isEnabled = false
                cell.textField.textColor = .secondaryLabel
            }
            return cell

        case .contextWindowTokens:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsTextInputCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsTextInputCell else { return UITableViewCell() }
            let autoLabel = String(localized: "provider_model.editor.field.context_window.placeholder")
            let placeholder = "\(autoLabel)\u{ff08}\(resolvedContextWindowTokens.formatted())\u{ff09}"
            cell.configure(
                title: String(localized: "provider_model.editor.field.context_window"),
                text: contextWindowTokensText,
                placeholder: placeholder,
                keyboardType: .numberPad
            ) { [weak self] text in
                self?.contextWindowTokensText = text
            }
            if readOnly {
                cell.textField.isEnabled = false
                cell.textField.textColor = .secondaryLabel
            }
            return cell

        case .save:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsCenteredButtonCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsCenteredButtonCell else { return UITableViewCell() }
            cell.configure(
                title: String(localized: "provider_model.editor.button.save"),
                isEnabled: canSave()
            )
            return cell
        }
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<ModelEditorSectionID, ModelEditorItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<ModelEditorSectionID, ModelEditorItemID>()

        var sections: [ModelEditorSectionID] = [.identity, .capability, .tokenLimits]
        if !readOnly {
            sections.append(.save)
        }
        snapshot.appendSections(sections)

        // Identity
        snapshot.appendItems([.modelID, .displayName], toSection: .identity)

        // Capability — dynamic based on provider kind
        switch provider.providerKind {
        case .openAIResponses, .openAIChatCompletions, .openRouter:
            var items: [ModelEditorItemID] = ProjectChatService.ReasoningEffort.allCases.map {
                .reasoningEffort($0)
            }
            items.append(.structuredOutput)
            snapshot.appendItems(items, toSection: .capability)
        case .anthropic, .googleGemini, .xiaomiMiMo:
            snapshot.appendItems([
                .thinkingToggle,
                .thinkingCanDisable(enabled: thinkingSupported),
                .structuredOutput,
            ], toSection: .capability)
        }

        // Token Limits
        snapshot.appendItems([.maxOutputTokens, .contextWindowTokens], toSection: .tokenLimits)

        // Save
        if !readOnly {
            snapshot.appendItems([.save], toSection: .save)
        }

        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    private func refreshSaveButton() {
        guard var snapshot = diffableDataSource?.snapshot(),
              snapshot.itemIdentifiers.contains(.save) else { return }
        snapshot.reconfigureItems([.save])
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        if case .save = itemID {
            return canSave() ? indexPath : nil
        }
        return nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return }
        if case .save = itemID, canSave() {
            let payload = SavePayload(
                modelID: modelIDText.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayNameText.trimmingCharacters(in: .whitespacesAndNewlines),
                capabilities: buildCapabilities()
            )
            onSave?(payload)
            navigationController?.popViewController(animated: true)
        }
    }

    @objc private func duplicateAsCustomModel() {
        readOnly = false
        existingModel = nil
        title = String(localized: "provider_model.editor.title.add")
        navigationItem.rightBarButtonItem = nil
        applySnapshot()
    }

    private func canSave() -> Bool {
        let normalizedModelID = modelIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedModelID.isEmpty
    }

    private func buildCapabilities() -> LLMProviderModelCapabilities {
        let maxOutput = Int(maxOutputTokensText.trimmingCharacters(in: .whitespacesAndNewlines))
        let contextWindow = Int(contextWindowTokensText.trimmingCharacters(in: .whitespacesAndNewlines))
        let maxOutputOverride = (maxOutput ?? 0) > 0 ? maxOutput : nil
        let contextWindowOverride = (contextWindow ?? 0) > 0 ? contextWindow : nil

        switch provider.providerKind {
        case .openAIResponses, .openAIChatCompletions, .openRouter:
            let orderedEfforts = ProjectChatService.ReasoningEffort.allCases.filter { reasoningEfforts.contains($0) }
            return LLMProviderModelCapabilities(
                reasoningEfforts: orderedEfforts,
                thinkingSupported: false,
                thinkingCanDisable: false,
                structuredOutputSupported: structuredOutputSupported,
                maxOutputTokensOverride: maxOutputOverride,
                contextWindowTokensOverride: contextWindowOverride
            )
        case .anthropic, .googleGemini, .xiaomiMiMo:
            return LLMProviderModelCapabilities(
                reasoningEfforts: [],
                thinkingSupported: thinkingSupported,
                thinkingCanDisable: thinkingSupported && thinkingCanDisable,
                structuredOutputSupported: structuredOutputSupported,
                maxOutputTokensOverride: maxOutputOverride,
                contextWindowTokensOverride: contextWindowOverride
            )
        }
    }
}

// MARK: - Section & Item IDs

nonisolated enum ModelEditorSectionID: Hashable, Sendable {
    case identity
    case capability
    case tokenLimits
    case save

    var header: String? {
        switch self {
        case .identity:
            return String(localized: "provider_model.editor.section.identity")
        case .capability:
            return nil // dynamic — handled by headerProvider
        case .tokenLimits:
            return String(localized: "provider_model.editor.section.token_limits")
        case .save:
            return nil
        }
    }

    var footer: String? { nil }
}

nonisolated enum ModelEditorItemID: Hashable, Sendable {
    case modelID
    case displayName
    case reasoningEffort(ProjectChatService.ReasoningEffort)
    case thinkingToggle
    case thinkingCanDisable(enabled: Bool)
    case structuredOutput
    case maxOutputTokens
    case contextWindowTokens
    case save
}

// MARK: - DataSource (header/footer support)

private final class ModelEditorDataSource: UITableViewDiffableDataSource<ModelEditorSectionID, ModelEditorItemID> {
    var headerProvider: ((ModelEditorSectionID) -> String?)?

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }
        if let headerProvider {
            return headerProvider(sectionID)
        }
        return sectionID.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.footer
    }
}
