//
//  ChatMenuBuilder.swift
//  Doufu
//

import UIKit

struct ChatMenuBuilder {

    static func threadMenu(
        threads: [ProjectChatThreadRecord],
        currentThreadID: String?,
        onSwitch: @escaping (String) -> Void,
        onCreate: @escaping () -> Void,
        onManage: @escaping () -> Void
    ) -> UIMenu {
        let threadActions: [UIMenuElement]
        if !threads.isEmpty {
            threadActions = threads.map { thread in
                UIAction(
                    title: thread.title,
                    state: thread.id == currentThreadID ? .on : .off
                ) { _ in
                    onSwitch(thread.id)
                }
            }
        } else {
            threadActions = [
                UIAction(title: String(localized: "chat.menu.no_thread"), attributes: .disabled) { _ in }
            ]
        }

        let createAction = UIAction(
            title: String(localized: "chat.menu.new_thread"),
            image: UIImage(systemName: "plus")
        ) { _ in
            onCreate()
        }
        let manageAction = UIAction(
            title: String(localized: "chat.menu.manage_threads"),
            image: UIImage(systemName: "list.bullet")
        ) { _ in
            onManage()
        }
        let actionsSubmenu = UIMenu(title: "", options: .displayInline, children: [createAction, manageAction])
        return UIMenu(title: String(localized: "chat.thread.button_title"), children: threadActions + [actionsSubmenu])
    }

