//
//  ProviderModelEditorViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/07.
//

import UIKit

final class ProviderModelEditorViewController: UITableViewController {
    struct SavePayload {
        let modelID: String
        let displayName: String
        let capabilities: LLMProviderModelCapabilities
    }

    var onSave: ((SavePayload) -> Void)?

    private enum Section: Int, CaseIterable {
        case identity
        case capability
        case tokenLimits
        case save
    }

    private enum TokenLimitsRow: Int, CaseIterable {
        case maxOutputTokens
        case contextWindowTokens
    }

    private enum IdentityRow: Int, CaseIterable {
        case modelID
        case displayName
    }

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
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .doufuBackground
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
        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsToggleCell.self, forCellReuseIdentifier: SettingsToggleCell.reuseIdentifier)
        tableView.register(SettingsCenteredButtonCell.self, forCellReuseIdentifier: SettingsCenteredButtonCell.reuseIdentifier)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else {
            return 0
        }
        switch section {
        case .identity:
            return IdentityRow.allCases.count
        case .capability:
            switch provider.providerKind {
            case .openAICompatible, .openRouter:
                return ProjectChatService.ReasoningEffort.allCases.count + 1
            case .anthropic, .googleGemini:
                return 3
            }
        case .tokenLimits:
            return TokenLimitsRow.allCases.count
        case .save:
            return readOnly ? 0 : 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }
        switch section {
        case .identity:
            return String(localized: "provider_model.editor.section.identity")
        case .capability:
            return (provider.providerKind == .openAICompatible || provider.providerKind == .openRouter)
                ? String(localized: "provider_model.editor.section.capabilities")
                : String(localized: "provider_model.editor.section.thinking")
        case .tokenLimits:
            return String(localized: "provider_model.editor.section.token_limits")
        case .save:
            return nil
        }
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch section {
        case .identity:
            guard
                let row = IdentityRow(rawValue: indexPath.row),
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsTextInputCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsTextInputCell
            else {
                return UITableViewCell()
            }

            switch row {
            case .modelID:
                cell.configure(
                    title: String(localized: "provider_model.editor.field.model_id"),
                    text: modelIDText,
                    placeholder: provider.providerKind.defaultModelID,
                    autocapitalizationType: .none
                ) { [weak self] text in
                    self?.modelIDText = text
                    self?.tableView.reloadSections(IndexSet(integer: Section.save.rawValue), with: .none)
                }
            case .displayName:
                cell.configure(
                    title: String(localized: "provider_model.editor.field.display_name"),
                    text: displayNameText,
                    placeholder: String(localized: "provider_model.editor.field.display_name.placeholder"),
                    autocapitalizationType: .words
                ) { [weak self] text in
                    self?.displayNameText = text
                }
            }
            if readOnly {
                cell.textField.isEnabled = false
                cell.textField.textColor = .secondaryLabel
            }
            return cell

        case .capability:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsToggleCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsToggleCell
            else {
                return UITableViewCell()
            }

            switch provider.providerKind {
            case .openAICompatible, .openRouter:
                if indexPath.row < ProjectChatService.ReasoningEffort.allCases.count {
                    let effort = ProjectChatService.ReasoningEffort.allCases[indexPath.row]
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
                        self.tableView.reloadSections(IndexSet(integer: Section.save.rawValue), with: .none)
                    }
                } else {
                    cell.configure(
                        title: String(localized: "provider_model.editor.structured_output"),
                        isOn: structuredOutputSupported
                    ) { [weak self] isOn in
                        self?.structuredOutputSupported = isOn
                    }
                }
            case .anthropic, .googleGemini:
                switch indexPath.row {
                case 0:
                    cell.configure(
                        title: String(localized: "provider_model.editor.thinking_supported"),
                        isOn: thinkingSupported
                    ) { [weak self] isOn in
                        guard let self else { return }
                        self.thinkingSupported = isOn
                        if !isOn {
                            self.thinkingCanDisable = false
                        }
                        self.tableView.reloadSections(IndexSet(integer: Section.capability.rawValue), with: .none)
                    }
                case 1:
                    cell.configure(
                        title: String(localized: "provider_model.editor.thinking_can_disable"),
                        isOn: thinkingCanDisable
                    ) { [weak self] isOn in
                        self?.thinkingCanDisable = isOn
                    }
                    cell.isUserInteractionEnabled = thinkingSupported
                    cell.contentView.alpha = thinkingSupported ? 1.0 : 0.72
                default:
                    cell.configure(
                        title: String(localized: "provider_model.editor.structured_output"),
                        isOn: structuredOutputSupported
                    ) { [weak self] isOn in
                        self?.structuredOutputSupported = isOn
                    }
                }
            }
            if readOnly {
                (cell.accessoryView as? UISwitch)?.isEnabled = false
            }
            return cell

        case .tokenLimits:
            guard
                let row = TokenLimitsRow(rawValue: indexPath.row),
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsTextInputCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsTextInputCell
            else {
                return UITableViewCell()
            }
            switch row {
            case .maxOutputTokens:
                let autoLabel = String(localized: "provider_model.editor.field.max_output_tokens.placeholder")
                let placeholder = "\(autoLabel)（\(resolvedMaxOutputTokens.formatted())）"
                cell.configure(
                    title: String(localized: "provider_model.editor.field.max_output_tokens"),
                    text: maxOutputTokensText,
                    placeholder: placeholder,
                    keyboardType: .numberPad
                ) { [weak self] text in
                    self?.maxOutputTokensText = text
                }
            case .contextWindowTokens:
                let autoLabel = String(localized: "provider_model.editor.field.context_window.placeholder")
                let placeholder = "\(autoLabel)（\(resolvedContextWindowTokens.formatted())）"
                cell.configure(
                    title: String(localized: "provider_model.editor.field.context_window"),
                    text: contextWindowTokensText,
                    placeholder: placeholder,
                    keyboardType: .numberPad
                ) { [weak self] text in
                    self?.contextWindowTokensText = text
                }
            }
            if readOnly {
                cell.textField.isEnabled = false
                cell.textField.textColor = .secondaryLabel
            }
            return cell

        case .save:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsCenteredButtonCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsCenteredButtonCell
            else {
                return UITableViewCell()
            }
            cell.configure(
                title: String(localized: "provider_model.editor.button.save"),
                isEnabled: canSave()
            )
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard Section(rawValue: indexPath.section) == .save else {
            return nil
        }
        return canSave() ? indexPath : nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard Section(rawValue: indexPath.section) == .save, canSave() else {
            return
        }

        let payload = SavePayload(
            modelID: modelIDText.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: displayNameText.trimmingCharacters(in: .whitespacesAndNewlines),
            capabilities: buildCapabilities()
        )
        onSave?(payload)
        navigationController?.popViewController(animated: true)
    }

    @objc private func duplicateAsCustomModel() {
        readOnly = false
        existingModel = nil
        title = String(localized: "provider_model.editor.title.add")
        navigationItem.rightBarButtonItem = nil
        tableView.reloadData()
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
        case .openAICompatible, .openRouter:
            let orderedEfforts = ProjectChatService.ReasoningEffort.allCases.filter { reasoningEfforts.contains($0) }
            return LLMProviderModelCapabilities(
                reasoningEfforts: orderedEfforts,
                thinkingSupported: false,
                thinkingCanDisable: false,
                structuredOutputSupported: structuredOutputSupported,
                maxOutputTokensOverride: maxOutputOverride,
                contextWindowTokensOverride: contextWindowOverride
            )
        case .anthropic, .googleGemini:
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
