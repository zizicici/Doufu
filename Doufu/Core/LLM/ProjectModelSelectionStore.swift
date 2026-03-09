//
//  ProjectModelSelectionStore.swift
//  Doufu
//
//  Created by Claude on 2026/03/09.
//

import Foundation

struct ProjectModelSelection: Codable, Equatable {
    let providerID: String
    let modelRecordID: String
}

struct ThreadModelSelection: Codable, Equatable {
    var selectedProviderID: String
    var selectedModelIDByProviderID: [String: String]
    var selectedReasoningEffortsByModelID: [String: String]
    var selectedAnthropicThinkingEnabledByModelID: [String: Bool]
    var selectedGeminiThinkingEnabledByModelID: [String: Bool]
}

final class ProjectModelSelectionStore {
    static let shared = ProjectModelSelectionStore()

    private let fileManager: FileManager
    private let configFileName = ".doufu_project_config.json"
    private let threadSelectionsFileName = ".doufu_thread_selections.json"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Project-level Selection

    func loadSelection(projectURL: URL) -> ProjectModelSelection? {
        let config = loadProjectConfig(projectURL: projectURL)
        guard let providerID = config?.selectedProviderID,
              !providerID.isEmpty,
              let modelRecordID = config?.selectedModelRecordID,
              !modelRecordID.isEmpty
        else {
            return nil
        }
        return ProjectModelSelection(providerID: providerID, modelRecordID: modelRecordID)
    }

    func saveSelection(_ selection: ProjectModelSelection?, projectURL: URL) {
        var config = loadProjectConfig(projectURL: projectURL) ?? ProjectConfig()
        config.selectedProviderID = selection?.providerID
        config.selectedModelRecordID = selection?.modelRecordID
        saveProjectConfig(config, projectURL: projectURL)
    }

    // MARK: - Thread-level Selection

    func loadThreadSelection(projectURL: URL, threadID: String) -> ThreadModelSelection? {
        let selections = loadThreadSelections(projectURL: projectURL)
        return selections[threadID]
    }

    func saveThreadSelection(_ selection: ThreadModelSelection, projectURL: URL, threadID: String) {
        var selections = loadThreadSelections(projectURL: projectURL)
        selections[threadID] = selection
        saveThreadSelections(selections, projectURL: projectURL)
    }

    func removeThreadSelection(projectURL: URL, threadID: String) {
        var selections = loadThreadSelections(projectURL: projectURL)
        selections.removeValue(forKey: threadID)
        saveThreadSelections(selections, projectURL: projectURL)
    }

    // MARK: - Private

    private func loadProjectConfig(projectURL: URL) -> ProjectConfig? {
        let url = projectURL.appendingPathComponent(configFileName)
        guard
            let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(ProjectConfig.self, from: data)
        else {
            return nil
        }
        return config
    }

    private func saveProjectConfig(_ config: ProjectConfig, projectURL: URL) {
        let url = projectURL.appendingPathComponent(configFileName)
        guard let data = try? JSONEncoder().encode(config) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func loadThreadSelections(projectURL: URL) -> [String: ThreadModelSelection] {
        let url = projectURL.appendingPathComponent(threadSelectionsFileName)
        guard
            let data = try? Data(contentsOf: url),
            let selections = try? JSONDecoder().decode([String: ThreadModelSelection].self, from: data)
        else {
            return [:]
        }
        return selections
    }

    private func saveThreadSelections(_ selections: [String: ThreadModelSelection], projectURL: URL) {
        let url = projectURL.appendingPathComponent(threadSelectionsFileName)
        guard let data = try? JSONEncoder().encode(selections) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}

private struct ProjectConfig: Codable {
    var selectedProviderID: String?
    var selectedModelRecordID: String?
}