    static func moreMenu(
        onFiles: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> UIMenu {
        let filesAction = UIAction(
            title: String(localized: "workspace.panel.files"),
            image: UIImage(systemName: "folder")
        ) { _ in
            onFiles()
        }
        let settingsAction = UIAction(
            title: String(localized: "workspace.panel.settings"),
            image: UIImage(systemName: "gearshape")
        ) { _ in
            onSettings()
        }
        let closeAction = UIAction(
            title: String(localized: "common.action.close"),
            image: UIImage(systemName: "xmark"),
            attributes: .destructive
        ) { _ in
            onClose()
        }
        return UIMenu(children: [filesAction, settingsAction, closeAction])
    }

    static func executingMoreMenu(
        onClose: @escaping () -> Void
    ) -> UIMenu {
        let filesAction = UIAction(
            title: String(localized: "workspace.panel.files"),
            image: UIImage(systemName: "folder"),
            attributes: .disabled
        ) { _ in }
        let settingsAction = UIAction(
            title: String(localized: "workspace.panel.settings"),
            image: UIImage(systemName: "gearshape"),
            attributes: .disabled
        ) { _ in }
        let closeAction = UIAction(
            title: String(localized: "common.action.close"),
            image: UIImage(systemName: "xmark"),
            attributes: .destructive
        ) { _ in
            onClose()
        }
        return UIMenu(children: [filesAction, settingsAction, closeAction])
    }

    static func modelMenu(
        currentCredential: ProjectChatService.ProviderCredential?,
        allCredentials: [ProjectChatService.ProviderCredential],
        manager: ChatModelSelectionManager
    ) -> UIMenu {
        guard let credential = currentCredential else {
            let unavailable = UIAction(title: String(localized: "chat.error.no_provider"), attributes: .disabled) { _ in }
            return UIMenu(title: String(localized: "chat.menu.model"), children: [unavailable])
        }
        let providerMenus = allCredentials.map { provider in
            let modelRecords = manager.availableModelRecords(for: provider)
            let modelSubmenus: [UIMenu] = modelRecords.map { model in
                let modelID = model.id
                let isCurrent = provider.providerID == credential.providerID
                    && modelID.caseInsensitiveCompare(manager.resolvedModelID(for: provider)) == .orderedSame
                let selectAction = UIAction(
                    title: String(localized: "chat.menu.use_model"),
                    state: isCurrent ? .on : .off
                ) { _ in
                    manager.selectProviderModel(providerCredential: provider, modelID: modelID)
                }
                var children: [UIMenuElement] = [selectAction]
                if let optionMenu = modelOptionMenu(credential: provider, modelID: modelID, manager: manager) {
                    children.append(optionMenu)
                }
                return UIMenu(
                    title: model.effectiveDisplayName,
                    options: .displayInline,
                    children: children
                )
            }

            let useProviderAction = UIAction(
                title: String(localized: "chat.menu.use_provider"),
                state: provider.providerID == credential.providerID ? .on : .off
            ) { _ in
                manager.switchProvider(to: provider.providerID)
            }
            let providerChildren: [UIMenuElement]
            if modelSubmenus.isEmpty {
                providerChildren = [
                    useProviderAction,
                    UIAction(title: String(localized: "chat.menu.no_models_available"), attributes: .disabled) { _ in }
                ]
            } else {
                providerChildren = [useProviderAction] + modelSubmenus
            }
            return UIMenu(
                title: manager.providerMenuTitle(for: provider),
                children: providerChildren
            )
        }

        return UIMenu(
            title: String(localized: "chat.menu.model"),
            children: providerMenus
        )
    }

    static func modelOptionMenu(
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        manager: ChatModelSelectionManager
    ) -> UIMenu? {
        let providerKind = manager.providerStore.loadProvider(id: credential.providerID)?.kind ?? credential.providerKind
        let capabilities = manager.resolveModelProfile(
            providerID: credential.providerID,
            providerKind: providerKind,
            modelID: modelID
        )
        switch providerKind {
        case .openAICompatible:
            guard let profile = manager.reasoningProfile(
                forModelID: modelID,
                providerID: credential.providerID,
                providerKind: providerKind
            ) else {
                return nil
            }
            let selectedReasoning = manager.resolvedReasoningEffort(
                forModelID: modelID,
                providerID: credential.providerID,
                providerKind: providerKind
            )
            let reasoningActions = profile.supported.map { effort in
                UIAction(
                    title: effort.displayName,
                    state: effort == selectedReasoning ? .on : .off
                ) { _ in
                    manager.selectProviderModel(providerCredential: credential, modelID: modelID)
                    manager.selectedReasoningEffortsByModelID[manager.normalizedModelID(modelID)] = effort
                    manager.delegate?.modelSelectionDidChange()
                }
            }
            return UIMenu(
                title: String(localized: "chat.menu.reasoning"),
                options: .displayInline,
                children: reasoningActions
            )
        case .anthropic:
            guard capabilities.thinkingSupported else { return nil }
            let key = manager.normalizedModelID(modelID)
            guard capabilities.thinkingCanDisable else {
                manager.selectedAnthropicThinkingEnabledByModelID[key] = true
                return nil
            }
            let currentValue = manager.selectedAnthropicThinkingEnabledByModelID[key] ?? true
            manager.selectedAnthropicThinkingEnabledByModelID[key] = currentValue
            let actions = [
                UIAction(
                    title: String(localized: "chat.thinking.enabled"),
                    state: currentValue ? .on : .off
                ) { _ in
                    manager.selectProviderModel(providerCredential: credential, modelID: modelID)
                    manager.selectedAnthropicThinkingEnabledByModelID[key] = true
                    manager.delegate?.modelSelectionDidChange()
                },
                UIAction(
                    title: String(localized: "chat.thinking.disabled"),
                    state: currentValue ? .off : .on
                ) { _ in
                    manager.selectProviderModel(providerCredential: credential, modelID: modelID)
                    manager.selectedAnthropicThinkingEnabledByModelID[key] = false
                    manager.delegate?.modelSelectionDidChange()
                }
            ]
            return UIMenu(
                title: String(localized: "chat.menu.thinking"),
                options: .displayInline,
                children: actions
            )
        case .googleGemini:
            guard capabilities.thinkingSupported else { return nil }
            let key = manager.normalizedModelID(modelID)
            guard capabilities.thinkingCanDisable else {
                manager.selectedGeminiThinkingEnabledByModelID[key] = true
                return nil
            }
            let currentValue = manager.selectedGeminiThinkingEnabledByModelID[key] ?? true
            manager.selectedGeminiThinkingEnabledByModelID[key] = currentValue
            let actions = [
                UIAction(
                    title: String(localized: "chat.thinking.enabled"),
                    state: currentValue ? .on : .off
                ) { _ in
                    manager.selectProviderModel(providerCredential: credential, modelID: modelID)
                    manager.selectedGeminiThinkingEnabledByModelID[key] = true
                    manager.delegate?.modelSelectionDidChange()
                },
                UIAction(
                    title: String(localized: "chat.thinking.disabled"),
                    state: currentValue ? .off : .on
                ) { _ in
                    manager.selectProviderModel(providerCredential: credential, modelID: modelID)
                    manager.selectedGeminiThinkingEnabledByModelID[key] = false
                    manager.delegate?.modelSelectionDidChange()
                }
            ]
            return UIMenu(
                title: String(localized: "chat.menu.thinking"),
                options: .displayInline,
                children: actions
            )
        }
    }
}
