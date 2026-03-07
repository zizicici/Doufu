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
        let shouldSelect: Bool
    }

    var onSave: ((SavePayload) -> Void)?

    private enum Section: Int, CaseIterable {
        case identity
        case capability
        case selection
        case save
    }

    private enum IdentityRow: Int, CaseIterable {
        case modelID
        case displayName
    }

    private let provider: ProjectChatService.ProviderCredential
    private let existingModel: LLMProviderModelRecord?
    private var modelIDText: String
    private var displayNameText: String
    private var reasoningEfforts: Set<ProjectChatService.ReasoningEffort>
    private var thinkingSupported: Bool
    private var thinkingCanDisable: Bool
    private var structuredOutputSupported: Bool
    private var shouldSelect: Bool

    init(
        provider: ProjectChatService.ProviderCredential,
        existingModel: LLMProviderModelRecord?,
        selectedModelID: String
    ) {
        self.provider = provider
        self.existingModel = existingModel
        let modelID = existingModel?.modelID ?? ""
        modelIDText = modelID
        displayNameText = existingModel?.effectiveDisplayName ?? ""
        let capabilities = existingModel?.capabilities ?? .defaults(for: provider.providerKind, modelID: modelID)
        reasoningEfforts = Set(capabilities.reasoningEfforts)
        thinkingSupported = capabilities.thinkingSupported
        thinkingCanDisable = capabilities.thinkingCanDisable
        structuredOutputSupported = capabilities.structuredOutputSupported
        if let existingID = existingModel?.id, !existingID.isEmpty {
            shouldSelect = existingID.caseInsensitiveCompare(selectedModelID) == .orderedSame
        } else {
            shouldSelect = false
        }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = existingModel == nil
            ? String(localized: "provider_model.editor.title.add")
            : String(localized: "provider_model.editor.title.edit")
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
            case .openAICompatible:
                return ProjectChatService.ReasoningEffort.allCases.count + 1
            case .anthropic, .googleGemini:
                return 3
            }
        case .selection, .save:
            return 1
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
            return provider.providerKind == .openAICompatible
                ? String(localized: "provider_model.editor.section.capabilities")
                : String(localized: "provider_model.editor.section.thinking")
        case .selection:
            return String(localized: "provider_model.editor.section.selection")
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
            case .openAICompatible:
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
            return cell

        case .selection:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsToggleCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsToggleCell
            else {
                return UITableViewCell()
            }
            cell.configure(
                title: String(localized: "provider_model.editor.select_after_save"),
                isOn: shouldSelect
            ) { [weak self] isOn in
                self?.shouldSelect = isOn
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
            capabilities: buildCapabilities(),
            shouldSelect: shouldSelect
        )
        onSave?(payload)
        navigationController?.popViewController(animated: true)
    }

    private func canSave() -> Bool {
        let normalizedModelID = modelIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else {
            return false
        }

        if provider.providerKind == .openAICompatible {
            return !reasoningEfforts.isEmpty
        }
        return true
    }

    private func buildCapabilities() -> LLMProviderModelCapabilities {
        switch provider.providerKind {
        case .openAICompatible:
            let orderedEfforts = ProjectChatService.ReasoningEffort.allCases.filter { reasoningEfforts.contains($0) }
            return LLMProviderModelCapabilities(
                reasoningEfforts: orderedEfforts,
                thinkingSupported: false,
                thinkingCanDisable: false,
                structuredOutputSupported: structuredOutputSupported
            )
        case .anthropic, .googleGemini:
            return LLMProviderModelCapabilities(
                reasoningEfforts: [],
                thinkingSupported: thinkingSupported,
                thinkingCanDisable: thinkingSupported && thinkingCanDisable,
                structuredOutputSupported: structuredOutputSupported
            )
        }
    }
}
