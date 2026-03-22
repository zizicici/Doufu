//
//  ProviderModelManagementCoordinator.swift
//  Doufu
//
//  Created by Codex on 2026/03/07.
//

import UIKit

enum ProviderModelManageRow: Int, CaseIterable {
    case refreshOfficialModels
    case addCustomModel
}

@MainActor
final class ProviderModelManagementCoordinator {
    private let store = LLMProviderSettingsStore.shared
    private let modelDiscoveryService = LLMProviderModelDiscoveryService()

    private(set) var isRefreshingModels = false
    private var modelRefreshTask: Task<Void, Never>?

    func storedModels(for provider: LLMProviderRecord?) -> [LLMProviderModelRecord] {
        provider?.availableModels ?? []
    }

    func cancelRefreshIfNeeded(whenViewRemoved: Bool) {
        guard whenViewRemoved else {
            return
        }
        modelRefreshTask?.cancel()
        modelRefreshTask = nil
        isRefreshingModels = false
    }

    func refreshOfficialModels(
        for provider: LLMProviderRecord,
        manageSectionIndex: Int,
        tableView: UITableView,
        in controller: UIViewController,
        onUpdate: (() -> Void)? = nil
    ) {
        isRefreshingModels = true
        if let onUpdate {
            onUpdate()
        } else {
            tableView.reloadSections(IndexSet(integer: manageSectionIndex), with: .none)
        }
        modelRefreshTask?.cancel()
        modelRefreshTask = Task { @MainActor [weak self, weak tableView, weak controller] in
            guard let self else {
                return
            }
            defer {
                self.isRefreshingModels = false
                if let onUpdate {
                    onUpdate()
                } else {
                    tableView?.reloadData()
                }
            }

            let token = (try? self.store.loadBearerToken(for: provider))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                return
            }

            do {
                let models = try await self.modelDiscoveryService.fetchModels(for: provider, bearerToken: token)
                _ = try self.store.replaceOfficialModels(providerID: provider.id, models: models)
            } catch {
                guard let controller else {
                    return
                }
                let alert = UIAlertController(
                    title: String(localized: "provider_model.alert.refresh_failed.title"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                controller.present(alert, animated: true)
            }
        }
    }

    func presentModelDetail(
        for provider: LLMProviderRecord,
        model: LLMProviderModelRecord,
        tableView: UITableView,
        from controller: UIViewController,
        onUpdate: (() -> Void)? = nil
    ) {
        guard let credential = buildCredential(for: provider) else {
            return
        }
        let editor = ProviderModelEditorViewController(
            provider: credential,
            existingModel: model,
            readOnly: true
        )
        editor.onSave = { [weak tableView, weak controller, weak self] payload in
            guard let self else { return }
            do {
                _ = try self.store.saveCustomModel(
                    providerID: provider.id,
                    modelID: payload.modelID,
                    displayName: payload.displayName,
                    capabilities: payload.capabilities,
                    existingRecordID: nil
                )
                if let onUpdate {
                    onUpdate()
                } else {
                    tableView?.reloadData()
                }
            } catch {
                guard let controller else { return }
                let alert = UIAlertController(
                    title: String(localized: "provider_model.alert.save_failed.title"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                controller.present(alert, animated: true)
            }
        }
        controller.navigationController?.pushViewController(editor, animated: true)
    }

    func presentModelEditor(
        for provider: LLMProviderRecord,
        existingModel: LLMProviderModelRecord?,
        tableView: UITableView,
        from controller: UIViewController,
        onUpdate: (() -> Void)? = nil
    ) {
        guard let credential = buildCredential(for: provider) else {
            return
        }
        let editor = ProviderModelEditorViewController(
            provider: credential,
            existingModel: existingModel
        )
        editor.onSave = { [weak tableView, weak controller, weak self] payload in
            guard let self else {
                return
            }
            do {
                _ = try self.store.saveCustomModel(
                    providerID: provider.id,
                    modelID: payload.modelID,
                    displayName: payload.displayName,
                    capabilities: payload.capabilities,
                    existingRecordID: existingModel?.id
                )
                if let onUpdate {
                    onUpdate()
                } else {
                    tableView?.reloadData()
                }
            } catch {
                guard let controller else {
                    return
                }
                let alert = UIAlertController(
                    title: String(localized: "provider_model.alert.save_failed.title"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                controller.present(alert, animated: true)
            }
        }
        controller.navigationController?.pushViewController(editor, animated: true)
    }

    private func buildCredential(for provider: LLMProviderRecord) -> ProjectChatService.ProviderCredential? {
        guard let baseURL = URL(string: provider.effectiveBaseURLString) else {
            return nil
        }
        let token = (try? store.loadBearerToken(for: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ProjectChatService.ProviderCredential(
            providerID: provider.id,
            providerLabel: provider.label,
            providerKind: provider.kind,
            authMode: provider.authMode,
            modelID: "",
            baseURL: baseURL,
            bearerToken: token,
            chatGPTAccountID: provider.chatGPTAccountID,
            profile: LLMModelRegistry.resolve(providerKind: provider.kind, modelID: "", modelRecord: nil)
        )
    }
}
